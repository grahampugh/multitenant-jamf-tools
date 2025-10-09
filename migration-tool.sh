#!/bin/bash

# --------------------------------------------------------------------------------
# JAMF MIGRATION TOOL
# A script to either save JSS config via api to XML and/or upload parsed XML to a JSS.
#
# Original Author of JSS-Config-In-A-Box:
# https://github.com/franton/JSS-Config-In-A-Box
#
# JSS-Config-In-A-Box was loosely based on the work by Jeffrey Compton:
# https://github.com/igeekjsc/JSSAPIScripts/blob/master/jssMigrationUtility.bash
#
# Adapted for new purposes by Graham Pugh @ ETH Zurich.
# 
# Adapted again for integration in the multitenant-jamf-tools repo by Graham Pugh @ JAMF.
# NOTE: unlike some of the other multitenant-jamf-tools, this script can only
# apply changes to one destination instance per run.
# --------------------------------------------------------------------------------

xmlloc_default="/Users/Shared/Jamf/Migration-Tool-Archive"
log_file="$HOME/Library/Logs/JAMF/migration-tool.log"
git_branch="tst-template"
icons_folder="$xmlloc_default/icons"

# reduce the curl tries
max_tries_override=2

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
source "_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# This script relies on the following files, which contain a list of all the API endpoints.
# Each endpoint can be commented in or out, depending on what you wish to copy.
# Note that different files are necessary because the order has to be slightly different for reading and writing.
templates_folder="${this_script_dir}/migration-tool-templates"
readfile="${templates_folder}/read_all.txt"
readlimitedfile="${templates_folder}/read_limited.txt"
wipefile="${templates_folder}/wipe_all.txt"
writefile="${templates_folder}/write_all.txt"
writelimitedfile="${templates_folder}/write_limited.txt"
writeiosfile="${templates_folder}/write_ios.txt"

# -------------------------------------------------------------------------
# FUNCTIONS
# -------------------------------------------------------------------------

check_xml_folder() {
    # Determine the storage directory
    if [[ ! "$xmlloc" ]]; then
        xmlloc="$xmlloc_default"
    fi

    # Check and create the JSS xml folder and archive folders if missing
    if [[ ! -d "$xmlloc" ]]; then
        mkdir -p "$xmlloc"
    else
        # if the storage directory is a git archive, make sure it's synced
        if [[ -d "$xmlloc/.git" ]]; then
            git -C "$xmlloc" checkout $git_branch
            git -C "$xmlloc" pull
        else
            if [[ -z $archive ]]; then
                echo
                read -r -p "Do you wish to archive existing xml files? (Y/N) : " archive
                if [[ "$archive" = "y" ]] || [[ "$archive" = "Y" ]];
                then
                    archive="YES"
                else
                    archive="NO"
                fi
            fi
        fi
    fi

    # Check for existing items, archiving if necessary.
    for (( loop=0; loop<${#readfiles[@]}; loop++ ))
    do
        if [[ "$archive" == "YES" ]]; then
            if [[ $(ls -1 "$xmlloc"/"${readfiles[$loop]}"/* 2>/dev/null | wc -l) -gt 0 ]]; then
                echo
                echo "   [check_xml_folder] Archiving API endpoint: ${readfiles[$loop]}"
                ditto -ck "$xmlloc/${readfiles[$loop]}" "$xmlloc/archives/${readfiles[$loop]}-$( date +%Y%m%d%H%M%S ).zip"
                rm -rf "${xmlloc:?}/${readfiles[$loop]}"
            fi
        fi

        # Check and create the JSS xml resource folders if missing.
        if [[ ! -f "$xmlloc/${readfiles[$loop]}" ]]; then
            mkdir -p "$xmlloc/${readfiles[$loop]}/id_list"
            mkdir -p "$xmlloc/${readfiles[$loop]}/fetched_xml"
            mkdir -p "$xmlloc/${readfiles[$loop]}/parsed_xml"
        fi
    done
}

setup_the_action() {
    # Set default instance list
    default_instance_list_file="instance-lists/default-instance-list.txt"
    [[ -f "$default_instance_list_file" ]] && default_instance_list=$(cat "$default_instance_list_file") || default_instance_list="prd"

    # Check and create the JSS xml folder and archive folders if missing.
    xml_folder="$xml_folder_default"
    mkdir -p "${xml_folder}"
    formatted_list="${xml_folder}/formatted_list.xml"

    # ensure nothing carried over
    do_all_instances=""

    # select the instance that the action will be performed on
    if [[ $source_instance_list ]]; then
        instance_list_file="$source_instance_list"
    fi
    choose_source_instance
    source_instance_list="$instance_list_file"
    default_instance_list="$source_instance_list" # reset default to match source

    # if [[ "$action_type" != "download" ]]; then
    #     # now select the destination instances
    #     if [[ $dest_instance_list ]]; then
    #         instance_list_file="$dest_instance_list"
    #     else
    #         instance_list_file=""
    #     fi
    #     choose_destination_instances
    # fi
}

grab_existing_jss_xml() {
    # determine source jss_url
    jss_url="$source_instance"

    # Print our settings
    echo
    echo "   [grab_existing_jss_xml] Server: $jss_url"
    echo

    if [[ -d "$xmlloc/.git" ]]; then
        git -C "$xmlloc" checkout $git_branch
        git -C "$xmlloc" pull
    fi
    
    # Loop around the array of JSS endpoints we set up earlier.
    for (( loop=0; loop<${#readfiles[@]}; loop++ ))
    do
        # Set our result incremental variable to 1
        resultInt=1

        # Work out where things are going to be stored on this loop
        # instance_loc=$(sed 's|https://||' <<< "$jss_url" | sed 's|/|_|g' | sed 's|\.|_|g')
        formattedList="$xmlloc/${readfiles[$loop]}/id_list/formattedList.xml"
        plainList="$xmlloc/${readfiles[$loop]}/id_list/plainList.txt"
        plainListAccountsUsers="$xmlloc/${readfiles[$loop]}/id_list/plainListAccountsUsers.txt"
        plainListAccountsGroups="$xmlloc/${readfiles[$loop]}/id_list/plainListAccountsGroups.txt"
        fetchedResult="$xmlloc/${readfiles[$loop]}/fetched_xml/result-$resultInt.xml"
        fetchedResultAccountsUsers="$xmlloc/${readfiles[$loop]}/fetched_xml/userResult-$resultInt.xml"
        fetchedResultAccountsGroups="$xmlloc/${readfiles[$loop]}/fetched_xml/groupResult-$resultInt.xml"

        # ensure all the directories exist
        mkdir -p "$xmlloc/${readfiles[$loop]}/id_list" "$xmlloc/${readfiles[$loop]}/fetched_xml"

        # Grab all existing ID's for the current API endpoint we're processing
        echo
        echo "   [grab_existing_jss_xml] Creating ID list for ${readfiles[$loop]} on ${jss_url}"
        # echo "using $jss_url/JSSResource/${readfiles[$loop]} with user $origjssapiuser:$origjssapipwd"

        # check for an existing token, get a new one if required
        set_credentials "$jss_url"

        # send request
        curl_url="$jss_url/JSSResource/${readfiles[$loop]}"
        curl_args=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request

        # cat "$curl_output_file"  ## TEMP
        # echo ## TEMP
        # echo "$formattedList" ## TEMP

        # format the output into a file
        xmllint --format "$curl_output_file" 2>/dev/null > "$formattedList"

        if [[ ${readfiles[$loop]} == "accounts" ]]; then
            # Accounts have to be treated differently
            if [[ $(grep -c "<users/>" "$formattedList") == "0" ]]; then
                echo
                echo "   [grab_existing_jss_xml] Creating plain list of user ID's..."
                sed '/<site>/,/<\/site>/d' "$formattedList" | sed '/<groups>/,/<\/groups>/d' | awk -F '<id>|</id>' '/<id>/ {print $2}' > "$plainListAccountsUsers"
            else
                rm "$formattedList"
            fi

            if [[ $(grep -c "<groups/>" "$formattedList") == "0" ]]; then
                echo
                echo "   [grab_existing_jss_xml] Creating plain list of group ID's..."
                sed '/<site>/,/<\/site>/d' "$formattedList" | sed '/<users>/,/<\/users>/d' | awk -F '<id>|</id>' '/<id>/ {print $2}' > "$plainListAccountsGroups"
            else
                rm "$formattedList"
            fi

        elif [[ ${readfiles[$loop]} == "smtpserver" || ${readfiles[$loop]} == "activationcode" || ${readfiles[$loop]} == "computerinventorycollection" ]]; then
            echo
            echo "   [grab_existing_jss_xml] Parsing ${readfiles[$loop]}"
            cat "$formattedList" > "$xmlloc/${readfiles[$loop]}/parsed_xml/parsed_result1.xml"

        else
            if [[ $(grep -c "<size>0" "$formattedList") == "0" ]]; then
                echo
                echo "   [grab_existing_jss_xml] Creating a plain list of ${readfiles[$loop]} ID's  "
                awk -F'<id>|</id>' '/<id>/ {print $2}' "$formattedList" > "$plainList"
            else
                rm "$formattedList"
            fi
        fi

        # Work out how many IDs are present IF formattedlist is present. Grab and download each one for the specific search we're doing. Special code for accounts because the API is annoyingly different from the rest.
        files=("$xmlloc/${readfiles[$loop]}"/id_list/*)
        
        if [[ ${#files[@]} -gt 0 ]]; then
            # echo "${readfiles[$loop]]}" ## TEMP
            case "${readfiles[$loop]}" in
                accounts)
                    totalFetchedIDsUsers=$( wc -l < "$plainListAccountsUsers" | sed -e 's/^[ \t]*//' )
                    while IFS= read -r userID; do
                        echo
                        echo "   [grab_existing_jss_xml] Downloading User ID number $userID ($resultInt/$totalFetchedIDsUsers)"

                        # determine source jss_url
                        jss_url="$source_instance"
                        # check for an existing token, get a new one if required
                        set_credentials "$jss_url"

                        # send request
                        curl_url="$jss_url/JSSResource/${readfiles[$loop]}/userid/$userID"
                        curl_args=("--header")
                        curl_args+=("Accept: application/xml")
                        send_curl_request

                        # format the output
                        fetchedResultAccountsUsers=$(xmllint --format "$curl_output_file" 2>/dev/null)

                        # itemID=$( echo "$fetchedResultAccountsUsers" | grep "<id>" | awk -F '<id>|</id>' '{ print $2; exit; }')
                        # itemName=$( echo "$fetchedResultAccountsUsers" | grep "<name>" | awk -F '<name>|</name>' '{ print $2; exit; }')
                        # cleanedName=$( echo "$itemName" | sed 's/[:\/\\]//g' )
                        echo "$fetchedResultAccountsUsers" > "$xmlloc/${readfiles[$loop]}/fetched_xml/user_$resultInt.xml"

                        resultInt=$((resultInt + 1))
                    done < "$plainListAccountsUsers"

                    resultInt=1

                    totalFetchedIDsGroups=$( wc -l < "$plainListAccountsGroups" | sed -e 's/^[ \t]*//' )
                    while IFS= read -r groupID; do
                        echo
                        echo "   [grab_existing_jss_xml] Downloading Group ID number $groupID ($resultInt/$totalFetchedIDsGroups)"

                        # determine source jss_url
                        jss_url="$source_instance"
                        # check for an existing token, get a new one if required
                        set_credentials "$jss_url"

                        # send request
                        curl_url="$jss_url/JSSResource/${readfiles[$loop]}/groupid/$groupID"
                        curl_args=("--header")
                        curl_args+=("Accept: application/xml")
                        send_curl_request

                        # format the output
                        fetchedResultAccountsGroups=$(xmllint --format "$curl_output_file" 2>/dev/null)

                        # itemID=$( echo "$fetchedResultAccountsGroups" | grep "<id>" | awk -F '<id>|</id>' '{ print $2; exit; }')
                        # itemName=$( echo "$fetchedResultAccountsGroups" | grep "<name>" | awk -F '<name>|</name>' '{ print $2; exit; }')
                        # cleanedName=$( echo "$itemName" | sed 's/[:\/\\]//g' )
                        echo "$fetchedResultAccountsGroups" > "$xmlloc/${readfiles[$loop]}/fetched_xml/group_$resultInt.xml"

                        resultInt=$((resultInt + 1))
                    done < "$plainListAccountsGroups"
                ;;

                smtpserver|activationcode)
                    echo
                    echo "   [grab_existing_jss_xml] No additional downloading required for: ${readfiles[$loop]}"
                ;;

                *)
                    if [[ -f "$plainList" ]]; then
                        totalFetchedIDs=$(wc -l < "$plainList" | sed -e 's/^[ \t]*//')

                        while IFS= read -r apiID; do
                            echo
                            echo "   [grab_existing_jss_xml] Downloading ID number $apiID ($resultInt/$totalFetchedIDs)"

                            # determine source jss_url
                            jss_url="$source_instance"
                            # check for an existing token, get a new one if required
                            set_credentials "$jss_url"

                            # send request
                            curl_url="$jss_url/JSSResource/${readfiles[$loop]}/id/$apiID"
                            curl_args=("--header")
                            curl_args+=("Accept: application/xml")
                            send_curl_request

                            # format the output into a file
                            xmllint --format "$curl_output_file" 2>/dev/null > "$fetchedResult"

                            resultInt=$((resultInt + 1))
                            fetchedResult="$xmlloc/${readfiles[$loop]}/fetched_xml/result-$resultInt.xml"
                        done < "$plainList"
                    else
                        echo
                        echo "   [grab_existing_jss_xml] No "${readfiles[$loop]}" items found"
                    fi
                ;;
            esac

            # Depending which API endpoint we're dealing with, parse the grabbed files into something we can upload later.
            case "${readfiles[$loop]}" in
                computergroups|mobiledevicegroups)
                    echo
                    echo "   [grab_existing_jss_xml] Parsing ${readfiles[$loop]}"

                    for fetched_file in "$xmlloc/${readfiles[$loop]}"/fetched_xml/*; do
                        [[ -f "$fetched_file" ]] || break  # handle the case of no matching files
                        echo "   [grab_existing_jss_xml] Parsing group: $fetched_file"

                        if grep -q "<is_smart>false</is_smart>" "$fetched_file"; then
                            if [[ "${readfiles[$loop]}" == "computergroups" ]]; then
                                echo "   [grab_existing_jss_xml] $fetched_file is a static computer group"
                                parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/static_group_parsed_"$(basename "$fetched_file")
                                grep -v '<id>' "$fetched_file" | sed '/<computers>/,/<\/computers/d' > "$parsed_file"
                            elif  [[ "${readfiles[$loop]}" == "mobiledevicegroups" ]]; then
                                echo "   [grab_existing_jss_xml] $fetched_file is a static mobile device group"
                                parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/static_group_parsed_"$(basename "$fetched_file")
                                grep -v '<id>' "$fetched_file" | sed '/<mobile_devices>/,/<\/mobile_devices/d' > "$parsed_file"
                            fi
                        else
                            if [[ "${readfiles[$loop]}" == "computergroups" ]]; then
                                echo "   [grab_existing_jss_xml] $fetched_file is a smart computer group..."
                                parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/smart_group_parsed_"$(basename "$fetched_file")
                                grep -v '<id>' "$fetched_file" | sed '/<computers>/,/<\/computers/d' > "$parsed_file"
                            elif  [[ "${readfiles[$loop]}" == "mobiledevicegroups" ]]; then
                                echo "   [grab_existing_jss_xml] $fetched_file is a smart mobile device group..."
                                parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/smart_group_parsed_"$(basename "$fetched_file")
                                grep -v '<id>' "$fetched_file" | sed '/<mobile_devices>/,/<\/mobile_devices/d' > "$parsed_file"
                            fi
                        fi
                    done
                ;;

                policies)
                    echo
                    echo "   [grab_existing_jss_xml] Parsing ${readfiles[$loop]}"

                    for fetched_file in "$xmlloc/${readfiles[$loop]}"/fetched_xml/*; do
                        [[ -f "$fetched_file" ]] || break  # handle the case of no matching files
                        echo
                        echo "   [grab_existing_jss_xml] Parsing policy: $fetched_file"

                        if grep -q "<name>No category assigned</name>" "$fetched_file"; then
                            echo "   [grab_existing_jss_xml] Policy $fetched_file is not assigned to a category. Ignoring."
                        else
                            echo "   [grab_existing_jss_xml] Processing policy file $fetched_file"
                            # download the icon before we delete it from the xml!
                            fetch_icon "$fetched_file"
                            parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/parsed_"$(basename "$fetched_file")
                            grep -v '<id>' "$fetched_file" | sed  '/<self_service_icon>/,/<\/self_service_icon>/d' | sed '/<computers>/,/<\/computers>/d' | sed  '/<limit_to_users>/,/<\/limit_to_users>/d' | sed '/<users>/,/<\/users>/d' | sed '/<user_groups>/,/<\/user_groups>/d' > "$parsed_file"
                        fi
                    done
                ;;

                restrictedsoftware)
                    echo
                    echo "   [grab_existing_jss_xml] Parsing ${readfiles[$loop]}"

                    for fetched_file in "$xmlloc/${readfiles[$loop]}"/fetched_xml/*; do
                        [[ -f "$fetched_file" ]] || break  # handle the case of no matching files
                        echo
                        echo "   [grab_existing_jss_xml] Parsing item: $fetched_file"
                        parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/parsed_"$(basename "$fetched_file")
                        grep -v '<id>' "$fetched_file" | sed '/<computers>/,/<\/computers>/d' | sed '/<limit_to_users>/,/<\/limit_to_users>/d' | sed '/<users>/,/<\/users>/d' | sed '/<user_groups>/,/<\/user_groups>/d' > "$parsed_file"
                    done
                ;;

                ldapservers|distributionpoints)
                    echo
                    echo "   [grab_existing_jss_xml] Parsing: ${readfiles[$loop]}."

                    for fetched_file in "$xmlloc/${readfiles[$loop]}"/fetched_xml/*; do
                        [[ -f "$fetched_file" ]] || break  # handle the case of no matching files
                        echo
                        echo "   [grab_existing_jss_xml] Parsing $fetched_file"
                        parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/parsed_"$(basename "$fetched_file")
                        grep -v '<id>' "$fetched_file" | sed -e "s|<password_sha256.*|<password>${ldap_password}</password>|" | sed -e "s|<ssh_password_sha256.*|<ssh_password>${smb_pass}</ssh_password>|" | sed -e "s|<read_only_password_sha256.*|<read_only_password>${smb_readonly_pass}</read_only_password>|" | sed -e "s|<read_write_password_sha256.*|<read_write_password>${smb_pass}</read_write_password>|" | sed -e "s|<http_password_sha256.*|<http_password>${smb_readonly_pass}</http_password>|" > "$parsed_file"
                    done
                ;;

                smtpserver|activationcode)
                    echo
                    echo "   [grab_existing_jss_xml] No special parsing needed for: ${readfiles[$loop]}."
                ;;

                *)
                    echo
                    echo "   [grab_existing_jss_xml] No special parsing needed for: ${readfiles[$loop]}."

                    for fetched_file in "$xmlloc/${readfiles[$loop]}"/fetched_xml/*; do
                        [[ -f "$fetched_file" ]] || break  # handle the case of no matching files
                        echo
                        echo "   [grab_existing_jss_xml] Parsing $fetched_file"
                        parsed_file="$xmlloc/${readfiles[$loop]}/parsed_xml/parsed_"$(basename "$fetched_file")
                        grep -v '<id>' "$fetched_file" > "$parsed_file"
                    done
                ;;
            esac
        else
            echo
            echo "   [grab_existing_jss_xml] Resource ${readfiles[$loop]} empty. Skipping."
        fi
    done
    # write to git
    if [[ -d "$xmlloc/.git" ]];
    then
        git -C "$xmlloc" add --all
        git_date=$(date)
        git -C "$xmlloc" commit -m "Updated at $git_date"
        git -C "$xmlloc" push
    fi
}

fetch_icon() {
    local fetchedFile="$1"

    # get icon details from fetched xml
    icon_filename=$( xmllint --xpath '//self_service/self_service_icon/filename/text()' "${fetchedFile}" 2>/dev/null )
    # if [[ "$icon_filename" ]]; then
    #     echo "   [fetch_icon] Icon name found: $icon_filename"
    # fi
    icon_url=$( xmllint --xpath '//self_service/self_service_icon/uri/text()' "${fetchedFile}" 2>/dev/null )
    # if [[ "$icon_url" ]]; then
    #     echo "   [fetch_icon] Icon URL found: $icon_url"
    # fi

    # download icon to local folder
    if [[ $icon_filename && $icon_url ]]; then
        echo "   [fetch_icon] Downloading $icon_filename from $icon_url"

        # determine source jss_url
        jss_url="$source_instance"
        # check for an existing token, get a new one if required
        set_credentials "$jss_url"

        # send request
        curl_url="$icon_url"
        send_curl_request

        # copy icon to final icon location
        cp "$curl_output_file" "$icons_folder/$icon_filename"
    else
        echo "   [fetch_icon] No icon in this policy"
    fi
}

wipe_jss() {
    # THIS IS YOUR LAST CHANCE TO PUSH THE CANCELLATION BUTTON

    # determine source jss_url
    jss_url="$source_instance"

    echo
    echo "This action will erase items on $jss_url."
    echo "Are you utterly sure you want to do this?"
    read -r -p "(Default is NO. Type YES to go ahead) : " arewesure

    # Check for the skip
    if [[ $arewesure != "YES" ]]; then
        echo
        echo "Ok, skipping the wipe."
        return
    fi

    # OK DO IT

    for (( loop=0; loop<${#wipefiles[@]}; loop++ )); do
        if [[ "${wipefiles[$loop]}" == "accounts" ]]; then
            echo
            echo "   [wipe_jss] Skipping ${wipefiles[$loop]} API endpoint. Or we can't get back in!"
        elif [[ ${wipefiles[$loop]} == "smtpserver" || ${wipefiles[$loop]} == "activationcode" || ${wipefiles[$loop]} == "computerinventorycollection" ]]; then
            echo
            echo "   [wipe_jss] Skipping ${wipefiles[$loop]} API endpoint as no delete option is available via API."
        else
            # Set our result incremental variable to 1
            resultInt=1

            # Grab all existing ID's for the current API endpoint we're processing
            echo
            echo "   [wipe_jss] Processing ID list for ${wipefiles[$loop]}"
            echo "   [wipe_jss] Dest: $jss_url"

            # check for an existing token, get a new one if required
            set_credentials "$jss_url"

            # send request
            curl_url="$jss_url/JSSResource/${wipefiles[$loop]}"
            curl_args=("--header")
            curl_args+=("Accept: application/xml")
            send_curl_request

            # format the output into a file
            xmllint --format "$curl_output_file" 2>/dev/null > "${xmlloc}/unprocessedid.txt"

            # Check if any ids have been captured. Skip if none present.
            check=$(grep -c "<size>0</size>" "${xmlloc}/unprocessedid.txt")

            if [[ "$check" == "0" ]]; then
                # What are we deleting?
                echo
                echo "   [wipe_jss] Deleting ${wipefiles[$loop]}"

                # Process all the item id numbers
                awk -F '<id>|</id>' '/<id>/ {print $2}' "${xmlloc}/unprocessedid.txt" > "${xmlloc}/processedid.txt"

                # Delete all the item id numbers
                totalFetchedIDs=$( wc -l < "${xmlloc}/processedid.txt" | sed -e 's/^[ \t]*//' )

                while read -r line; do
                    echo
                    echo "   [wipe_jss] Deleting ID number $line ($resultInt/$totalFetchedIDs)"

                    # send request
                    curl_url="$jss_url/JSSResource/${wipefiles[$loop]}/id/$line"
                    curl_args=("--request")
                    curl_args+=("DELETE")
                    curl_args+=("--header")
                    curl_args+=("Accept: application/xml")
                    send_curl_request

                    resultInt=$((resultInt + 1))
                done < "${xmlloc}/processedid.txt"
            else
                echo
                echo "   [wipe_jss] API endpoint ${wipefiles[$loop]} is empty. Skipping."
            fi
        fi
    done
}

put_on_new_jss() {
    echo
    echo "   [put_on_new_jss] Writing to $jss_url"

    for (( loop=0; loop<${#writefiles[@]}; loop++ )); do
        if [[ $(ls -1 "$xmlloc/${writefiles[$loop]}/parsed_xml"/* 2>/dev/null | wc -l) -gt 0 ]]; then
            # Set our result incremental variable to 1
            resultInt=1
            echo
            echo
            echo "   [put_on_new_jss] Posting ${writefiles[$loop]} to JSS instance: $jss_url"

            # determine source jss_url
            jss_url="$source_instance"
            # check for an existing token, get a new one if required
            set_credentials "$jss_url"

            # get XML object name from object type (URL style)
            api_xml_object=$(get_api_object_from_type "${writefiles[$loop]}")
            api_xml_object_plural=$(get_plural_from_api_xml_object "$api_xml_object")

            case "${writefiles[$loop]}" in
                accounts)
                    echo
                    echo "   [put_on_new_jss] Posting user accounts."

                    totalParsedResourceXML_user=$( ls $xmlloc/${writefiles[$loop]}/parsed_xml/*user* | wc -l | sed -e 's/^[ \t]*//' )
                    postInt_user=0

                    for xmlPost_user in "$xmlloc/${writefiles[$loop]}/parsed_xml"/*user*; do
                        (( postInt_user++ ))
                        echo
                        echo
                        echo "   [put_on_new_jss] Posting User Account $postInt_user/$totalParsedResourceXML_user '$xmlPost_user' from $(basename "$xmlPost_user")"

                        # send request
                        curl_url="$jss_url/JSSResource/accounts/userid/0"
                        curl_args=("--header")
                        curl_args+=("Content-Type: application/xml")
                        curl_args+=("--data-binary")
                        curl_args+=(@"$xmlPost_user")
                        send_curl_request
                    done

                    echo
                    echo "   [put_on_new_jss] Posting user group accounts."

                    totalParsedResourceXML_group=$( ls "$xmlloc/${writefiles[$loop]}/parsed_xml"/*group* | wc -l | sed -e 's/^[ \t]*//' )
                    postInt_group=0

                    for xmlPost_group in "$xmlloc/${writefiles[$loop]}/parsed_xml/"*group*; do
                        (( postInt_group++ ))
                        echo
                        echo
                        echo "   [put_on_new_jss] Posting User Group $postInt_group/$totalParsedResourceXML_group '$xmlPost_group' from $(basename "$xmlPost_group")"

                        # send request
                        curl_url="$jss_url/JSSResource/accounts/groupid/0"
                        curl_args=("--header")
                        curl_args+=("Content-Type: application/xml")
                        curl_args+=("--data-binary")
                        curl_args+=(@"$xmlPost_group")
                        send_curl_request
                    done
                ;;

                computergroups|mobiledevicegroups)
                    echo
                    echo "   [put_on_new_jss] Posting static groups."

                    # grab a list of existing groups
                    curl_url="$jss_url/JSSResource/${writefiles[$loop]}"
                    curl_args=("--header")
                    curl_args+=("Accept: application/xml")
                    send_curl_request

                    # save the output file
                    instance_check_file="$xmlloc/${writefiles[$loop]}/$(basename "$jss_url").output.txt"
                    xmllint --format "$curl_output_file" 2>/dev/null > "$instance_check_file"

                    totalParsedResourceXML_staticGroups=$( ls "$xmlloc/${writefiles[$loop]}/parsed_xml/"static_group_parsed* | wc -l | sed -e 's/^[ \t]*//' )
                    postInt_static=0

                    for parsedXML_static in "$xmlloc/${writefiles[$loop]}/parsed_xml"/static_group_parsed*; do
                        (( postInt_static++ ))
                        # look for existing group and update it rather than create a new one if it exists
                        source_name="$( grep "<name>" < "$parsedXML_static" | head -n 1 | awk -F '<name>|</name>' '{ print $2; exit; }' | sed -e 's|&amp;|\&|g' )"
                        # source_name_urlencode="$( echo "$source_name" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"

                        echo
                        echo "   [put_on_new_jss] Posting Static Group $postInt_static/$totalParsedResourceXML_staticGroups '$source_name' from $(basename "$parsedXML_static")"

                        # get id from output
                        existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = \"$source_name\"]/id/text()" "$instance_check_file" 2>/dev/null)

                        if [[ $existing_id ]]; then
                            echo
                            echo "   [put_on_new_jss] Static group '$source_name' already exists - not overwriting..."
                        else
                            # send request
                            curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/0"
                            curl_args=("--request")
                            curl_args+=("POST")
                            curl_args+=("--header")
                            curl_args+=("Content-Type: application/xml")
                            curl_args+=("--data-binary")
                            curl_args+=(@"$parsedXML_static")
                            send_curl_request

                            # slow down to allow Jamf Pro 10.39+ to to its thing
                            sleep 2
                        fi
                    done

                    echo
                    echo "   [put_on_new_jss] Posting smart groups"

                    totalParsedResourceXML_smartGroups=$(ls $xmlloc/${writefiles[$loop]}/parsed_xml/smart_group_parsed* | wc -l | sed -e 's/^[ \t]*//')
                    postInt_smart=0

                    for parsedXML_smart in "$xmlloc/${writefiles[$loop]}/parsed_xml"/smart_group_parsed*; do
                        (( postInt_smart++ ))
                        # look for existing entry and update it rather than create a new one if it exists
                        source_name="$( grep "<name>" < "$parsedXML_smart" | head -n 1 | awk -F '<name>|</name>' '{ print $2; exit; }' | sed -e 's|&amp;|\&|g' )"

                        echo
                        echo "   [put_on_new_jss] Posting Smart Group $postInt_smart/$totalParsedResourceXML_smartGroups '$source_name' from $(basename "$parsedXML_smart")"

                        # get id from output
                        existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = \"$source_name\"]/id/text()" "$instance_check_file" 2>/dev/null)

                        if [[ $existing_id ]]; then
                            if [[ $overwrite_items == "yes" ]]; then
                                # We only want to replace certain smart groups, namely those with "test version installed" or "current version installed" in their name.
                                # if [[ "$source_name" == *"version installed"*  ]]; then # TEMP DISABLE
                                    echo
                                    echo "   [put_on_new_jss] Smart Group '$source_name' can be replaced"
                                    echo

                                    # send request
                                    curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/$existing_id"
                                    curl_args=("--request")
                                    curl_args+=("PUT")
                                    curl_args+=("--header")
                                    curl_args+=("Content-Type: application/xml")
                                    curl_args+=("--data-binary")
                                    curl_args+=(@"$parsedXML_smart")
                                    send_curl_request

                                    # slow down to allow Jamf Pro 10.39+ to to its thing
                                    sleep 2
                            else
                                echo "   [put_on_new_jss] Smart Group '$source_name' already exists... skipping"
                            fi
                        else
                            # send request
                            curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/0"
                            curl_args=("--request")
                            curl_args+=("POST")
                            curl_args+=("--header")
                            curl_args+=("Content-Type: application/xml")
                            curl_args+=("--data-binary")
                            curl_args+=(@"$parsedXML_smart")
                            send_curl_request

                            # slow down to allow Jamf Pro 10.39+ to to its thing
                            sleep 2
                        fi
                    done
                ;;

                smtpserver|activationcode|computerinventorycollection)
                    echo
                    echo "   [put_on_new_jss] Posting $parsedXML ($postInt/$totalParsedResourceXML)"
                    for parsedXML in "$xmlloc/${writefiles[$loop]}/parsed_xml/"*.xml; do
                        # look for name
                        source_name="$( grep "<name>" < "$parsedXML" | head -n 1 | awk -F '<name>|</name>' '{ print $2; exit; }' | sed -e 's|&amp;|\&|g' )"

            
                        echo
                        echo "   [put_on_new_jss] Posting ${writefiles[$loop]} $postInt/$totalParsedResourceXML '$source_name' from $(basename "$parsedXML")"

                        # send request
                        curl_url="$jss_url/JSSResource/${writefiles[$loop]}"
                        curl_args=("--request")
                        curl_args+=("PUT")
                        curl_args+=("--header")
                        curl_args+=("Content-Type: application/xml")
                        curl_args+=("--data-binary")
                        curl_args+=(@"$parsedXML")
                        send_curl_request
                    done
                ;;

                policies)
                    totalParsedResourceXML=$(ls $xmlloc/${writefiles[$loop]}/parsed_xml | wc -l | sed -e 's/^[ \t]*//')
                    postInt=0

                    # grab a list of existing policies
                    curl_url="$jss_url/JSSResource/${writefiles[$loop]}"
                    curl_args=("--header")
                    curl_args+=("Accept: application/xml")
                    send_curl_request

                    # save the output file
                    instance_check_file="$xmlloc/${writefiles[$loop]}/$(basename "$jss_url").output.txt"
                    xmllint --format "$curl_output_file" 2>/dev/null > "$instance_check_file"

                    for parsedXML in "$xmlloc/${writefiles[$loop]}/parsed_xml/"*.xml; do
                        (( postInt++ ))

                        # look for existing policy and update it rather than create a new one if it exists
                        # Re-add icon from local source - first get the policy name from the parsed XML
                        source_name="$( xmllint --xpath //general/name "$parsedXML" | awk -F '<name>|</name>' '{ print $2; exit; }' | sed -e 's|&amp;|\&|g' )"
                        # source_name_urlencode="$( echo "$source_name" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"

                        echo
                        echo "   [put_on_new_jss] Posting ${writefiles[$loop]} $postInt/$totalParsedResourceXML '$source_name' from $(basename "$parsedXML")"

                        # get id from output
                        existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = \"$source_name\"]/id/text()" "$instance_check_file" 2>/dev/null)

                        if [[ $existing_id ]]; then
                            if [[ $overwrite_items == "yes" ]]; then
                                echo "   [put_on_new_jss] ${writefiles[$loop]} '$source_name' already exists (ID=$existing_id)... overwriting"
                                # send request
                                curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/$existing_id"
                                curl_args=("--request")
                                curl_args+=("PUT")
                                curl_args+=("--header")
                                curl_args+=("Content-Type: application/xml")
                                curl_args+=("--data-binary")
                                curl_args+=(@"$parsedXML")
                                send_curl_request
                            else
                                echo "   [put_on_new_jss] policy '$source_name' already exists... skipping"
                            fi
                        else
                            # existing policy not found, creating new one
                            # send request
                            curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/0"
                            curl_args=("--request")
                            curl_args+=("POST")
                            curl_args+=("--header")
                            curl_args+=("Content-Type: application/xml")
                            curl_args+=("--data-binary")
                            curl_args+=(@"$parsedXML")
                            send_curl_request
                        fi

                        # Re-add icon from local source - first get the icon name from the source policy (if there is one, otherwise skip)
                        # Since we already extracted the icon in the parsed file, we need to use the original fetched file for this. The numbers of the fetched and parsed files are the same so we can use this to get the correct fetched file.
                        parsingNumber=$( basename "${parsedXML}" | sed -e 's/^[^-]*-//' | sed -e 's/\.xml//' )
                        fetchedXMLFile="${xmlloc}/${writefiles[$loop]}/fetched_xml/result-${parsingNumber}.xml"
                        icon_name="$( xmllint --xpath //self_service/self_service_icon/filename "$fetchedXMLFile" | awk -F '<filename>|</filename>' '{ print $2; exit; }' )"
                        if [[ $icon_name ]]; then
                            echo
                            echo "   [put_on_new_jss] Icon name: $icon_name"

                            # If an icon exists in our repo that doesn't match the icon in an existing policy, upload it.
                            # Method thanks to https://list.jamfsoftware.com/jamf-nation/discussions/23231/mass-icon-upload
                            if [[ -f "$icons_folder/$icon_name" ]]; then
                                echo
                                 echo "   [put_on_new_jss] Matching icon found: $icons_folder/$icon_name"

                                # To upload the file we need to know the policy number that was just created.
                                # To do this we submit a request based on the policy name
                                policy_name="$( xmllint --xpath //general/name "$parsedXML" | awk -F '<name>|</name>' '{ print $2; exit; }' )"
                                policy_name_urlencode="$( echo "$policy_name" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"

                                echo
                                echo "   [put_on_new_jss] URL: $jss_url/JSSResource/policies/name/$policy_name_urlencode"

                                # send request
                                curl_url="$jss_url/JSSResource/${writefiles[$loop]}"
                                curl_args=("--header")
                                curl_args+=("Accept: application/xml")
                                send_curl_request

                                # get id from output
                                policy_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = \"$policy_name\"]/id/text()" "$curl_output_file" 2>/dev/null)

                                echo
                                echo "   [put_on_new_jss] Policy number $policy_id identified..."

                                # Let's see if there is already an icon with the correct name.
                                # send request
                                curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/$policy_id"
                                curl_args=("--header")
                                curl_args+=("Accept: application/xml")
                                send_curl_request

                                existing_self_service_icon=$(xmllint --xpath //self_service/self_service_icon/filename "$curl_output_file" 2>/dev/null | awk -F '<filename>|</filename>' '{ print $2; exit; }' )

                                if [[ "$existing_self_service_icon" != "$icon_name" ]]; then
                                    echo
                                    echo "   [put_on_new_jss] Existing icon does not match local repo (or is absent). Uploading $icon_name"

                                    # Now upload the file to the correct policy_id
                                    # send request
                                    curl_url="$jss_url/JSSResource/fileuploads/policies/id/$policy_id"
                                    curl_args=("-F")
                                    curl_args+=(name=@"$icons_folder/$icon_name")
                                    send_curl_request

                                    # Now check if the icon is there
                                    # send request
                                    curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/$policy_id"
                                    curl_args=("--header")
                                    curl_args+=("Accept: application/xml")
                                    send_curl_request

                                    # save the output file
                                    icon_check_file="$xmlloc/${writefiles[$loop]}/$(basename "$jss_url").iconcheck.txt"
                                    cp "$curl_output_file" "$icon_check_file"

                                    self_service_icon_uri=$( xmllint --xpath //self_service/self_service_icon/uri "$icon_check_file" 2>/dev/null | awk -F '<uri>|</uri>' '{ print $2; exit; }' )

                                    if [[ "$self_service_icon_uri" ]]; then
                                        echo
                                        echo "   [put_on_new_jss] Icon successfully uploaded to $self_service_icon_uri"
                                    else
                                        echo
                                        echo "   [put_on_new_jss] $icon_name errored when attempting to upload it. Continuing anyway..."
                                    fi
                                else
                                    echo
                                    echo "   [put_on_new_jss] Existing icon matches repo. No need to re-upload."
                                fi
                            else
                                echo
                                echo "   [put_on_new_jss] Icon $icons_folder/$icon_name not found. Continuing..."
                            fi
                        else
                            echo
                            echo "   [put_on_new_jss] No icon in source policy. Continuing..."
                        fi
                    done
                ;;

                *)
                    totalParsedResourceXML=$(ls $xmlloc/${writefiles[$loop]}/parsed_xml | wc -l | sed -e 's/^[ \t]*//')
                    postInt=0

                    # get list of existing items
                    curl_url="$jss_url/JSSResource/${writefiles[$loop]}"
                    curl_args=("--header")
                    curl_args+=("Accept: application/xml")
                    send_curl_request

                    # save the output file
                    instance_check_file="$xmlloc/${writefiles[$loop]}/$(basename "$jss_url").output.txt"
                    xmllint --format "$curl_output_file" 2>/dev/null > "$instance_check_file"

                    for parsedXML in "$xmlloc/${writefiles[$loop]}/parsed_xml/"*.xml; do
                        (( postInt++ ))
                        # look for existing entry and update it rather than create a new one if it exists
                        source_name="$( grep "<name>" < "$parsedXML" | head -n 1 | awk -F '<name>|</name>' '{ print $2; exit; }' | sed -e 's|&amp;|\&|g' )"

                        echo
                        echo "   [put_on_new_jss] Posting ${writefiles[$loop]} $postInt/$totalParsedResourceXML '$source_name' from $(basename "$parsedXML")"

                        # get id from output
                        existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = \"$source_name\"]/id/text()" "$instance_check_file" 2>/dev/null)

                        # TEMP
                        # echo "existing_id ID: $existing_id"
                        # echo "api_xml_object_plural: $api_xml_object_plural"
                        # echo "api_xml_object: $api_xml_object"
                        # echo "source_name: $source_name"
                        # echo "instance_check_file: $instance_check_file"

                        if [[ $existing_id ]]; then
                             if [[ $overwrite_items == "yes" && "${writefiles[$loop]}" != "categories" ]]; then
                                echo "   [put_on_new_jss] ${writefiles[$loop]} '$source_name' already exists (ID=$existing_id)... overwriting"
                                # send request
                                curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/$existing_id"
                                curl_args=("--request")
                                curl_args+=("PUT")
                                curl_args+=("--header")
                                curl_args+=("Content-Type: application/xml")
                                curl_args+=("--data-binary")
                                curl_args+=(@"$parsedXML")
                                send_curl_request
                            else
                                echo "   [put_on_new_jss] ${writefiles[$loop]} '$source_name' already exists... skipping"
                            fi
                        else
                            # existing item not found, creating new one
                            # send request
                            curl_url="$jss_url/JSSResource/${writefiles[$loop]}/id/0"
                            curl_args=("--request")
                            curl_args+=("POST")
                            curl_args+=("--header")
                            curl_args+=("Content-Type: application/xml")
                            curl_args+=("--data-binary")
                            curl_args+=(@"$parsedXML")
                            send_curl_request
                        fi
                    done
                ;;
            esac
        else
            echo
            echo "   [put_on_new_jss] Resource ${writefiles[$loop]} empty. Skipping."
        fi
    done

    # Setting IFS back to default
    IFS=$OIFS
}

main_menu() {
    # Configure Logging
    log_file="$HOME/Library/Logs/JAMF/jamf-migration-tool.log"
    if [[ ! -f "$log_file" ]]; then
        mkdir -p "$( dirname "$log_file" )"
        touch "$log_file"
    fi
    exec &> >( tee -a "$log_file" >&2 )

    # Create icons folder
    mkdir -p "$icons_folder"


    # Set the source and destination server(s) and instance(s)
    # These are the endpoints we're going to read
    readfiles=()
    while read -r line; do
        if [[ ${line:0:1} != '#' && ${line} ]]; then
            readfiles+=("$line")
        fi
    done < "${readfile}"

    # These are the endpoints we're going to wipe
    wipefiles=()
    while read -r line; do
        if [[ ${line:0:1} != '#' && ${line} ]]; then
            wipefiles+=("$line")
        fi
    done < "${wipefile}"

    # These are the endpoints we're going to write
    writefiles=()
    while read -r line; do
        if [[ ${line:0:1} != '#' && ${line} ]]; then
            writefiles+=("$line")
        fi
    done < "${writefile}"

    while [[ $choice != "q" ]]; do
        echo
        echo "========="
        echo "Main Menu"
        echo "========="
        echo
        echo "1) Download config from template JSS"
        echo "2) Upload config to destination JSS instance"
        echo "3) Wipe JSS instance"
        echo
        echo "q) Quit!"
        echo
        read -r -p "Choose an option (1-3 / q) : " choice

        case "$choice" in
            1)
                ## Download from template instance
                action_type="download"
                setup_the_action

                # Do you want to change just a single endpoint or the standard list?
                echo
                echo "Possible endpoints:"
                echo
                grep -v -e "^#" "${readfile}" | sort | uniq
                echo

                apiParameter=""
                read -r -p "If you only want to download items of one specific API endpoint, enter it here : " apiParameter

                if [[ -z "${apiParameter}" || "${apiParameter}" == "ALL" ]]; then
                    # create an option to just download the iOS or limited stuff
                    read -r -p "Type I for iOS only, or L for limited download, or enter to download everything : " readquestion
                    case "${readquestion}" in
                        I|i)
                            read_file="${readlimitedfile}"
                        ;;
                        L|l)
                            read_file="${readlimitedfile}"
                        ;;
                        *)
                            read_file="${readfile}"
                        ;;
                    esac
                fi

                readfiles=()
                if [[ -z "${apiParameter}" || "${apiParameter}" == "ALL" ]]; then
                    # These are the endpoints we're going to save
                    while read -r line; do
                        if [[ ${line:0:1} != '#' && ${line} ]]; then
                            readfiles+=("${line}")
                        fi
                    done < "${read_file}"
                else
                    readfiles+=("${apiParameter}")
                    echo "${readfiles[@]}"
                fi

                jss_url="${instance_choice_array[0]}"
                grab_existing_jss_xml
            ;;

            2)
                ## Upload to instance
                action_type="upload"
                setup_the_action

                # Do you want to change just a single endpoint or the standard list?
                apiParameter=""
                # Do you want to change just a single endpoint or the standard list?
                echo
                echo "Possible endpoints"
                grep -v -e "^#" "${writefile}" | sort | uniq
                echo
                read -r -p "If you only want to upload items of one specific API endpoint, enter it here : " apiParameter

                writefiles=()
                if [[ -z "${apiParameter}" || "${apiParameter}" == "ALL" ]]; then
                    # create an option to just upload the iOS or limited stuff
                    read -r -p "Type I for iOS only, or L for limited upload after a limited wipe : " writequestion
                    case "${writequestion}" in
                        I|i)
                            write_file="${writeiosfile}"
                        ;;
                        L|l)
                            write_file="${writelimitedfile}"
                        ;;
                        *)
                            write_file="${writefile}"
                        ;;
                    esac

                    # These are the endpoint we're going to upload. Ordering is different from read/wipe.
                    while read -r line; do
                        if [[ ${line:0:1} != '#' && ${line} ]]; then
                            writefiles+=("${line}")
                        fi
                    done < "${write_file}"
                else
                    writefiles+=("${apiParameter}")
                fi

                echo
                read -r -p "Do you want to overwrite existing items on destination instance? (Y/N) : " wanttoput

                # Check for the skip
                if [[ $wanttoput == "Y" || $wanttoput == "y" ]]; then
                    overwrite_items="yes"
                else
                    overwrite_items="no"
                fi

                # temp set destination as source
                instance_choice_array=("$source_instance")

                echo
                read -r -p "Do you want to wipe the destination instance prior to uploading? (Y/N) : " wanttowipe

                # Check for the skip
                if [[ $wanttowipe == "Y" || $wanttowipe == "y" ]]; then
                    wipefiles=("${writefiles[@]}")
                    for jss_url in "${instance_choice_array[@]}"; do
                        wipe_jss
                    done
                fi

                echo "${instance_choice_array[*]}"

                for jss_url in "${instance_choice_array[@]}"; do
                    put_on_new_jss
                done
            ;;

            3)
                ## Wipe limited data (used for training instance)
                action_type="wipe"
                setup_the_action

                read_file="${readlimitedfile}"

                # Do you want to change just a single endpoint or the standard list?
                apiParameter=""
                # Do you want to change just a single endpoint or the standard list?
                echo
                echo "Possible endpoints"
                grep -v -e "^#" "${wipefile}" | sort | uniq
                echo
                read -r -p "If you only want to wipe items of one specific API endpoint, enter it here : " apiParameter

                wipefiles=()

                if [[ -z "${apiParameter}" || "${apiParameter}" == "ALL" ]]; then
                    # These are the endpoints we're going to wipe
                    while read -r line; do
                        if [[ ${line:0:1} != '#' && ${line} ]]; then
                            wipefiles+=("${line}")
                        fi
                    done < "${wipefile}"
                else
                    wipefiles+=("${apiParameter}")
                    echo "${wipefiles[@]}"
                fi

                jss_url="${instance_choice_array[0]}"
                wipe_jss
            ;;

            q|Q)
                echo
                echo "Thank you for using the Jamf Migration Tool!"
            ;;

            *)
                echo
                echo "Incorrect input. Please try again."
            ;;
        esac
    done
}

## MAIN

# These are the endpoints we're going to read
readfiles=()
while read -r line; do
    if [[ ${line:0:1} != '#' && ${line} ]]; then
        readfiles+=("$line")
    fi
done < "${readfile}"

# These are the endpoints we're going to wipe
wipefiles=()
while read -r line; do
    if [[ ${line:0:1} != '#' && ${line} ]]; then
        wipefiles+=("$line")
    fi
done < "${wipefile}"

# These are the endpoints we're going to write
writefiles=()
while read -r line; do
    if [[ ${line:0:1} != '#' && ${line} ]]; then
        writefiles+=("$line")
    fi
done < "${writefile}"

# Start menu screen here
echo
echo "   -----------------------"
echo "     Jamf Migration Tool"
echo "   -----------------------"
echo
echo "   [main] script started at $(date)"
echo

# Do the checks to see if this script can run
# check_icons_folder_mounted
check_xml_folder

# Show main menu in interactive mode.
main_menu

# All done!
exit
