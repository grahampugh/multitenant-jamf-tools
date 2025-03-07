#!/bin/bash

: <<'DOC' 
JOCADS - the Jamf Object Copier and Deleter script for multiple Jamf instances
by Graham Pugh

This script can copy and delete a range of API objects between Jamf instances across multiple servers

Prerequisites:
Requires Jamf Pro 10.35 or greater
DOC

# -------------------------------------------------------------------------
# Source the file for obtaining the token and setting the server
# -------------------------------------------------------------------------

# source the _common-framework.sh file
# shellcheck source-path=SCRIPTDIR source=_common-framework.sh
source "_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# -------------------------------------------------------------------------
# Set variables
# -------------------------------------------------------------------------

# Other fixed variables
xml_folder_default="/Users/Shared/Jamf/JOCADS"
log_file="$HOME/Library/Logs/JAMF/JOCADS.log"
policy_testing_category="Untested"

# Reset group action before reading command line flags
api_obj_action=""

# reduce the curl tries
max_tries_override=4

# -------------------------------------------------------------------------
# Functions
# -------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
-----------------------
  Jamf Object Copier
-----------------------
Usage: ./jocads.sh <options>

NOTE: ./set_credentials.sh      Set the Keychain credentials

-h, --help                      Shows this help screen.

[no arguments]                  Interactive mode


--source '<URL>'                Specify the template instance. Optional.
--dest '<URL>'                  Specify an instance. Required.
                                If dest flag is set to 'ALL', copies to or deletes from all instances.
--source-list 'prd/tst'         Specify a server. This overrides the default server (prd). Optional.
--dest-list '<SERVERNAME>'"
                                Specify a server. This overrides the default server (prd). Optional.
--all                           Perform action on ALL instances in the instance list
-d, --delete                    Delete an item.
-c, --copy                      Copy an item.

Object types. Must be exactly as in the JSS:
--policy '<POLICY-NAME>'        Specify a policy name.
--group '<GROUP-NAME>'          Specify a group name.
--script '<SCRIPT-NAME>'        Specify a script name.
--category '<CATEGORY-NAME>'    Specify a category name.
--ea '<EA-NAME>'                Specify an extension attribute name.
--masapp '<APPSTOREAPP-NAME>'   Specify a Mac App Store app name.
--package '<PACKAGE-NAME>'      Specify a package name.

--dp '<FILTER>'                 Filter the choice of distribution point URL, 
                                e.g. 'myorg' to only select a URL containing 'myorg'

--clean                         Clean up working files after use.
-v                              Add verbose curl output
USAGE
}

add_icon_to_copied_policy() {
    local chosen_api_obj_name="$1"
    local jss_url="$2"
    local jss_credentials="$3"

    # If downloaded icon doesn't match the icon in an existing policy, upload it.
    # Method thanks to https://list.jamfsoftware.com/jamf-nation/discussions/23231/mass-icon-upload
    if [[ -f "$xml_folder/$icon_filename" ]]; then
        echo "   [add_icon_to_copied_policy] Downloaded icon: ${icon_filename}"

        chosen_api_obj_name_url_encoded="$( echo "$chosen_api_obj_name" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"

        # send request
        curl_url="$jss_url/JSSResource/policies/name/${chosen_api_obj_name_url_encoded}"
        curl_args=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request

        # get id from output
        policy_id=$(xmllint --xpath '//general/id/text()' "$curl_output_file" 2>/dev/null)

        if [[ $policy_id ]]; then
            echo "   [add_icon_to_copied_policy] Policy number ${policy_id} identified..."
        else
            echo  "   [add_icon_to_copied_policy] ERROR: Policy ${chosen_api_obj_name} not found, so cannot upload icon. Aborting..."
            cleanup_and_exit
        fi

        # Let's see if there is already an icon with the correct name (not really relevant in this script, but it should all be modularized in the future).
        curl_url="$jss_url/JSSResource/policies/id/${policy_id}"
        curl_args=("--header")
        curl_args+=("Accept: application/xml")
        curl_args+=("-N" "-X" "GET")
        send_curl_request

        existing_self_service_icon=$(xmllint --xpath '//self_service/self_service_icon/filename/text()' "$curl_output_file" 2>/dev/null)
        if [[ "${existing_self_service_icon}" ]]; then
            echo "   [add_icon_to_copied_policy] Existing icon: ${existing_self_service_icon}"
        else
            echo "   [add_icon_to_copied_policy] No icon found."

        fi

        if [[ "$force_icon_update" == "yes" ]]; then
            echo "   [add_icon_to_copied_policy] Forcing upload of '${icon_filename}'."
        fi

        if [[ "${existing_self_service_icon}" != "${icon_filename}" || "$force_icon_update" == "yes" ]]; then
            echo "   [add_icon_to_copied_policy] Uploading '${icon_filename}'."

            # Now upload the file to the correct policy_id
            curl_url="$jss_url/JSSResource/fileuploads/policies/id/${policy_id}"
            curl_args=("--header")
            curl_args+=("Content-type: multipart/form-data")
            curl_args+=("--form")
            curl_args+=(name=@"${xml_folder}/${icon_filename}")
            curl_args+=("-N" "-X" "POST")
            send_curl_request
        else
            echo "   [add_icon_to_copied_policy] Existing icon matches repo. No need to re-upload."
        fi
    elif [[ ! "${icon_filename}" ]]; then
        echo "   [add_icon_to_copied_policy] No icon in this recipe. Continuing..."
    else
        echo "   [add_icon_to_copied_policy] Icon '${xml_folder}/${icon_filename}' not found. Continuing..."
    fi
    echo
}

check_eas_in_groups() {
    local group_name="$1"

    group_file="${xml_folder}/computer_group-${group_name}-fetched.xml"

    # Set the source server
    set_credentials "${source_instance}"
    # determine jss_url
    jss_url="${source_instance}"

    # grab a list of all the extension attributes so we can search against them
    # send request
    curl_url="$jss_url/JSSResource/computerextensionattributes"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get a list of EAs
    extension_attributes_list=$(xmllint --xpath '//computer_extension_attributes/computer_extension_attribute/name' "$curl_output_file" 2>/dev/null | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n")

    # We need to ensure extension attributes referenced within computer groups are created first
    echo "   [check_eas_in_groups] Checking for extension attributes in criteria of '$group_name'"

    criterion_array=$(
        xmllint --xpath '//computer_group/criteria/criterion/name' \
        "${group_file}" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    if [[ $criterion_array ]]; then
        while read -r criterion; do
            extension_attribute_found=0
            if [[ $criterion ]]; then
                echo "   [check_eas_in_groups] Checking '${criterion}' is an EA."
                # exclude known criteria that are not EAs
                if [[ "$criterion" != "Application Title" && "$criterion" != "Application Version" && "$criterion" != "Computer Group" && "$criterion" != "Computer Name" && "$criterion" != "Operating System" && "$criterion" != "Operating System Version" && "$criterion" != "User Approved MDM" && "$criterion" != "Building" && "$criterion" != "Department" && "$criterion" != "Packages Installed By Installer.app/SWU" && "$criterion" != "Username" && "$criterion" != "Number of Available Updates" ]]; then
                    echo "   [check_eas_in_groups] Extension attribute '${criterion}' found in criteria."
                    if contains_element "${criterion}" "${extension_attributes_list}"; then
                        echo "   [check_eas_in_groups] Extension attribute '${criterion}' matches existing."
                        extension_attribute_found=1
                        extension_attribute_name="${criterion}"
                        fetch_api_object_by_name "computer_extension_attribute" "$extension_attribute_name"
                        parse_api_object_by_name_for_copying "computer_extension_attribute" "$extension_attribute_name"
                        echo
                        if [[ $ask_for_dependencies == "yes" ]]; then
                            printf '%s' "WARNING! This will update computer_extension_attribute $extension_attribute_name. Are you sure? (Y/N) : "
                            read -r are_you_sure_computer_extension_attribute < /dev/tty
                            echo
                            case "$are_you_sure_computer_extension_attribute" in
                                Y|y)
                                    echo "   [check_eas_in_groups] Confirmed, copying $extension_attribute_name"
                                    copy_api_object_by_name "computer_extension_attribute" "$extension_attribute_name"
                                ;;
                                *)
                                    echo "   [check_eas_in_groups] Skipping $extension_attribute_name"
                                ;;
                            esac
                        else
                            echo "   [check_eas_in_groups] Force-copy mode, copying $extension_attribute_name"
                            copy_api_object_by_name "computer_extension_attribute" "$extension_attribute_name"
                        fi
                    fi
                    if [[ $extension_attribute_found == 0 ]]; then
                        echo "   [check_eas_in_groups] No matching extension attribute '${criterion}' found."
                    fi
                fi
            fi
        done <<< "${criterion_array}"
    else
        echo "   [check_eas_in_groups] No extension attributes found in this group."
    fi
}

check_eas_in_mobile_device_groups() {
    local group_name="$1"

    group_file="${xml_folder}/mobile_device_group-${group_name}-fetched.xml"

    # Set the source server
    set_credentials "${source_instance}"
    # determine jss_url
    jss_url="${source_instance}"

    # grab a list of all the extension attributes so we can search against them
    # send request
    curl_url="$jss_url/JSSResource/mobiledeviceextensionattributes"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get a list of EAs
    extension_attributes_list=$(xmllint --xpath '//mobile_device_extension_attributes/mobile_device_extension_attribute/name' "$curl_output_file" 2>/dev/null | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n")

    # We need to ensure extension attributes referenced within mobile device groups are created first
    echo "   [check_eas_in_mobile_device_groups] Checking for extension attributes in criteria of '$group_name'"

    criterion_array=$(
        xmllint --xpath '//mobile_device_group/criteria/criterion/name' \
        "${group_file}" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    if [[ $criterion_array ]]; then
        while read -r criterion; do
            extension_attribute_found=0
            if [[ $criterion ]]; then
                echo "   [check_eas_in_mobile_device_groups] Checking '${criterion}' is an EA."
                # exclude known criteria that are not EAs
                if [[ "$criterion" != "Building" && "$criterion" != "Department" && "$criterion" != "Username" && "$criterion" != "Number of Available Updates" && "$criterion" != "Device Ownership Type" && "$criterion" != "Enrollment Method: PreStage enrollment" && "$criterion" != "Mobile Device Group" && "$criterion" != "Display Name" ]]; then
                    echo "   [check_eas_in_mobile_device_groups] Extension attribute '${criterion}' found in criteria."
                    if contains_element "${criterion}" "${extension_attributes_list}"; then
                        echo "   [check_eas_in_mobile_device_groups] Extension attribute '${criterion}' matches existing."
                        extension_attribute_found=1
                        extension_attribute_name="${criterion}"
                        fetch_api_object_by_name "mobile_device_extension_attribute" "$extension_attribute_name"
                        parse_api_object_by_name_for_copying "mobile_device_extension_attribute" "$extension_attribute_name"
                        echo
                        if [[ $ask_for_dependencies == "yes" ]]; then
                            printf '%s' "WARNING! This will update mobile_device_extension_attribute $extension_attribute_name. Are you sure? (Y/N) : "
                            read -r are_you_sure_mobile_device_extension_attribute < /dev/tty
                            echo
                            case "$are_you_sure_mobile_device_extension_attribute" in
                                Y|y)
                                    echo "   [check_eas_in_mobile_device_groups] Confirmed, copying $extension_attribute_name"
                                    copy_api_object_by_name "mobile_device_extension_attribute" "$extension_attribute_name"
                                ;;
                                *)
                                    echo "   [check_eas_in_mobile_device_groups] Skipping $extension_attribute_name"
                                ;;
                            esac
                        else
                            echo "   [check_eas_in_mobile_device_groups] Force-copy mode, copying $extension_attribute_name"
                            copy_api_object_by_name "mobile_device_extension_attribute" "$extension_attribute_name"
                        fi
                    fi
                    if [[ $extension_attribute_found == 0 ]]; then
                        echo "   [check_eas_in_mobile_device_groups] No matching extension attribute '${criterion}' found."
                    fi
                fi
            fi
        done <<< "${criterion_array}"
    else
        echo "   [check_eas_in_mobile_device_groups] No extension attributes found in this group."
    fi
}

check_groups_in_groups() {
    local group_name="$1"

    # We need to ensure computer groups referenced within computer groups are created first
    echo "   [check_groups_in_groups] Checking for computer groups in criteria of '$group_name'"

    embedded_group_array=$(
        xmllint --xpath '//computer_group/criteria/criterion[name = "Computer Group"]/value' \
        "${xml_folder}/computer_group-${group_name}-fetched.xml" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    f=${#final_group_list[@]}

    if [[ $embedded_group_array ]]; then
        while read -r group; do
            if [[ $group ]]; then
                if [[ "${final_group_list[*]}" != *"${group}"* ]]; then
                    echo "   [check_groups_in_groups] Fetching: ${group}"
                    fetch_api_object_by_name computer_group "${group}"
                    final_group_list[f]="${group}"
                    f=$((f + 1))
                fi
            fi
        done <<< "${embedded_group_array}"
    else
        echo "   [check_groups_in_groups] No embedded computer group found."
    fi
}

check_groups_in_mobile_device_groups() {
    local group_name="$1"

    # We need to ensure mobile device groups referenced within mobile device groups are created first
    echo "   [check_groups_in_mobile_device_groups] Checking for mobile device groups in criteria of '$group_name'"

    embedded_group_array=$(
        xmllint --xpath '//mobile_device_group/criteria/criterion[name = "Mobile Device Group"]/value' \
        "${xml_folder}/mobile_device_group-${group_name}-fetched.xml" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    f=${#final_group_list[@]}

    if [[ $embedded_group_array ]]; then
        while read -r group; do
            if [[ $group ]]; then
                if [[ "${final_group_list[*]}" != *"${group}"* ]]; then
                    echo "   [check_groups_in_mobile_device_groups] Fetching: ${group}"
                    fetch_api_object_by_name mobile_device_group "${group}"
                    final_group_list[f]="${group}"
                    f=$((f + 1))
                fi
            fi
        done <<< "${embedded_group_array}"
    else
        echo "   [check_groups_in_mobile_device_groups] No embedded mobile device group found."
    fi
}

cleanup_and_exit() {
    # Clean up
    rm -rf "${xml_folder_default}"
    # unmount_smb_share
    echo
    echo "   [cleanup_and_exit] We are done here. Thanks, bye!"
    echo "   [main] script exited successfully at $(date)"
    echo
    exit
}

contains_element() {
    # Function to find a match in an array.
    # From https://stackoverflow.com/questions/3685970/check-if-a-bash-array-contains-a-value
    local element="$1"

    while read -r EA ; do
        if [[ "${element}" == "${EA}" ]]; then
            return 0
        fi
    done <<< "${2}"
    return 1
}

convert_name_for_sed() {
    name_for_sed="${1//&/\\&}"
    echo "$name_for_sed"
}

copy_api_object() {
    local api_xml_object="$1"
    local chosen_api_obj_id=$2
    local chosen_api_obj_name="$3"

    api_object_type=$( get_api_object_type "$api_xml_object" )

    local parsed_file="${xml_folder}/${api_xml_object}-${chosen_api_obj_id}-parsed.xml"

    echo "   [copy_api_object] Copying '${api_xml_object}' object '${chosen_api_obj_name}'"

    # we are about to parse various files which takes over the '$parsed_file' variable.
    # so set a temporary one which we revert to afterwards
    parsed_file_temp="${parsed_file}"
    api_object_type_temp="${api_object_type}"

    # now check for dependencies unless we say otherwise
    if [[ $skip_dependencies == "no" ]]; then
        if [[ "${api_xml_object}" == "script" || "${api_xml_object}" == "package" ]]; then
            # Look for category in script info and create if necessary
            local category_name
            category_name=$( 
                xmllint --xpath '//category/text()' "${parsed_file}" 2>/dev/null 
            )
            create_category "$category_name"
        elif [[ "${api_xml_object}" == "os_x_configuration_profile" || "${api_xml_object}" == "mac_application" ]]; then
            # Look for categories and create them if necessary
            echo "   [copy_api_object] Checking the category in '${chosen_api_obj_name}'"
            category_name=$( 
                xmllint --xpath '//general/category/name/text()' "${parsed_file}" 2>/dev/null 
            )
            category_name_decoded="${category_name//&amp;/&}"
            if [[ $category_name_decoded == "" ]]; then
                echo "   [copy_api_object] No category found in this ${api_xml_object}! If this is a mistake, the policy copy will fail."
                echo "   [copy_api_object] Fetched XML: ${parsed_file}"
                exit 1
            else
                echo "   [copy_api_object] Category to check: ${category_name_decoded}"
                create_category "$category_name"
            fi

            # Look for computer groups in the object (targets and exclusions)
            echo "   [copy_api_object] Checking for computer groups in ${chosen_api_obj_name}"

            group_array=$(
                xmllint --xpath '//scope/computer_groups/computer_group/name' \
                "${parsed_file}" 2>/dev/null \
                | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
            )
            excluded_group_array=$(
                xmllint --xpath  '//scope/exclusions/computer_groups/computer_group/name' \
                "${parsed_file}" 2>/dev/null \
                | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
            )

            # Combine the two into a list of unique groups
            unique_group_list=()
            u=0

            if [[ $excluded_group_array ]]; then
                while read -r group; do
                    if [[ $group ]]; then
                        if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                            echo "   [copy_api_object] Excluded Computer group found: ${group}"
                            unique_group_list[u]="${group}"
                            u=$((u + 1))
                        fi
                    fi
                done <<< "${excluded_group_array}"
            fi

            if [[ $group_array ]]; then
                while read -r group; do
                    if [[ $group ]]; then
                        if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                            echo "   [copy_api_object] Computer group found: ${group}"
                            unique_group_list[u]="${group}"
                            u=$((u + 1))
                        fi
                    fi
                done <<< "${group_array}"
            fi

            # transfer the unique list to a new list so that we can add further groups from
            # embedded groups whilst iterating through the unique list
            final_group_list=()
            for (( i = 0; i < ${#unique_group_list[@]}; i++ )); do
                final_group_list[i]="${unique_group_list[$i]}"
            done

            echo "   [copy_api_object] Total ${#unique_group_list[@]} groups found."

            # Read all the groups to find groups within
            for (( i=0; i<${#unique_group_list[@]}; i++ )); do
                echo "   [copy_api_object] Fetching '${unique_group_list[$i]}'."
                fetch_api_object_by_name "computer_group" "${unique_group_list[$i]}"
                check_groups_in_groups "${unique_group_list[$i]}"
            done

            # Process all the groups in reverse order, since the embedded groups
            # will then appear first, which should be safer for avoiding failed group creation
            for (( i=${#final_group_list[@]}-1; i>=0; i-- )); do
                echo "   [copy_api_object] Computer group to process: ${final_group_list[$i]}"
                check_eas_in_groups "${final_group_list[$i]}"
                parse_api_object_by_name_for_copying "computer_group" "${final_group_list[$i]}"
                echo
                if [[ $ask_for_dependencies == "yes" ]]; then
                    printf '%s' "WARNING! This will update computer_group ${final_group_list[$i]}. Are you sure? (Y/N) : "
                    read -r are_you_sure_copy_api_object < /dev/tty
                    case "$are_you_sure_copy_api_object" in
                        Y|y)
                            echo "   [main] Confirmed, copying ${final_group_list[$i]}"
                            copy_computer_group "${final_group_list[$i]}"
                        ;;
                        *)
                            echo "   [main] Skipping ${final_group_list[$i]}"
                        ;;
                    esac
                else
                    echo "   [main] Force-copy mode, copying ${final_group_list[$i]}"
                    copy_computer_group "${final_group_list[$i]}"
                fi
            done
        elif [[ "${api_xml_object}" == "configuration_profile" || "${api_xml_object}" == "mobile_device_application" ]]; then
            # Look for categories and create them if necessary
            echo "   [copy_api_object] Checking the category in '${chosen_api_obj_name}'"
            category_name=$( 
                xmllint --xpath '//general/category/name/text()' "${parsed_file}" 2>/dev/null 
            )
            category_name_decoded="${category_name//&amp;/&}"
            if [[ $category_name_decoded == "" ]]; then
                echo "   [copy_api_object] No category found in this ${api_xml_object}! If this is a mistake, the policy copy will fail."
                echo "   [copy_api_object] Fetched XML: ${parsed_file}"
                exit 1
            else
                echo "   [copy_api_object] Category to check: ${category_name_decoded}"
                create_category "$category_name"
            fi

            # Look for mobile device groups in the object (targets and exclusions)
            echo "   [copy_api_object] Checking for mobile device groups in ${chosen_api_obj_name}"

            group_array=$(
                xmllint --xpath '//scope/mobile_devices/mobile_device/name' \
                "${parsed_file}" 2>/dev/null \
                | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
            )
            excluded_group_array=$(
                xmllint --xpath  '//scope/exclusions/mobile_device_groups/mobile_device_group/name' \
                "${parsed_file}" 2>/dev/null \
                | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
            )

            # Combine the two into a list of unique groups
            unique_group_list=()
            u=0

            if [[ $excluded_group_array ]]; then
                while read -r group; do
                    if [[ $group ]]; then
                        if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                            echo "   [copy_api_object] Excluded Mobile device group found: ${group}"
                            unique_group_list[u]="${group}"
                            u=$((u + 1))
                        fi
                    fi
                done <<< "${excluded_group_array}"
            fi

            if [[ $group_array ]]; then
                while read -r group; do
                    if [[ $group ]]; then
                        if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                            echo "   [copy_api_object] Mobile device group found: ${group}"
                            unique_group_list[u]="${group}"
                            u=$((u + 1))
                        fi
                    fi
                done <<< "${group_array}"
            fi

            # transfer the unique list to a new list so that we can add further groups from
            # embedded groups whilst iterating through the unique list
            final_group_list=()
            for (( i = 0; i < ${#unique_group_list[@]}; i++ )); do
                final_group_list[i]="${unique_group_list[$i]}"
            done

            echo "   [copy_api_object] Total ${#unique_group_list[@]} groups found."

            # Read all the groups to find groups within
            for (( i=0; i<${#unique_group_list[@]}; i++ )); do
                echo "   [copy_api_object] Fetching '${unique_group_list[$i]}'."
                fetch_api_object_by_name "mobile_device_group" "${unique_group_list[$i]}"
                check_groups_in_mobile_device_groups "${unique_group_list[$i]}"
            done

            # Process all the groups in reverse order, since the embedded groups
            # will then appear first, which should be safer for avoiding failed group creation
            for (( i=${#final_group_list[@]}-1; i>=0; i-- )); do
                echo "   [copy_api_object] Mobile device group to process: ${final_group_list[$i]}"
                check_eas_in_mobile_device_groups "${final_group_list[$i]}"
                parse_api_object_by_name_for_copying "mobile_device_group" "${final_group_list[$i]}"
                echo
                if [[ $ask_for_dependencies == "yes" ]]; then
                    printf '%s' "WARNING! This will update mobile_device_group ${final_group_list[$i]}. Are you sure? (Y/N) : "
                    read -r are_you_sure_copy_api_object < /dev/tty
                    case "$are_you_sure_copy_api_object" in
                        Y|y)
                            echo "   [main] Confirmed, copying ${final_group_list[$i]}"
                            copy_mobile_device_group "${final_group_list[$i]}"
                        ;;
                        *)
                            echo "   [main] Skipping ${final_group_list[$i]}"
                        ;;
                    esac
                else
                    echo "   [main] Force-copy mode, copying ${final_group_list[$i]}"
                    copy_mobile_device_group "${final_group_list[$i]}"
                fi
            done
        fi
    fi

    # now revert $parsed_file & $api_object_type
    parsed_file="${parsed_file_temp}"
    echo "   [copy_api_object] Parsed file: '${parsed_file}'"
    api_object_type="${api_object_type_temp}"

    # look for existing entry and update it rather than create a new one if it exists
    source_name_escaped="$( grep "<name>" "${parsed_file}" | head -n 1 | xargs | sed 's/<[^>]*>//g' )"
    source_name="${source_name_escaped//\&amp;/&}"

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="$dest_instance"

    api_xml_object_plural=$(get_plural_from_api_xml_object "$api_xml_object")

    # send request
    curl_url="$jss_url/JSSResource/${api_object_type}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output (users and groups are different to everything else)
    if [[ $api_object_type == "accounts" ]]; then
        existing_id=$(xmllint --xpath "//${api_object_type}/${api_xml_object_plural}/${api_xml_object}[name = '$source_name']/id/text()" "$curl_output_file" 2>/dev/null)
    else
        existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = '$source_name']/id/text()" "$curl_output_file" 2>/dev/null)
    fi

    # change the PayloadOrganization value if selected
    if [[ ("${api_xml_object}" == "os_x_configuration_profile" || "${api_xml_object}" == "configuration_profile") && $fix_org -eq 1 && $new_org != "" ]]; then
        set_payload_organisation "$new_org" "$source_name"
    fi

    if [[ $existing_id ]]; then
        echo "   [copy_api_object] Existing ${api_xml_object} named '${source_name}' found; id=${existing_id}. Updating..."

        if [[ "${api_xml_object}" == "os_x_configuration_profile" || "${api_xml_object}" == "configuration_profile" ]]; then
            # for profiles, we need to ensure that the UUID in the destination profile is maintained, so we do not want to overwrite it. 
            # The UUID is mentioned three times, so it needs to be parsed directly from the destination, and written into the parsed file in each location...

            parsed_uuid=$(xmllint --xpath "//uuid/text()" "${parsed_file}" 2>/dev/null)
            echo "   [copy_api_object] UUID in template: ${parsed_uuid}"

            # send request
            curl_url="$jss_url/JSSResource/${api_object_type}/id/${existing_id}"
            curl_args=("--header")
            curl_args+=("Accept: application/xml")
            send_curl_request

            # get id from output
            existing_uuid=$(xmllint --xpath "//uuid/text()" "$curl_output_file" 2>/dev/null)

            echo "   [copy_api_object] UUID in $dest_instance: ${existing_uuid}"

            # now substitute this existing uuid into the parsed file, or change to the entered uuid
            substituted_parsed_file="$(dirname "$parsed_file")/$(basename "$dest_instance")-$(basename "$parsed_file")"
            if [[ $ask_for_uuid = 1 && $entered_uuid != "" ]]; then
                echo "   [copy_api_object] Entered UUID will be injected: ${entered_uuid}"
                sed 's/'"${parsed_uuid}"'/'"${entered_uuid}"'/g' "${parsed_file}" > "${substituted_parsed_file}"
            else
                sed 's/'"${parsed_uuid}"'/'"${existing_uuid}"'/g' "${parsed_file}" > "${substituted_parsed_file}"
            fi

            echo "   [copy_api_object] Substituted UUID into ${substituted_parsed_file}"

            # send request (profiles)
            curl_url="$jss_url/JSSResource/${api_object_type}/id/${existing_id}"
            curl_args=("--request")
            curl_args+=("PUT")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--upload-file")
            curl_args+=("${substituted_parsed_file}")
            send_curl_request
        else # all other object types
            # send request (accounts are different to everything else)
            if [[ $api_object_type == "accounts" ]]; then
                curl_url="$jss_url/JSSResource/${api_object_type}/${api_xml_object}id/${existing_id}"
            else
                # remove scope using template file if remove_scope_only is specified
                if [[ $remove_scope_only == "yes" ]]; then
                    remove_scope "$api_xml_object" "$chosen_api_obj_name"
                fi

                # disable policy if disable_only is specified
                if [[ $disable_only == "yes" ]]; then
                    disable_api_object "$api_xml_object" "$chosen_api_obj_name"
                fi

                # enable policy if disable_only is specified
                if [[ $enable_only == "yes" ]]; then
                    enable_api_object "$api_xml_object" "$chosen_api_obj_name"
                fi

                curl_url="$jss_url/JSSResource/${api_object_type}/id/${existing_id}"
            fi
            curl_args=("--request")
            curl_args+=("PUT")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--upload-file")
            curl_args+=("${parsed_file}")
            send_curl_request
        fi
    else
        if [[ "${api_xml_object}" == "category" ]]; then
            create_category "$source_name"
        else
            echo "   [copy_api_object] No existing ${api_xml_object} named '${source_name}' found; creating..."

            if [[ $remove_scope_only == "yes" ]]; then
                echo "   [copy_api_object_by_name] '${chosen_api_obj_name}' not present; cannot remove scope..."
            elif [[ $disable_only == "yes" ]]; then
                echo "   [copy_api_object_by_name] '${chosen_api_obj_name}' not present; cannot disable..."
            elif [[ $enable_only == "yes" ]]; then
                echo "   [copy_api_object_by_name] '${chosen_api_obj_name}' not present; cannot enable..."
            else
                echo "   [copy_api_object_by_name] No existing ${api_xml_object} named '${source_name}' found; creating..."

                # send request (accounts are different to everything else)
                if [[ $api_object_type == "accounts" ]]; then
                    curl_url="$jss_url/JSSResource/${api_object_type}/${api_xml_object}id/0"
                else
                    curl_url="$jss_url/JSSResource/${api_object_type}/id/0"
                fi
                curl_args=("--request")
                curl_args+=("POST")
                curl_args+=("--header")
                curl_args+=("Content-Type: application/xml")
                curl_args+=("--upload-file")
                curl_args+=("${parsed_file}")
                send_curl_request
            fi
        fi
    fi
    echo
}

copy_api_object_by_name() {
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"

    local parsed_file="${xml_folder}/${api_xml_object}-${chosen_api_obj_name}-parsed.xml"

    api_object_type=$( get_api_object_type "$api_xml_object" )

    echo "   [copy_api_object_by_name] Copying ${api_xml_object} object '${chosen_api_obj_name}'"

    # look for existing entry and update it rather than create a new one if it exists
    source_name="${chosen_api_obj_name}"

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="$dest_instance"

    api_xml_object_plural=$(get_plural_from_api_xml_object "$api_xml_object")

    # send request
    curl_url="$jss_url/JSSResource/${api_object_type}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = '$source_name']/id/text()" "$curl_output_file" 2>/dev/null)

    if [[ $existing_id ]]; then
        echo "   [copy_api_object_by_name] Existing ${api_xml_object} named '${source_name}' found; id=${existing_id}. Updating..."

        # remove scope using template file if remove_scope_only is specified
        if [[ $remove_scope_only == "yes" ]]; then
            remove_scope "$api_xml_object" "$chosen_api_obj_name"
        fi

        # disable policy if disable_only is specified
        if [[ $disable_only == "yes" ]]; then
            disable_api_object "$api_xml_object" "$chosen_api_obj_name"
        fi

        # enable policy if disable_only is specified
        if [[ $enable_only == "yes" ]]; then
            enable_api_object "$api_xml_object" "$chosen_api_obj_name"
        fi

        # send request
        curl_url="$jss_url/JSSResource/${api_object_type}/id/${existing_id}"
        curl_args=("--request")
        curl_args+=("PUT")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/xml")
        curl_args+=("--data-binary")
        curl_args+=(@"${parsed_file}")
        send_curl_request
    else
        if [[ $remove_scope_only == "yes" ]]; then
            echo "   [copy_api_object_by_name] '${chosen_api_obj_name}' not present; cannot remove scope..."
        elif [[ $disable_only == "yes" ]]; then
            echo "   [copy_api_object_by_name] '${chosen_api_obj_name}' not present; cannot disable..."
        elif [[ $enable_only == "yes" ]]; then
            echo "   [copy_api_object_by_name] '${chosen_api_obj_name}' not present; cannot enable..."
        else
            echo "   [copy_api_object_by_name] No existing ${api_xml_object} named '${source_name}' found; creating..."

            # send request
            curl_url="$jss_url/JSSResource/${api_object_type}/id/0"
            curl_args=("--request")
            curl_args+=("POST")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--data-binary")
            curl_args+=(@"${parsed_file}")
            send_curl_request
        fi
    fi
    echo
}

copy_groups_in_group() {
    local chosen_group_name="$1"

    local fetched_group_file="${xml_folder}/computer_group-${chosen_group_name}-fetched.xml"

    # Look for computer groups as criteria in the group
    echo "   [copy_groups_in_group] Checking for computer groups in '${chosen_group_name}'"

    group_array=$(
        xmllint --xpath \
        '//computer_group/criteria/criterion[name = "Computer Group"]/value' \
        "$fetched_group_file" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    # Create list of unique groups
    unique_group_list=()
    u=0

    if [[ $group_array ]]; then
        while read -r group; do
            if [[ $group ]]; then
                if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                    echo "   [copy_groups_in_group] Computer group found: '${group}'"
                    unique_group_list[u]="${group}"
                    u=$((u + 1))
                fi
            fi
        done <<< "${group_array}"
    fi

    # transfer the unique list to a new list so that we can add further groups from
    # embedded groups whilst iterating through the unique list
    final_group_list=()
    for (( i=0; i<${#unique_group_list[@]}; i++ )); do
        final_group_list[i]="${unique_group_list[$i]}"
    done

    echo "   [copy_groups_in_group] Total ${#unique_group_list[@]} groups found in group."

    # Read all the groups to find groups within
    for (( i=0; i<${#unique_group_list[@]}; i++ )); do
        echo "   [copy_groups_in_group] Fetching '${unique_group_list[$i]}'."
        fetch_api_object_by_name computer_group "${unique_group_list[$i]}"
        check_groups_in_groups "${unique_group_list[$i]}"
    done

    # Process all the groups in reverse order, since the embedded groups
    # will then appear first, which should be safer for avoiding failed group creation
    for (( i=${#final_group_list[@]}-1; i>=0; i-- )); do
        echo "   [copy_groups_in_group] Computer group to process: ${final_group_list[$i]}"
        check_eas_in_groups "${final_group_list[$i]}"
        parse_api_object_by_name_for_copying computer_group "${final_group_list[$i]}"
        echo
        if [[ $ask_for_dependencies == "yes" ]]; then
            printf '%s' "WARNING! This will update computer_group ${final_group_list[$i]}. Are you sure? (Y/N) : "
            read -r are_you_sure_copy_groups_in_group < /dev/tty
            case "$are_you_sure_copy_groups_in_group" in
                Y|y)
                    echo "   [main] Confirmed, copying ${final_group_list[$i]}"
                    copy_computer_group "${final_group_list[$i]}"
                ;;
                *)
                    echo "   [main] Skipping ${final_group_list[$i]}"
                ;;
            esac
        else
            echo "   [main] Force-copy mode, copying ${final_group_list[$i]}"
            copy_computer_group "${final_group_list[$i]}"
        fi
    done
    echo
}

copy_groups_in_mobile_device_group() {
    local chosen_group_name="$1"

    local fetched_group_file="${xml_folder}/mobile_device_group-${chosen_group_name}-fetched.xml"

    # Look for computer groups as criteria in the group
    echo "   [copy_groups_in_mobile_device_group] Checking for mobile device groups in '${chosen_group_name}'"

    group_array=$(
        xmllint --xpath \
        '//mobile_device_group/criteria/criterion[name = "Mobile Device Group"]/value' \
        "$fetched_group_file" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    # Create list of unique groups
    unique_group_list=()
    u=0

    if [[ $group_array ]]; then
        while read -r group; do
            if [[ $group ]]; then
                if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                    echo "   [copy_groups_in_mobile_device_group] Mobile device group found: '${group}'"
                    unique_group_list[u]="${group}"
                    u=$((u + 1))
                fi
            fi
        done <<< "${group_array}"
    fi

    # transfer the unique list to a new list so that we can add further groups from
    # embedded groups whilst iterating through the unique list
    final_group_list=()
    for (( i=0; i<${#unique_group_list[@]}; i++ )); do
        final_group_list[i]="${unique_group_list[$i]}"
    done

    echo "   [copy_groups_in_mobile_device_group] Total ${#unique_group_list[@]} groups found in group."

    # Read all the groups to find groups within
    for (( i=0; i<${#unique_group_list[@]}; i++ )); do
        echo "   [copy_groups_in_mobile_device_group] Fetching '${unique_group_list[$i]}'."
        fetch_api_object_by_name mobile_device_group "${unique_group_list[$i]}"
        check_groups_in_mobile_device_groups "${unique_group_list[$i]}"
    done

    # Process all the groups in reverse order, since the embedded groups
    # will then appear first, which should be safer for avoiding failed group creation
    for (( i=${#final_group_list[@]}-1; i>=0; i-- )); do
        echo "   [copy_groups_in_mobile_device_group] Mobile device group to process: ${final_group_list[$i]}"
        check_eas_in_mobile_device_groups "${final_group_list[$i]}"
        parse_api_object_by_name_for_copying mobile_device_group "${final_group_list[$i]}"
        echo
        if [[ $ask_for_dependencies == "yes" ]]; then
            printf '%s' "WARNING! This will update mobile_device_group ${final_group_list[$i]}. Are you sure? (Y/N) : "
            read -r are_you_sure_copy_groups_in_mobile_device_group < /dev/tty
            case "$are_you_sure_copy_groups_in_mobile_device_group" in
                Y|y)
                    echo "   [main] Confirmed, copying ${final_group_list[$i]}"
                    copy_mobile_device_group "${final_group_list[$i]}"
                ;;
                *)
                    echo "   [main] Skipping ${final_group_list[$i]}"
                ;;
            esac
        else
            echo "   [main] Force-copy mode, copying ${final_group_list[$i]}"
            copy_mobile_device_group "${final_group_list[$i]}"
        fi
    done
    echo
}

get_exclusion_list() {
    exclusion_list_type="$1"  # policies or computergroups

    # import relevant exclusion list
    exclusion_lists_folder="$this_script_dir/exclusion-lists"

    if [[ -f "$exclusion_lists_folder/$exclusion_list_type.txt" ]]; then
        # generate a standard "complete" list 
        exclusion_list=()
        while IFS= read -r exclusion; do
            if [[ "$exclusion" ]]; then
                exclusion_list+=("$exclusion")
            fi
        done < "$exclusion_lists_folder/$exclusion_list_type.txt"
    else
        echo
        echo "No exclusion list for $exclusion_list_type found."
    fi
}

copy_computer_group() {
    local group_name="$1"

    # look for existing entry and update it rather than create a new one if it exists
    source_name="$( 
                    xmllint --xpath \
                    '/computer_group/name/text()' \
                    "${xml_folder}/computer_group-${group_name}-fetched.xml" 2>/dev/null 
                )"
    # source_name_url_encoded=$( encode_name "${source_name}" )

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="$dest_instance"

    # send request
    curl_url="$jss_url/JSSResource/computergroups"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//computer_groups/computer_group[name = '$source_name']/id/text()" "$curl_output_file" 2>/dev/null)

    if [[ $existing_id ]]; then
        # Some extra checking for groups we don't want to replace
        exclude_group="no"
        get_exclusion_list "computergroups"
        for exclusion in "${exclusion_list[@]}"; do
            if [[ $group_name == *"$exclusion"* ]]; then
                exclude_group="yes"
            fi
        done

        if [[ $exclude_group == "no" || ($exclude_group == "yes" && $force_update_groups == "ALL") || ($group_name == *" $force_update_groups" && $force_update_groups != "ALL") ]]; then
            # Other primary groups do need to be updated
            [[ ($exclude_group == "yes" && $force_update_groups == "ALL") || ($group_name == *" $force_update_groups" && $force_update_groups != "ALL") ]] && echo "   [copy_computer_group] $group_name matches 'force_update_groups' criteria ('$force_update_groups')"

            echo "   [copy_computer_group] '$source_name' already exists (ID=$existing_id); updating..."

            # send request
            curl_url="$jss_url/JSSResource/computergroups/id/$existing_id"
            curl_args=("--request")
            curl_args+=("PUT")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--data-binary")
            curl_args+=(@"${xml_folder}/computer_group-${group_name}-parsed.xml")
            send_curl_request
        else
            # We don't want to replace any of the user-serviceable groups)
            echo "   [copy_computer_group] '$source_name' already exists (ID=$existing_id) and is in the exclusion list; skipping..."
        fi
    else
        echo "   [copy_computer_group] No existing '$source_name' group found; creating..."

        # send request
        curl_url="$jss_url/JSSResource/computergroups/id/0"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/xml")
        curl_args+=("--data-binary")
        curl_args+=(@"${xml_folder}/computer_group-${group_name}-parsed.xml")
        send_curl_request
    fi
    echo
}

copy_mobile_device_group() {
    local group_name="$1"

    # look for existing entry and update it rather than create a new one if it exists
    source_name="$( 
                    xmllint --xpath \
                    '/mobile_device_group/name/text()' \
                    "${xml_folder}/mobile_device_group-${group_name}-fetched.xml" 2>/dev/null 
                )"
    # source_name_url_encoded=$( encode_name "${source_name}" )

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="$dest_instance"

    # send request
    curl_url="$jss_url/JSSResource/mobiledevicegroups"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//mobile_device_groups/mobile_device_group[name = '$source_name']/id/text()" "$curl_output_file" 2>/dev/null)

    if [[ $existing_id ]]; then
        # Some extra checking for groups we don't want to replace
        exclude_group="no"
        get_exclusion_list "mobiledevicegroups"
        for exclusion in "${exclusion_list[@]}"; do
            if [[ $group_name == *"$exclusion"* ]]; then
                exclude_group="yes"
            fi
        done

        if [[ $exclude_group == "no" || ($exclude_group == "yes" && $force_update_groups == "ALL") || ($group_name == *" $force_update_groups" && $force_update_groups != "ALL") ]]; then
            # Other primary groups do need to be updated
            [[ ($exclude_group == "yes" && $force_update_groups == "ALL") || ($group_name == *" $force_update_groups" && $force_update_groups != "ALL") ]] && echo "   [copy_mobile_device_group] $group_name matches 'force_update_groups' criteria ('$force_update_groups')"

            echo "   [copy_mobile_device_group] '$source_name' already exists (ID=$existing_id); updating..."

            # send request
            curl_url="$jss_url/JSSResource/mobiledevicegroups/id/$existing_id"
            curl_args=("--request")
            curl_args+=("PUT")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--data-binary")
            curl_args+=(@"${xml_folder}/mobile_device_group-${group_name}-parsed.xml")
            send_curl_request
        else
            # We don't want to replace any of the user-serviceable groups)
            echo "   [copy_mobile_device_group] '$source_name' already exists (ID=$existing_id) and is in the exclusion list; skipping..."
        fi
    else
        echo "   [copy_mobile_device_group] No existing '$source_name' group found; creating..."

        # send request
        curl_url="$jss_url/JSSResource/mobiledevicegroups/id/0"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/xml")
        curl_args+=("--data-binary")
        curl_args+=(@"${xml_folder}/mobile_device_group-${group_name}-parsed.xml")
        send_curl_request
    fi
    echo
}


copy_policy() {
    local chosen_api_obj_name="$1"
    local chosen_api_obj_id=$2

    local fetched_policy_file="${xml_folder}/policy-${chosen_api_obj_name}-fetched.xml"
    local parsed_policy_file="${xml_folder}/policy-${chosen_api_obj_name}-parsed.xml"

    echo "   [copy_policy] Copying policy '$chosen_api_obj_name' (id=$chosen_api_obj_id)"

    # look for all dependencies of the policy unless we say otherwise
    if [[ $skip_dependencies == "no" ]]; then
        # Look for packages and copy them if necessary
        echo "   [copy_policy] Checking for packages in ${chosen_api_obj_name}"
        packages_count=$( 
            xmllint --xpath '//package_configuration/packages/size/text()' \
            "${fetched_policy_file}" 2>/dev/null 
        )
        [[ ! $packages_count ]] && packages_count=0

        for (( n=1; n<=packages_count; n++ )); do
            package_id=$( 
                xmllint --xpath "//package_configuration/packages/package[$n]/id/text()" \
                "${fetched_policy_file}" 2>/dev/null 
            )
            if [[ ${package_id} ]]; then
                package_name=$( 
                    xmllint --xpath "//package_configuration/packages/package[$n]/name/text()" \
                    "${fetched_policy_file}" 2>/dev/null 
                )
                echo "   [copy_policy] Package to check: $package_name (ID ${package_id})"
                fetch_api_object "package" "${package_id}"
                parse_api_obj_for_copying "package" "${package_id}"
                echo
                if [[ $ask_for_dependencies == "yes" ]]; then
                    printf '%s' "WARNING! This will update package $package_name. Are you sure? (Y/N) : "
                    read -r are_you_sure_copy_package < /dev/tty
                    case "$are_you_sure_copy_package" in
                        Y|y)
                            echo "   [main] Confirmed, copying $package_name"
                            copy_api_object "package" "${package_id}" "$package_name"
                        ;;
                        *)
                            echo "   [main] Skipping $package_name"
                        ;;
                    esac
                else
                    echo "   [main] Force-copy mode, copying $package_name"
                    copy_api_object "package" "${package_id}" "$package_name"
                fi
            fi
        done

        # Look for categories and create them if necessary
        echo "   [copy_policy] Checking the category in '${chosen_api_obj_name}'"
        category_name=$( 
            xmllint --xpath '//general/category/name/text()' \
            "${fetched_policy_file}" 2>/dev/null 
        )
        category_name_decoded="${category_name//&amp;/&}"
        if [[ $category_name_decoded == "" ]]; then
            echo "   [copy_policy] No category found in this policy! If this is a mistake, the policy copy will fail."
            echo "   [copy_policy] Fetched XML: ${fetched_policy_file}"
            exit 1
        else
            echo "   [copy_policy] Category to check: ${category_name_decoded}"
            create_category "$category_name"
        fi
    
        # Look for scripts and copy them if necessary
        echo "   [copy_policy] Checking for scripts in ${chosen_api_obj_name}"
        script_count=$(
            xmllint --xpath '//scripts/size/text()' \
            "${fetched_policy_file}" 2>/dev/null 
        )

        if [[ $script_count -gt 0 ]]; then
            for (( n=1; n<=script_count; n++ )); do
                script_id=$( 
                    xmllint --xpath "//scripts/script[$n]/id/text()" \
                    "${fetched_policy_file}" 2>/dev/null 
                )
                if [[ $script_id ]]; then
                    script_name=$( 
                        xmllint --xpath "//scripts/script[$n]/name/text()" \
                        "${fetched_policy_file}" 2>/dev/null 
                    )
                    echo "   [copy_policy] Script to check: $script_name (ID ${script_id})"
                    fetch_api_object script "${script_id}"
                    parse_api_obj_for_copying script "${script_id}"
                    echo
                    if [[ $ask_for_dependencies == "yes" ]]; then
                        printf '%s' "WARNING! This will update script $script_name. Are you sure? (Y/N) : "
                        read -r are_you_sure_copy_script < /dev/tty
                        case "$are_you_sure_copy_script" in
                            Y|y)
                                echo "   [main] Confirmed, copying $script_name"
                                copy_api_object "script" "${script_id}" "$script_name"
                            ;;
                            *)
                                echo "   [main] Skipping $script_name"
                            ;;
                        esac
                    else
                        echo "   [main] Force-copy mode, copying $script_name"
                        copy_api_object "script" "${script_id}" "$script_name"
                    fi
                fi
            done
        fi

        # Look for computer groups in the policy (targets and exclusions)
        echo "   [copy_policy] Checking for computer groups in ${chosen_api_obj_name}"

        group_array=$(
            xmllint --xpath '//scope/computer_groups/computer_group/name' \
            "${fetched_policy_file}" 2>/dev/null \
            | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
        )
        excluded_group_array=$(
            xmllint --xpath '//scope/exclusions/computer_groups/computer_group/name' \
            "${fetched_policy_file}" 2>/dev/null \
            | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
        )

        # Combine the two into a list of unique groups
        unique_group_list=()
        u=0

        if [[ $excluded_group_array ]]; then
            while read -r group; do
                if [[ $group ]]; then
                    if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                        echo "   [copy_policy] Excluded Computer group found: ${group}"
                        unique_group_list[u]="${group}"
                        u=$((u + 1))
                    fi
                fi
            done <<< "${excluded_group_array}"
        fi

        if [[ $group_array ]]; then
            while read -r group; do
                if [[ $group ]]; then
                    if [[ "${unique_group_list[*]}" != *"${group}"* ]]; then
                        echo "   [copy_policy] Computer group found: ${group}"
                        unique_group_list[u]="${group}"
                        u=$((u + 1))
                    fi
                fi
            done <<< "${group_array}"
        fi

        # transfer the unique list to a new list so that we can add further groups from
        # embedded groups whilst iterating through the unique list
        final_group_list=()
        for (( i = 0; i < ${#unique_group_list[@]}; i++ )); do
            final_group_list[i]="${unique_group_list[$i]}"
        done

        echo "   [copy_policy] Total ${#unique_group_list[@]} groups found in policy."

        # Read all the groups to find groups within
        for (( i=0; i<${#unique_group_list[@]}; i++ )); do
            echo "   [copy_policy] Fetching '${unique_group_list[$i]}'."
            fetch_api_object_by_name "computer_group" "${unique_group_list[$i]}"
            check_groups_in_groups "${unique_group_list[$i]}"
        done

        # Process all the groups in reverse order, since the embedded groups
        # will then appear first, which should be safer for avoiding failed group creation
        for (( i=${#final_group_list[@]}-1; i>=0; i-- )); do
            echo "   [copy_policy] Computer group to process: ${final_group_list[$i]}"
            check_eas_in_groups "${final_group_list[$i]}"
            parse_api_object_by_name_for_copying "computer_group" "${final_group_list[$i]}"
            echo
            if [[ $ask_for_dependencies == "yes" ]]; then
                printf '%s' "WARNING! This will update computer_group ${final_group_list[$i]}. Are you sure? (Y/N) : "
                read -r are_you_sure_copy_computer_group < /dev/tty
                case "$are_you_sure_copy_computer_group" in
                    Y|y)
                        echo "   [main] Confirmed, copying ${final_group_list[$i]}"
                        copy_computer_group "${final_group_list[$i]}"
                    ;;
                    *)
                        echo "   [main] Skipping ${final_group_list[$i]}"
                    ;;
                esac
            else
                echo "   [main] Force-copy mode, copying ${final_group_list[$i]}"
                copy_computer_group "${final_group_list[$i]}"
            fi
        done
    fi

    # Write the policy to the destinations
    echo "   [copy_policy] Checking if '${chosen_api_obj_name}' exists..."

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="$dest_instance"

    # send request
    curl_url="$jss_url/JSSResource/policies"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//policies/policy[name = '${chosen_api_obj_name}']/id/text()" "$curl_output_file" 2>/dev/null)

    if [[ $existing_id ]]; then
        # Some extra checking for groups we don't want to replace
        exclude_policy="no"
        get_exclusion_list "computergroups"
        for exclusion in "${exclusion_list[@]}"; do
            if [[ $chosen_api_obj_name == *"$exclusion"* ]]; then
                exclude_policy="yes"
            fi
        done

        if [[ $exclude_policy == "no" || ($exclude_policy == "yes" && $force_update_policies == "ALL") || ($chosen_api_obj_name == *" $force_update_policies" && $force_update_policies != "ALL") ]]; then
            # Other primary groups do need to be updated
            [[ ($exclude_policy == "yes" && $force_update_policies == "ALL") || ($exclude_policy == *" $force_update_policies" && $force_update_policies != "ALL") ]] && echo "   [copy_policy] $chosen_api_obj_name matches 'force_update_groups' criteria ('$force_update_policies')"

            echo "   [copy_policy] '$chosen_api_obj_name' already exists (ID=$existing_id); updating..."

            # remove scope using template file if remove_scope_only is specified
            if [[ $remove_scope_only == "yes" ]]; then
                remove_scope "$api_xml_object" "$chosen_api_obj_name"
            fi

            # disable policy if disable_only is specified
            if [[ $disable_only == "yes" ]]; then
                disable_api_object "$api_xml_object" "$chosen_api_obj_name"
            fi

            # enable policy if disable_only is specified
            if [[ $enable_only == "yes" ]]; then
                enable_api_object "$api_xml_object" "$chosen_api_obj_name"
            fi

            # send request
            curl_url="$jss_url/JSSResource/policies/id/$existing_id"
            curl_args=("--request")
            curl_args+=("PUT")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--data-binary")
            curl_args+=(@"${parsed_policy_file}")
            send_curl_request
        else
            # We don't want to replace any of the user-serviceable groups)
            echo "   [copy_policy] '$source_name' already exists (ID=$existing_id) and is in the exclusion list; skipping..."
        fi
    else
        # This policy not found on the destination with the name we want to use, so post a new one (but not if we specified remove scope or disable policy as these should only apply to existing policies).
        if [[ $remove_scope_only == "yes" ]]; then
            echo "   [copy_policy] '${chosen_api_obj_name}' not present; cannot remove scope..."
        elif [[ $disable_only == "yes" ]]; then
            echo "   [copy_policy] '${chosen_api_obj_name}' not present; cannot disable..."
        elif [[ $enable_only == "yes" ]]; then
            echo "   [copy_policy] '${chosen_api_obj_name}' not present; cannot enable..."
        else
            echo "   [copy_policy] '${chosen_api_obj_name}' not present; creating..."

            # send request
            curl_url="$jss_url/JSSResource/policies/id/0"
            curl_args=("--request")
            curl_args+=("POST")
            curl_args+=("--header")
            curl_args+=("Content-Type: application/xml")
            curl_args+=("--data-binary")
            curl_args+=(@"${parsed_policy_file}")
            send_curl_request
        fi
    fi

    # Now check the icon and upload if necessary
    if [[ $remove_scope_only != "yes" && $disable_only != "yes" && $enable_only != "yes" ]]; then
        add_icon_to_copied_policy "$chosen_api_obj_name" "$jss_url" "${jss_credentials}"
        echo
    fi
}

create_category() {
    local category_name="$1"

    # We need to create a category if it doesn't already exist
    category_name_decoded="${category_name//&amp;/&}"
    echo "   [create_category] Checking category '${category_name_decoded}'"

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="$dest_instance"

    # send request
    curl_url="$jss_url/JSSResource/categories"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//categories/category[name = '$category_name_decoded']/id/text()" "$curl_output_file" 2>/dev/null)

    # determine if the category exists, create if not
    if [[ $existing_id ]]; then
        echo "   [create_category] '$category_name_decoded' already exists (ID=$existing_id)."
    else
        echo "   [create_category] Category '$category_name_decoded' does not exist. Creating..."
        # First we must write the script contents into the Script Template
        category_name_for_sed=$(convert_name_for_sed "$category_name")

        # Example CategoryTemplate.xml in the templates folder
        category_template="$this_script_dir/templates/CategoryTemplate.xml"

        while read -r line || [[ -n "$line" ]]; do
            echo "$line" \
            | sed -e 's|%CATEGORY_NAME%|'"${category_name_for_sed}"'|' \
            | sed -e 's|%PRIORITY%|9|'
        done < "$category_template" > "${xml_folder}/CategoryTemplate-Parsed.xml"

        # send request
        curl_url="$jss_url/JSSResource/categories/id/0"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/xml")
        curl_args+=("--data-binary")
        curl_args+=(@"${xml_folder}/CategoryTemplate-Parsed.xml")
        send_curl_request
    fi
    echo
}

delete_api_object() {
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"
    chosen_api_obj_name_decoded=${chosen_api_obj_name//&amp;/\&}
    api_object_type=$( get_api_object_type "$api_xml_object" )
    api_xml_object_plural=$(get_plural_from_api_xml_object "$api_xml_object")

    # Set the dest server
    set_credentials "$dest_instance"
    # determine jss_url
    jss_url="${dest_instance}"

    echo "   [delete_api_object] Deleting $api_xml_object '$chosen_api_obj_name_decoded'."

    # send request
    curl_url="$jss_url/JSSResource/${api_object_type}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output - in case of duplicate items with the same name, we only grab the first
    existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = '$chosen_api_obj_name']/id/text()" "$curl_output_file" 2>/dev/null | head -n 1)

    if [[ $existing_id ]]; then
        echo "   [delete_api_object] Existing ${api_xml_object} named '${chosen_api_obj_name_decoded}' found; id=${existing_id}. Deleting..."

        # send request
        curl_url="$jss_url/JSSResource/${api_object_type}/id/${existing_id}"
        curl_args=("--request")
        curl_args+=("DELETE")
        curl_args+=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request

        # Send Slack notification
        slack_text="{'username': '$jss_url', 'text': '*jocads.sh*\n*API $api_xml_object delete action*\nUser: $jss_api_user\nObject Name: *$chosen_api_obj_name*\nInstance: $jss_url\nHTTP Response: $http_response'}"
        send_slack_notification "$slack_text"
    else
        echo "   [delete_api_object] No existing ${api_xml_object} named '${chosen_api_obj_name_decoded}' found; aborting..."
    fi
    echo
}

do_delete_pkg() {
    local pkg_name="$1"
    if rm -f "${smb_mountpoint}/Packages/${pkg_name}"; then
        echo "   [delete_pkg] ${pkg_name} successfuilly deleted"
    else
        echo "   [delete_pkg] WARNING! successfully ${pkg_name} was not deleted."
    fi
}

delete_pkg() {
    local pkg_name="$1"
    skip_delete_pkg_obj=0

    # Check that a DP actually exists
    jss_instance="${dest_instance}"
    get_instance_distribution_point

    if [[ $smb_url ]]; then
        # get the smb credentials from the keychain
        get_smb_credentials

        echo
        echo "   [main] Checking for ${chosen_api_obj_name_decoded} on ${smb_url}..."
        # mount the SMB server if not already mounted
        mount_smb_share

        # is the package there?
        if find "${smb_mountpoint}/Packages" -name "${pkg_name}" >/dev/null; then
            echo "   [delete_pkg] Package '$pkg_name' found on $smb_url"
            echo
            if [[ $confirmed == "yes" ]]; then
                echo "   [main] Action confirmed from command line"
                do_delete_pkg "$pkg_name"
            else
                read -r -p "Do you want to delete the actual package from the SMB repo (requires inputting admin password)? (Y/N) : " delete_pkg_from_repo
                case "$delete_pkg_from_repo" in
                    Y|y)
                        echo "   [delete_pkg] Deleting package '$pkg_name' from $smb_url..."
                        do_delete_pkg "$pkg_name"
                    ;;
                    *)
                        echo "   [delete_pkg] Not deleting - package '$pkg_name' will remain on $smb_url"
                    ;;
                esac
            fi
        else
            echo "   [delete_pkg] Package '$pkg_name' does not exist on $smb_url"
            echo
            if [[ $confirmed == "yes" ]]; then
                echo "   [main] Action confirmed from command line"
            else
                read -r -p "Do you want to delete the package object anyway? (Y/N) : " delete_pkg_obj_from_jamf
                case "$delete_pkg_obj_from_jamf" in
                    Y|y)
                        echo "   [delete_pkg] Deleting package object '$pkg_name'..."
                    ;;
                    *)
                        echo "   [delete_pkg] Not deleting package object '$pkg_name'"
                        skip_delete_pkg_obj=1
                    ;;
                esac
            fi
        fi
        # mount the SMB server if not already mounted
        unmount_smb_share
    fi
    echo
}

encode_name() {
    # encode space, '&amp;', percent
    name_url_encoded="$( echo "$1" | sed -e 's|\%|%25|g' | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' | sed -e 's|\#|%23|g' | sed -e 's|\+|%2B|g' )"
    echo "$name_url_encoded"
}

fetch_api_object() {
    local api_xml_object="$1"
    local chosen_api_obj_id="$2"

    api_object_type=$( get_api_object_type "$api_xml_object" )

    # Get the full XML of the selected policy
    echo "   [fetch_api_object] ${api_xml_object} ID: ${chosen_api_obj_id}"

    # Set the source server
    set_credentials "${source_instance}"
    # determine jss_url
    jss_url="${source_instance}"

    # send request (different for accounts to everything else)
    if [[ "$api_xml_object" == "user" || "$api_xml_object" == "group" ]]; then
        curl_url="$jss_url/JSSResource/${api_object_type}/${api_xml_object}id/${chosen_api_obj_id}"
    else
        curl_url="$jss_url/JSSResource/${api_object_type}/id/${chosen_api_obj_id}"
        if [[ ($disable_only == "yes" || $enable_only == "yes") && $api_xml_object != "computer_extension_attribute" && $api_xml_object != "mobile_device_extension_attribute" ]]; then
            curl_url+="/subset/general"
        fi
    fi
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # save formatted fetch file
    xmllint --format "$curl_output_file" > "${xml_folder}/${api_xml_object}-${chosen_api_obj_id}-fetched.xml"
}

fetch_api_object_by_name() {
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"

    api_object_type=$( get_api_object_type "$api_xml_object" )

    chosen_api_obj_name_url_encoded=$(encode_name "$chosen_api_obj_name")

    # Get the full XML of the selected API object
    echo "   [fetch_api_object_by_name] Fetching $api_xml_object name ${chosen_api_obj_name} from $jss_url"
    echo "   [fetch_api_object_by_name] (encoded): ${chosen_api_obj_name_url_encoded}" # TEST

    # Set the source server
    set_credentials "${source_instance}"
    # determine jss_url
    jss_url="${source_instance}"

    # send request
    curl_url="$jss_url/JSSResource/$api_object_type/name/${chosen_api_obj_name_url_encoded}"
    if [[ ($disable_only == "yes" || $enable_only == "yes") && $api_xml_object != "computer_extension_attribute" && $api_xml_object != "mobile_device_extension_attribute" ]]; then
        curl_url+="/subset/general"
    fi
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # save formatted fetch file
    xmllint --format "$curl_output_file" > "${xml_folder}/${api_xml_object}-${chosen_api_obj_name}-fetched.xml"
}

fetch_icon() {
    local fetched_file="$1"

    # get icon details from fetched xml
    echo "   [fetch_icon] Getting icon name from $fetched_file"
    icon_filename=$( 
        xmllint --xpath '//self_service/self_service_icon/filename/text()'\
        "${fetched_file}" 2>/dev/null 
    )
    icon_url=$( 
        xmllint --xpath '//self_service/self_service_icon/uri/text()' \
        "${fetched_file}" 2>/dev/null 
    )
    # local_icon_url=$( echo "$icon_url" | sed 's|https://.*icon|'$jss_url'/icon|' )
    local_icon_url="$icon_url"

    # download icon to local folder (no credentials required for this)
    if [[ $icon_filename && $local_icon_url ]]; then
        echo "   [fetch_icon] Downloading $icon_filename from $local_icon_url to '${xml_folder}/$icon_filename'"
        for (( i=0; i<10; i++ )); do
            curl -s \
                -o "${xml_folder}/$icon_filename" \
                "$local_icon_url"
            sleep $i
            if [[ -s "${xml_folder}/$icon_filename" ]]; then
                echo "   [fetch_icon] Downloaded '${xml_folder}/$icon_filename'"
                break
            fi
            echo "   [fetch_icon] Warning! Icon did not download properly (attempt $i of 10)"
        done
        if [[ ! -s "${xml_folder}/$icon_filename" ]]; then
            echo "   [fetch_icon] Warning! Icon did not download properly. Deleting empty file"
            rm "${xml_folder}/$icon_filename"
        fi
    else
        echo "   [fetch_icon] No icon URL in this policy"
    fi
}

mount_smb_share() {
    # Mount distribution point.
    # smb_mountpoint="/Volumes/$dp_share-$source_instance_list"
    smb_mountpoint="/Volumes/$dp_share"
    if mount | grep "on $smb_mountpoint " > /dev/null; then
        echo "Warning! $smb_mountpoint is already mounted which may be pointing to an incorrect mount point. Attempting to unmount..."
        unmount_smb_share
    fi

    if /usr/bin/osascript -e "mount volume \"${smb_url}\" as user name \"${smb_user}\" with password \"${smb_pass}\""; then
        echo "   [mount_smb_share] ${smb_url} mounted"
    else
        echo "   [mount_smb_share] ERROR: ${smb_url} could not be mounted with ${smb_user}...aborting."
        exit 1
    fi
}

unmount_smb_share() {
    # Unmouint distribution point
    # smb_mountpoint="/Volumes/$dp_share-$source_instance_list"
    smb_mountpoint="/Volumes/$dp_share"
    if mount | grep "on $smb_mountpoint " > /dev/null; then
        if /usr/sbin/diskutil unmount "$smb_mountpoint"; then
            echo "   [unmount_smb_share] ${smb_mountpoint} successfully unmounted."
        else
            echo "   [unmount_smb_share] ERROR: ${smb_mountpoint} was not successfully unmounted."
            exit 1
        fi
    else
        echo "   [unmount_smb_share] ${smb_url} is not mounted."
    fi
}

parse_api_obj_for_copying() {
    local api_xml_object="$1"
    local chosen_api_obj_id=$2

    api_object_type=$( get_api_object_type "$api_xml_object" )

    fetched_file="${xml_folder}/${api_xml_object}-${chosen_api_obj_id}-fetched.xml"
    parsed_file="${xml_folder}/${api_xml_object}-${chosen_api_obj_id}-parsed.xml"

    # Strip out unwanted keys
    echo "   [parse_api_obj_for_copying] Parsing ${api_xml_object} ${chosen_api_obj_id}"
    do_parsing "${fetched_file}" "${parsed_file}"
    echo "   [parse_api_obj_for_copying] Created ${parsed_file}"
}

parse_api_object_by_name_for_copying() {
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"

    api_object_type=$( get_api_object_type "$api_xml_object" )

    fetched_file="${xml_folder}/${api_xml_object}-${chosen_api_obj_name}-fetched.xml"
    parsed_file="${xml_folder}/${api_xml_object}-${chosen_api_obj_name}-parsed.xml"

    # Strip out unwanted keys
    echo "   [parse_api_object_by_name_for_copying] Parsing ${api_xml_object} ${chosen_api_obj_name}"
    do_parsing "${fetched_file}" "${parsed_file}"
    echo "   [parse_api_object_by_name_for_copying] Created ${parsed_file}"
}

do_parsing() {
    local fetched_file="$1"
    local parsed_file="$2"

    # Strip out id, computer objects etc which are instance-specific
    grep -v '<id>' < "${fetched_file}" \
    | sed '/<computers>/,/<\/computers>/d' \
    | sed '/<mobile_devices>/,/<\/mobile_devices>/d' \
    | sed '/<users>/,/<\/users>/d' \
    | sed '/<self_service_icon>/,/<\/self_service_icon>/d' \
    | sed 's/<redeploy_on_update>Newly Assigned<\/redeploy_on_update>/<redeploy_on_update>All<\/redeploy_on_update>/g' \
    > "${parsed_file}"
}

strip_scope_from_api_object() {
    # temporary copy of parsed file
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"
    temp_parsed_file="${parsed_file/-parsed/-temp}"
    cp "$parsed_file" "$temp_parsed_file"

    # Strip out id, computer objects etc which are instance-specific
    echo "   [strip_scope_from_api_object] Stripping scope from ${api_xml_object} '${chosen_api_obj_name}'"
    sed '/<scope>/,/<\/scope>/d' < "${temp_parsed_file}" > "${parsed_file}"
}

disable_api_object() {
    # temporary copy of parsed file
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"
    temp_parsed_file="${parsed_file/-parsed/-temp}"
    cp "$parsed_file" "$temp_parsed_file"

    # disable
    echo "   [disable_api_object] Disabling ${api_xml_object} '${chosen_api_obj_name}'"
    sed 's|<enabled>true</enabled>|<enabled>false</enabled>|' < "${temp_parsed_file}" > "${parsed_file}"
}

enable_api_object() {
    # temporary copy of parsed file
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"
    temp_parsed_file="${parsed_file/-parsed/-temp}"
    cp "$parsed_file" "$temp_parsed_file"

    # enable
    echo "   [enable_api_object] Enabling ${api_xml_object} '${chosen_api_obj_name}'"
    sed 's|<enabled>false</enabled>|<enabled>true</enabled>|' < "${temp_parsed_file}" > "${parsed_file}"
}

remove_scope() {
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"

    echo "   [copy_policy] Remove-scope-only option chosen. Removing scope of '$chosen_api_obj_name'"
    # Example EmptyScopeTemplate.xml in the templates folder
    empty_scope_template="$this_script_dir/templates/EmptyScopeTemplate.xml"
    # check for a private version
    if [[ -f "$this_script_dir/templates/Private-EmptyScopeTemplate.xml" ]]; then
        empty_scope_template="$this_script_dir/templates/Private-EmptyScopeTemplate.xml"
    fi

    while read -r line || [[ -n "$line" ]]; do
        # shellcheck disable=SC2001
        sed 's|%API_OBJECT_TYPE%|'"$api_xml_object"'|' <<< "$line"
    done < "$empty_scope_template" > "${parsed_policy_file}"
}

set_payload_organisation() {
    # overwrite any existing payload organisation with a fixed value
    local new_org="$1"
    local chosen_api_obj_name="$2"
    temp_parsed_file="${parsed_file/-parsed/-temp}"
    cp "$parsed_file" "$temp_parsed_file"

    echo "   [set_payload_organisation] Changing payload organisation in '${chosen_api_obj_name}' to '${new_org}'"

    sed "s|PayloadOrganization\&lt\;\/key&gt\;\&lt\;string\&gt\;[A-Za-z ]*\&lt;\/string|PayloadOrganization\&lt;\/key\&gt\;\&lt\;string\&gt\;${new_org}\&lt\;\/string|g" < "${temp_parsed_file}" > "${parsed_file}"
}

main() {
    # -------------------------------------------------------------------------
    # MAIN BODY
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # Configure Logging
    # -------------------------------------------------------------------------

    # Logging
    if [[ ! -f "$log_file" ]]; then
        mkdir -p "$( dirname "$log_file" )"
        touch "$log_file"
    fi
    exec &> >( tee -a "$log_file" >&2 )

    # -------------------------------------------------------------------------
    # Select the API object type
    # -------------------------------------------------------------------------

    # Start menu screen here
    echo
    echo "   ---------------------------------------------------"
    echo "     JOCADS - the Jamf Object Copy and Delete Script"
    echo "   ---------------------------------------------------"
    echo
    echo "   [main] script started at $(date)"
    echo

    # default instance list type
    instance_list_type="mac"

    if [[ ! $api_xml_object ]]; then
        # Choose API object type:
        echo
        echo "API object type options:"
        echo "   A - [A]dvanced Computer Search"
        echo "   B - Advanced Mo[b]ile Device Search"
        echo "   C - [C]onfiguration Profile"
        echo "   F - Configuration Profile - [f]ix Payload Organisation"
        echo "   O - Configuration Profile - specify UUID to rescue [o]rphaned profile"
        echo "   D - Mobile [D]evice Configuration Profile"
        echo "   E - [E]xtension Attribute"
        echo "   G - Computer [G]roup"
        echo "   H - Mobile Device Group"
        echo "   I - [i]OS App Store App"
        echo "   K - Doc[k] Item"
        echo "   L or leave blank for Po[L]icy"
        echo "   M - [M]ac App Store App"
        echo "   P - [P]ackage object"
        echo "   R - [R]estricted software"
        echo "   S - [S]cript"
        echo "   T - Ca[T]egory"
        echo "   U - [U]ser"
        echo "   V - Group"
        read -r -p "Enter a letter from the above options: " api_object_type_request
        case "$api_object_type_request" in
            A|a)
                api_xml_object="advanced_computer_search"
            ;;
            B|b)
                api_xml_object="advanced_mobile_device_search"
            ;;
            G|g)
                api_xml_object="computer_group"
            ;;
            H|h)
                api_xml_object="mobile_device_group"
            ;;
            S|s)
                api_xml_object="script"
            ;;
            E|e)
                api_xml_object="computer_extension_attribute"
            ;;
            P|p)
                api_xml_object="package"
            ;;
            C|c)
                api_xml_object="os_x_configuration_profile"
            ;;
            D|d)
                api_xml_object="configuration_profile"
                instance_list_type="ios"
            ;;
            O|o)
                api_xml_object="os_x_configuration_profile"
                ask_for_uuid=1
            ;;
            F|f)
                api_xml_object="os_x_configuration_profile"
                fix_org=1
            ;;
            M|m)
                api_xml_object="mac_application"
            ;;
            I|i)
                api_xml_object="mobile_device_application"
                instance_list_type="ios"
            ;;
            R|r)
                api_xml_object="restricted_software_title"
            ;;
            T|t)
                api_xml_object="category"
                instance_list_type="ios"
            ;;
            L|l)
                api_xml_object="policy"
            ;;
            K|k)
                api_xml_object="dock_item"
            ;;
            U|u)
                api_xml_object="user"
                instance_list_type="ios"
            ;;
            V|v)
                api_xml_object="group"
                instance_list_type="ios"
            ;;
            *)
                api_xml_object="policy"
            ;;
        esac
    fi

    echo
    echo "   [main] $api_xml_object object type chosen"


    # -------------------------------------------------------------------------
    # Set the source and destination server(s) and instance(s)
    # -------------------------------------------------------------------------

    # Set default instance list
    default_instance_list_file="instance-lists/default-instance-list.txt"
    [[ -f "$default_instance_list_file" ]] && default_instance_list=$(cat "$default_instance_list_file") || default_instance_list="prd"

    # Check and create the JSS xml folder and archive folders if missing.
    xml_folder="$xml_folder_default"
    mkdir -p "${xml_folder}"
    formatted_list="${xml_folder}/formatted_list.xml"

    # ensure nothing carried over
    do_all_instances=""

    # select the instance that will be used as the source
    if [[ $source_instance_list ]]; then
        instance_list_file="$source_instance_list"
    fi
    choose_source_instance
    source_instance_list="$instance_list_file"
    default_instance_list="$source_instance_list" # reset default to match source

    # now select the destination instances
    if [[ $dest_instance_list ]]; then
        instance_list_file="$dest_instance_list"
    else
        instance_list_file=""
    fi
    choose_destination_instances

    # -------------------------------------------------------------------------
    # Process the API object to generate a list
    # -------------------------------------------------------------------------

    # determine source jss_url
    jss_url="$source_instance"

    echo
    echo "   [main] Reading $api_xml_object on '$jss_url'..."

    # check for an existing token, get a new one if required
    set_credentials "$jss_url"
    api_object_type=$( get_api_object_type "$api_xml_object" )

    # policies can be selected by category, other objects cannot
    if [[ $api_xml_object == "policy" ]]; then
        # send request
        curl_url="$jss_url/JSSResource/categories"
        curl_args=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request
    
        xmllint --format "$curl_output_file" > "${formatted_list}" 2>/dev/null

        # Set up an array for IDs and Names, which will have matching array counts.
        category_count=0

        category_choice_array=()
        category_ids=()
        category_names=()

        while IFS='' read -r line; do
            if [[ ${line} == *"<id>"* ]]; then
                category_ids[category_count]=$(echo "${line}" | awk -F '<id>|</id>' '{ print $2; exit; }')
            fi
            if [[ ${line} == *"<name>"* ]]; then
                category_names[category_count]=$(echo "${line}" | awk -F '<name>|</name>' '{ print $2; exit; }')
                category_count=$((category_count+1))
            fi
        done < "$formatted_list"

        # If policy was not selected at the command line, allow to select from category
        if [[ ! $policy_category ]]; then
            # List all possible categories
            echo
            echo "   [main] Categories :"
            echo

            for (( loop=0; loop<${#category_ids[@]}; loop++ )); do
                listed_category_name_xml_decoded="${category_names[$loop]//&amp;/&}"
                printf '   %-7s %-30s\n' "($loop)" "${listed_category_name_xml_decoded}"
                if [[ "${listed_category_name_xml_decoded}" == "${policy_testing_category}" ]]; then
                    policy_testing_category_in_list=$loop
                fi
            done

            echo
            category_choice=""
            echo "Enter the number(s) of policy category/ies, or blank for '$policy_testing_category'"
            read -r -p "   or enter 'ALL' to select all policy categories : " category_choice

            echo
            echo "   [main] Categories chosen:"
            echo

            if [[ "$category_choice" == "ALL" ]]; then
                echo
                echo "   All categories selected"
                policy_category="ALL"
            elif [[ "$category_choice" ]]; then
                for choice in $category_choice; do
                    chosen_category_name="${category_names[$choice]}"
                    echo "   [$choice] $chosen_category_name"
                    category_choice_array+=("$choice")
                done
            else
                echo "   [$policy_testing_category_in_list] $policy_testing_category"
                category_choice_array=( "$policy_testing_category_in_list" )
            fi
        fi

        echo
        # Grab all existing IDs for the policies in the chosen categories
        if [[ "${policy_category}" == "ALL" ]]; then
            echo "   [main] Reading policies in ALL categories on '${jss_url}' instance..."

            # send request
            curl_url="$jss_url/JSSResource/policies"
            curl_args=("--header")
            curl_args+=("Accept: application/xml")
            send_curl_request

            # output formatted xml to list
            xmllint --format "$curl_output_file" > "${formatted_list}"
        else
            # Clear the formatted list
            [[ -f "${formatted_list}" ]] && rm "${formatted_list}"

            for category_choice in "${category_choice_array[@]}"; do
                chosen_category_id="${category_ids[$category_choice]}"
                chosen_category_name="${category_names[$category_choice]}"

                echo "   [main] Reading policies in category '$chosen_category_name' on '${jss_url}'..."

                # send request
                curl_url="${jss_url}/JSSResource/policies/category/${chosen_category_id}"
                curl_args=("--header")
                curl_args+=("Accept: application/xml")
                send_curl_request

                # output formatted xml to list
                xmllint --format "$curl_output_file" >> "${formatted_list}"
            done
        fi
        if [[ $( grep -c "<policy>" "${formatted_list}" | awk '{ print $1 }') == "0" ]]; then
            echo
            echo "   [main] No policies found in the selected categories."
            cleanup_and_exit
        fi
    else
        # send request
        curl_url="$jss_url/JSSResource/${api_object_type}"
        curl_args=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request

        # output formatted xml to list
        xmllint --format "$curl_output_file" > "${formatted_list}"

        # accounts have to be treated differently
        if [[ $api_xml_object == "user" ]]; then
            # first we have to remove sites and groups from the list
            sed '/<site>/,/<\/site>/d' "$formatted_list"  | sed '/<groups>/,/<\/groups>/d' > "$formatted_list.tmp"
            mv "$formatted_list.tmp" "$formatted_list"
        elif  [[ $api_xml_object == "group" ]]; then
            # first we have to remove sites and users from the list
            sed '/<site>/,/<\/site>/d' "$formatted_list"  | sed '/<users>/,/<\/users>/d' > "$formatted_list.tmp"
            mv "$formatted_list.tmp" "$formatted_list"
        fi

        if [[ "$(grep -c "<$api_xml_object>" "$formatted_list" | awk '{ print $1 }')" == "0" ]]; then
            echo "   [main] No $api_xml_object found."
            cleanup_and_exit
        fi
    fi

    # Set up an array for IDs and Names, which will have matching array counts.
    api_obj_count=0
    api_obj_ids=()
    api_obj_names=()
    matches=0

    while IFS='' read -r line; do
        if [[ ${line} == *"<id>"* ]]; then
            api_obj_ids[api_obj_count]=$(echo "${line}" | awk -F '<id>|</id>' '{ print $2; exit; }')
        fi
        if [[ ${line} == *"<name>"* ]]; then
            api_obj_names[api_obj_count]=$(echo "${line}" | awk -F '<name>|</name>' '{ print $2; exit; }')
            api_obj_count=$((api_obj_count+1))
        fi
    done < "$formatted_list"

    if [[ "$inputted_api_obj_name" ]]; then
        # if supplying an object name at the command line, we want to only find an exact match
        exact_match_only="yes"
    else
        # Input an object name here, or leave blank to get a list
        echo
        echo "Enter a $api_xml_object name (full or partial, case insensitive),"
        read -r -p "or ENTER to see a list: " inputted_api_obj_name
    fi

    if [[ "$inputted_api_obj_name" ]]; then
        # if we now supplied a name (either via CLI or from prompt), look for matches
        echo
        echo "   [main] Inputted $api_xml_object name: ${inputted_api_obj_name}"
        echo

        chosen_api_obj_name=""
        inputted_api_obj_name_lowercase=$(echo "${inputted_api_obj_name}" | tr '[:upper:]' '[:lower:]')
        for (( loop=0; loop<${#api_obj_ids[@]}; loop++ )); do
            api_obj_name_lowercase=$(echo "${api_obj_names[$loop]}" | tr '[:upper:]' '[:lower:]')
            if [[ ("$api_obj_name_lowercase" == *"${inputted_api_obj_name_lowercase}"*) || "${api_obj_names[$loop]}" == "${inputted_api_obj_name}" ]]; then
                chosen_api_obj_id="${api_obj_ids[$loop]}"
                chosen_api_obj_name="${api_obj_names[$loop]}"
                matches=$((matches+1))
                api_obj_name_xml_decoded="${api_obj_names[$loop]//&amp;/&}"
                if [[ "${api_obj_names[$loop]}" == "$inputted_api_obj_name" ]]; then
                    exact_match_exists=1
                    exact_match_item="${loop}"
                fi
                # Create a fake array for the single choice
                # (will only be used if match = 1)
                api_obj_choice_list="${loop}"
                printf '   %-7s %-30s\n' "($loop)" "$api_obj_name_xml_decoded"
            fi
        done

        if [[ $exact_match_exists == 1 && $exact_match_only == "yes" ]]; then
            # if we have an exact match to that supplied at the command line, skip the selection list
            echo
            echo "   [main] Exact match is item [${exact_match_item}]."
            api_obj_choice_list="${exact_match_item}"
        elif [[ $matches -ge 1 ]]; then
            # if there is more than one match, print a selection list
            if [[ $matches -gt 1 ]]; then
                echo
                api_obj_choice=""
                read -r -p "Enter the $api_xml_object number(s), or blank to skip : " api_obj_choice_list
                if [[ -z "$api_obj_choice_list" ]]; then
                    echo
                    echo "   [main] Skipped."
                    cleanup_and_exit
                fi
            fi
        else
            if [[ $api_obj_choice_list ]]; then
                if [[ "$chosen_category_name" ]]; then
                    echo "   [main] No $api_xml_object named '$inputted_api_obj_name' found in category '$chosen_category_name' on '${source_instance}' instance. Quitting..."
                else
                    echo "   [main] No $api_xml_object named '$inputted_api_obj_name' found on '${source_instance}' instance. Quitting..."
                fi
                # Clean up
                cleanup_and_exit
            fi
        fi
    else
        # Now print the list for the user to select:
        echo
        if [[ "$chosen_category_name" ]]; then
            echo "   [main] Policies in the selected category/ies :"
        else
            echo "   [main] $api_xml_object found :"
        fi
        echo

        # pre-create a list of every item in the selection so that we can choose "ALL"
        list_of_all=()

        for (( loop=0; loop<${#api_obj_ids[@]}; loop++ )); do
            api_obj_name_xml_decoded="${api_obj_names[$loop]//&amp;/&}"
            printf '   %-7s %-30s\n' "($loop)" "$api_obj_name_xml_decoded"
            list_of_all+=("$loop")
        done

        echo
        api_obj_choice=""
        read -r -p "Enter the $api_xml_object number(s), 'ALL' to select all, or blank to skip : " api_obj_choice_list
        if [[ -z "$api_obj_choice_list" ]]; then
            echo
            echo "   [main] Skipped."
            cleanup_and_exit
        fi
    fi

    # generate the list of ALL
    if [[ $api_obj_choice_list == "ALL" ]]; then
        api_obj_choice_list="${list_of_all[*]}"
    fi

    # process list to make a proper array
    api_obj_choice_array=()

    for sel in $api_obj_choice_list; do
        if [[ $sel == *"-"* ]]; then
            list_first=$(echo "$sel" | cut -d'-' -f1)
            list_last=$(echo "$sel" | cut -d'-' -f2)
            for (( i=list_first; i<=list_last; i++ )); do
                api_obj_choice_array+=("$i")
            done
        else
            api_obj_choice_array+=("$sel")
        fi
    done

    echo
    echo "   [main] $api_xml_object items chosen:"
    echo
    for api_obj_choice in "${api_obj_choice_array[@]}"; do
        chosen_api_obj_id="${api_obj_ids[$api_obj_choice]}"
        chosen_api_obj_name="${api_obj_names[$api_obj_choice]}"
        chosen_api_obj_name_decoded=${chosen_api_obj_name//&amp;/\&}
        echo "   '$chosen_api_obj_name' (id=$chosen_api_obj_id)"
    done

    # -------------------------------------------------------------------------
    # Ask for copy or delete action
    # -------------------------------------------------------------------------

    # handler for forcing an icon update if "I" option used
    force_icon_update="no"

    # Ask to copy/delete if in interactive mode, or grab from parameters if from command line
    if [[ ! $api_obj_action ]]; then
        # Copy or delete?
        echo
        echo "Action options:"
        echo "   C  - [C]opy main object only - Safe Mode - will not check dependencies"
        echo "   Cs - [C]opy main object only - Ultra-[S]afe Mode - strips scope from object completely"
        echo "   Cd - [C]opy object including all dependencies - will ask to overwrite each dependency"
        echo "   Cn - [C]opy object including all dependencies - will overwrite each dependency without interaction ([N]o confirmations!)"
        echo "   Ci - [C]opy policy and force-overwrite the [i]con - will ask to overwrite each dependency"
        echo "   Cf - [C]opy object including all dependencies - will [f]orce-overwrite each dependency including protected/excluded items without interaction"
        echo "   R  - [R]emove scope only"
        echo "   X  - Disable object only (policy, extension attribute, mac app, iOS app)"
        echo "   E  - [E]nable object only (policy, extension attribute, mac app, iOS app)"
        echo "   D  - [D]elete object only (for packages will mount the repo and ask to delete the file)"
        read -r -p "Enter a letter from the above options: " action_question

        case "$action_question" in
            CD|Cd|cd)
                skip_dependencies="no"
                ask_for_dependencies="yes"
                api_obj_action="copy"
            ;;
            CF|Cf|cf)
                echo "   [main] Force mode selected - all items including protected items will be force-copied!"
                skip_dependencies="no"
                ask_for_dependencies="no"
                if [[ $api_xml_object == "computer_group" ]]; then
                    force_update_groups="$chosen_api_obj_name"
                    api_obj_action="copy"
                elif [[ $api_xml_object == "policy" ]]; then
                    force_update_policies="$chosen_api_obj_name"
                    api_obj_action="copy"
                fi
            ;;
            CI|Ci|ci)
                echo "   [main] Force icon mode selected - an existing icon with the same name will be replaced"
                ask_for_dependencies="yes"
                if [[ $api_xml_object == "policy" ]]; then
                    force_icon_update="yes"
                    api_obj_action="copy"
                fi
            ;;
            CN|Cn|cn)
                echo "   [main] Force copy selected - all non-protected items will be force-copied!"
                skip_dependencies="no"
                ask_for_dependencies="no"
                api_obj_action="copy"
            ;;
            CS|Cs|cs)
                echo "   [main] Ultra Safe mode selected - no object dependencies will be checked or copied, scope is unaltered"
                skip_dependencies="yes"
                strip_scope="yes"
                api_obj_action="copy"
            ;;
            C|c)
                echo "   [main] Safe mode selected - no object dependencies will be checked or copied"
                skip_dependencies="yes"
                api_obj_action="copy"
            ;;
            R|r)
                api_obj_action="copy"
                remove_scope_only="yes"
                skip_dependencies="yes"
            ;;
            X|x)
                api_obj_action="copy"
                disable_only="yes"
                skip_dependencies="yes"
            ;;
            E|e)
                api_obj_action="copy"
                enable_only="yes"
                skip_dependencies="yes"
            ;;
            D|d)
                api_obj_action="delete"
            ;;
            *)
                echo
                echo "   [main] No valid action chosen!"
                cleanup_and_exit
            ;;
        esac
    elif [[ $api_obj_action != "copy" && $api_obj_action != "delete" ]]; then
        echo
        echo "   [main] No valid action chosen!"
        cleanup_and_exit
    fi

    echo
    echo "   [main] Action selected: ${api_obj_action}"

    # removing scope only applies to certain objects # TODO - add all options
    if [[ $remove_scope_only == "yes" ]]; then
        if [[ $api_xml_object != "policy" && $api_xml_object != "mac_application" && $api_xml_object != "os_x_configuration_profile" && $api_xml_object != "configuration_profile" && $api_xml_object != "restricted_software" ]]; then
            echo
            echo "   [main] $api_xml_object cannot be chosen for the remove scope option."
            cleanup_and_exit
        fi
    fi

    # disable object only applies to certain objects # TODO - add all options
    if [[ $disable_only == "yes" || $enable_only == "yes" ]]; then
        if [[ $api_xml_object != "policy" && $api_xml_object != "mac_application" && $api_xml_object != "computer_extension_attribute" ]]; then
            echo
            echo "   [main] $api_xml_object cannot be chosen for the disable/enable object options."
            cleanup_and_exit
        fi
    fi

    # if user wishes to specify a UUID to inject into a configuration profile, ask for it here
    if [[ $ask_for_uuid == 1 && $api_obj_action == "copy" ]]; then
        echo
        read -r -p "Specify UUID to write to destination [or leave blank to skip] : " entered_uuid
    fi

    # if user wishes to specify an organisation to inject into a configuration profile, ask for it here
    if [[ $fix_org == 1 && $api_obj_action == "copy" ]]; then
        echo
        read -r -p "Specify value of PayloadOrganization to write to destination [or leave blank to skip] : " new_org
    fi

    if [[ $confirmed == "yes" ]]; then
        echo "   [main] Action confirmed from command line"
    else
        echo
        read -r -p "WARNING! This will affect the $api_xml_object on ALL chosen instances! Are you sure? (Y/N) : " are_you_sure
        case "$are_you_sure" in
            Y|y)
                echo "   [main] Confirmed"
            ;;
            *)
                cleanup_and_exit
            ;;
        esac
    fi

    # -------------------------------------------------------------------------
    # Perform action per object
    # -------------------------------------------------------------------------

    # Now loop through all the chosen objects. For each one we need to parse the chosen source instance
    for api_obj_choice in "${api_obj_choice_array[@]}"; do
        chosen_api_obj_id="${api_obj_ids[$api_obj_choice]}"
        chosen_api_obj_name="${api_obj_names[$api_obj_choice]}"
        chosen_api_obj_name_decoded=${chosen_api_obj_name//&amp;/\&}

        # Create a URL-encoded version of the API object name, we need this later...
        chosen_api_obj_name_url_encoded="$( echo "$chosen_api_obj_name" | sed -e 's|%|%25|g' | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' | sed -e 's|#|%23|g' )"

        if [[ $api_obj_action == "copy" ]]; then
            # grab the object from the source instance
            echo
            echo "   [main] Source instance: '$source_instance'"
            echo "   [main] Fetching ${api_xml_object} '$chosen_api_obj_name' (id=$chosen_api_obj_id)"

            if [[ $api_xml_object == "policy" ]]; then
                # policies require addition step of grabbing icon
                fetch_api_object_by_name "policy" "$chosen_api_obj_name"
                fetch_icon "${xml_folder}/policy-${chosen_api_obj_name}-fetched.xml"
                parse_api_object_by_name_for_copying "policy" "$chosen_api_obj_name"

            elif [[ ${api_xml_object} == "computer_group" ]]; then
                # Computer groups require getting the object by name
                fetch_api_object_by_name "computer_group" "$chosen_api_obj_name"
                parse_api_object_by_name_for_copying "computer_group" "$chosen_api_obj_name"

            elif [[ ${api_xml_object} == "mobile_device_group" ]]; then
                # Mobile device groups require getting the object by name
                fetch_api_object_by_name "mobile_device_group" "$chosen_api_obj_name"
                parse_api_object_by_name_for_copying "mobile_device_group" "$chosen_api_obj_name"
            else
                fetch_api_object "${api_xml_object}" "$chosen_api_obj_id"
                parse_api_obj_for_copying "${api_xml_object}" "$chosen_api_obj_id"
            fi
        fi

        # Now determine the destination instances to work on
        dest_instances_array=()
        if [[ $do_all_instances == "yes" ]]; then
            # create an array of multiple instances which does not include the source instance
            for instance in "${instance_choice_array[@]}"; do
                if [[ "$source_instance" != "$instance" ]]; then
                    dest_instances_array+=("$instance")
                fi
            done
            # if disabling, enabling, or remving scope, we go through all instances
            if [[ $remove_scope_only == "yes" || $disable_only == "yes" || $enable_only == "yes" ]]; then
                dest_instances_array+=("$source_instance")
            fi
            # if deleting, we go through all instances
            if [[ $api_obj_action == "delete" ]]; then
                dest_instances_array+=("$source_instance")
            fi
        else
            # create an array of multiple instances as chosen from the cli
            for instance in "${instance_choice_array[@]}"; do
                dest_instances_array+=( "$instance" )
            done
        fi

        echo "   [main] Instances to change: "
        for instance in "${dest_instances_array[@]}"; do
            echo "          $instance"
        done

        # loop through all the instances
        instance_count=1
        for dest_instance in "${dest_instances_array[@]}"; do
            # determine jss_url
            jss_url="$dest_instance"
            echo
            echo "   [main] Destination URL: $jss_url ($instance_count of ${#dest_instances_array[@]})"

            case $api_obj_action in
                delete)
                    # if deleting a package from an SMB repo, first remove the package itself (TODO - delete from S3)
                    if [[ $api_obj_action == "delete" && $api_xml_object == "package" ]]; then
                        delete_pkg "${chosen_api_obj_name}"
                    fi
                    # now delete the API object
                    if [[ $skip_delete_pkg_obj -ne 1 ]]; then
                        echo "   [main] Deleting ${api_xml_object} '$chosen_api_obj_name_decoded'"
                        delete_api_object "$api_xml_object" "$chosen_api_obj_name"
                    fi
                    ;;
                copy)
                    echo "   [main] Copying ${api_xml_object} '$chosen_api_obj_name'"
                    if [[ $strip_scope == "yes" ]]; then
                        strip_scope_from_api_object "$api_xml_object" "$chosen_api_obj_name"
                    fi
                    if [[ $api_xml_object == "policy" ]]; then
                        copy_policy "$chosen_api_obj_name" "$chosen_api_obj_id"
                    elif [[ $api_xml_object == "computer_group" ]]; then
                        if [[ $skip_dependencies == "no" ]]; then
                            check_eas_in_groups "$chosen_api_obj_name"
                            copy_groups_in_group "$chosen_api_obj_name"
                        fi
                        copy_computer_group "$chosen_api_obj_name"
                    elif [[ $api_xml_object == "mobile_device_group" ]]; then
                        if [[ $skip_dependencies == "no" ]]; then
                            check_eas_in_mobile_device_groups "$chosen_api_obj_name"
                            copy_groups_in_mobile_device_group "$chosen_api_obj_name"
                        fi
                        copy_mobile_device_group "$chosen_api_obj_name"
                    else
                        copy_api_object "$api_xml_object" "$chosen_api_obj_id" "$chosen_api_obj_name"
                    fi
                    # Send Slack notification
                    slack_text="{'username': '$jss_url', 'text': '*jocads.sh*\n*API $api_xml_object copy action*\nUser: $jss_api_user\nObject Name: *$chosen_api_obj_name*\nInstance: $jss_url\nHTTP Response: $http_response'}"
                    send_slack_notification "$slack_text"
                    ;;
            esac
            ((instance_count++))
        done
    done
}

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        --source=*)
            source_instance="${key#*=}"
            echo "   [main] CLI: Source instance: ${source_instance}"
        ;;

        -i|--source)
            shift
            source_instance="${1}"
            echo "   [main] CLI: Source instance: ${source_instance}"
        ;;

        --dest=*)
            chosen_instance="${key#*=}"
            echo "   [main] CLI: Destination instance(s): $dest_instance"
        ;;

        -di|--dest)
            shift
            chosen_instance="${1}"
            echo "   [main] CLI: Destination instance(s): $dest_instance"
        ;;

        --source-list=*)
            source_instance_list="${key#*=}"
            echo "   [main] CLI: Source instance list: $source_instance_list"
        ;;

        -il|--source-list)
            shift
            source_instance_list="${1}"
            echo "   [main] CLI: Source instance list: $source_instance_list"
        ;;

        --dest-list=*)
            dest_instance_list="${key#*=}"
            echo "   [main] CLI: Destination instance list: $dest_instance_list"
        ;;

        -dil|--dest-list)
            shift
            dest_instance_list="${1}"
            echo "   [main] CLI: Destination instance list: $dest_instance_list"
        ;;

        -c|--copy)
            echo "   [main] CLI: Action: copy"
            api_obj_action="copy"
        ;;

        -d|--delete)
            if [[ ! "$api_obj_action" ]]; then
                echo "   [main] CLI: Action: delete"
                api_obj_action="delete"
            else
                echo "   [main] CLI: Error: You can't both copy and delete at the same time!"
                echo
                exit 1
            fi
        ;;

        --force-update-groups=*)
            force_update_groups="${key#*=}"
            echo "   [main] CLI: Action: force update groups: $force_update_groups"
        ;;

        --force|--force-update-groups)
            shift
            force_update_groups="${1}"
            echo "   [main] CLI: Action: force update groups: $force_update_groups"
        ;;

        --policy=*)
            inputted_policy_name="${key#*=}"
            inputted_api_obj_name="${key#*=}"
            api_object_type="policies"
            api_xml_object="policy"
            policy_category="ALL"
            echo "   [main] CLI: Policy: $inputted_policy_name"
        ;;

        --policy)
            api_object_type="policies"
            api_xml_object="policy"
            echo "   [main] CLI: Policy: $inputted_policy_name"
        ;;

        --all)
            policy_category="ALL"
            echo "   [main] CLI: Policy Category: $policy_category"
        ;;

        --group=*)
            inputted_api_obj_name="${key#*=}"
            api_object_type="computergroups"
            api_xml_object="computer_group"
            echo "   [main] CLI: Group: $inputted_api_obj_name"
        ;;

        --group)
            api_object_type="computergroups"
            api_xml_object="computer_group"
            echo "   [main] CLI: Group: $inputted_api_obj_name"
        ;;

        --script=*)
            inputted_api_obj_name="${key#*=}"
            api_object_type="scripts"
            api_xml_object="script"
            echo "   [main] CLI: Script: $inputted_api_obj_name"
        ;;

        --script)
            api_object_type="scripts"
            api_xml_object="script"
            echo "   [main] CLI: Script: $inputted_api_obj_name"
        ;;

        --category=*)
            inputted_api_obj_name="${key#*=}"
            api_object_type="categories"
            api_xml_object="category"
            echo "   [main] CLI: Category: $inputted_api_obj_name"
        ;;

        --category)
            api_object_type="categories"
            api_xml_object="category"
            echo "   [main] CLI: Category: $inputted_api_obj_name"
        ;;

        --ea=*)
            inputted_api_obj_name="${key#*=}"
            api_object_type="computerextensionattributes"
            api_xml_object="computer_extension_attribute"
            echo "   [main] CLI: Extension Attribute: $inputted_api_obj_name"
        ;;

        --ea)
            api_object_type="computerextensionattributes"
            api_xml_object="computer_extension_attribute"
            echo "   [main] CLI: Extension Attribute: $inputted_api_obj_name"
        ;;

        --package=*)
            inputted_api_obj_name="${key#*=}"
            api_object_type="packages"
            api_xml_object="package"
            echo "   [main] CLI: Package: $inputted_api_obj_name"
        ;;

        --package)
            api_object_type="packages"
            api_xml_object="package"
            echo "   [main] CLI: Package: $inputted_api_obj_name"
        ;;

        --appstoreapp=*)
            inputted_api_obj_name="${key#*=}"
            api_object_type="macapplications"
            api_xml_object="mac_application"
            echo "   [main] CLI: Mac App Store App: $inputted_api_obj_name"
        ;;

        --appstoreapp)
            api_object_type="macapplications"
            api_xml_object="mac_application"
            echo "   [main] CLI: Mac App Store App: $inputted_api_obj_name"
        ;;

        --clean)
            echo "   [main] CLI: Action: clean up working files"
            clean_up="yes"
        ;;

        --confirm)
            echo "   [main] CLI: Action: auto-confirm copy or delete, for non-interactive use."
            confirmed="yes"
        ;;

        --dp)
            shift
            dp_url_filter="$1"
            echo "   [main] CLI: Distrivution Point filter applied: $dp_url_filter"
        ;;

        --dp=*)
            dp_url_filter="${key#*=}"
            echo "   [main] CLI: Distrivution Point filter applied: $dp_url_filter"
        ;;

        -v|--verbose)
            verbose=1
        ;;

        -h|--help)
            usage
            cleanup_and_exit
        ;;

    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# -------------------------------------------------------------------------
# Run the main function
# -------------------------------------------------------------------------

# run the main
main

# -------------------------------------------------------------------------
# Clean up at the end
# -------------------------------------------------------------------------

# Clean up
if [[ ! $clean_up ]]; then
    echo
    read -r -t 3 -p "Clean up working files? (Y/N) : " are_you_sure
    case "$are_you_sure" in
        N|n)
            exit
        ;;
        *)
            cleanup_and_exit
        ;;
    esac
else
    cleanup_and_exit
fi
