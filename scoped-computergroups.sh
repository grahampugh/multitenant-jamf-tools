#!/bin/bash

# --------------------------------------------------------------------------------
# A script to check which policies, configuration profiles, restricted software, 
# Mac App Store apps and eBooks are scoped to a specific computer group
# 
# Note that Jamf Pro now provides a built-in report for this, so this script 
# may no longer be needed.
#
# NOTE: This script will not check scope of Blueprints, Compliance Benchmarks, 
# or App Installers
#
# USAGE:
# ./scoped-computergroups.sh -g "Group Name" [other options]
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# prepare working directory
workdir="/Users/Shared/Jamf/ScopedComputerGroups"
mkdir -p "$workdir"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:

A script to check which policies, configuration profiles, restricted software, Mac App Store apps and eBooks are scoped to a specific computer group
Note that Jamf Pro now provides a built-in report for this, so this script may no longer be needed.

./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--all                         - perform action on ALL instances in the instance list
--group GROUP_NAME            - specify the group name to search for
-v                            - add verbose curl output
USAGE
}

prepare_output_file() {
    # prepare the output file
    jss_shortname=$( echo "$jss_instance" | sed 's|https://||' | sed 's|http://||' | sed 's|/$||' )
    output_file="$workdir/$jss_shortname-$group_name.txt"
    # ensure the directories can be written to, and empty the files
    echo "" > "$output_file"
    (
        echo "Timestamp: $( date )"
        echo "-------------------------------------------------------------------------------"
        echo "Group Name: $group_name"                        
        echo "-------------------------------------------------------------------------------"
        echo "Object Type            Name"                        
        echo "-------------------------------------------------------------------------------"
    ) > "$output_file"
}

print_scoped_objects() {
    # print the scoped objects
    for obj in "${scoped_objects[@]}"; do
        printf "%-22s %s\n" "$object_printname" "$obj" >> "$output_file"
    done
    echo
}

find_scoped_objects() {
    # find scoped objects of a specific type
    # $1: Object Type (Policy, Configuration Profile, Restricted Software, Mac App Store App, eBook)
    # $2: xpath/XML Tree - Top Level Only (policy, os_x_configuration_profile, restricted_software, mac_application, ebook)
    # $3: Group Name
    local object_printname="$1"
    local api_xml_object="$2"
    local group_name="$3"
    api_object_type=$( get_api_object_type "$api_xml_object" )

    echo "Retrieving List of All $object_printname IDs..."
    unset object_ids

    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    # send request
    curl_url="$jss_url/JSSResource/$api_object_type"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # echo "Output of $curl_output_file:" # TEMP
    # cat "$curl_output_file" # TEMP


    object_ids=$(
        xmllint --xpath "//$api_xml_object/id" \
        "$curl_output_file" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    scoped_objects=()

    echo "Checking for every $object_printname scoped to '$group_name'..."
    echo "Matches will be listed below:"
    while read -r i; do
        # echo "Retrieving $object_printname ID $i's data..."

        # send request
        curl_url="$jss_url/JSSResource/$api_object_type/id/$i"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request

        # if [[ $api_xml_object == "policy" ]]; then
        #     object_name=$(/usr/bin/xmllint --xpath "//$api_xml_object/general/name/text()" "$curl_output_file" 2>/dev/null)
        # else
        #     object_name=$(/usr/bin/xmllint --xpath "//$api_xml_object/name/text()" "$curl_output_file" 2>/dev/null)
        # fi
        object_name=$(/usr/bin/xmllint --xpath "//$api_xml_object/general/name/text()" "$curl_output_file" 2>/dev/null)

        if [[ "$object_printname" == "Policy" ]]; then
            ## Check if is a Jamf Remote Policy
            # echo "Checking if '$object_name' is a Jamf Remote Policy..."
            if [[ $object_name == $(/usr/bin/grep -qe -B1 '[0-9]+-[0-9]{2}-[0-9]{2} at [0-9]{1,2}:[0-9]{2,2} [AP]M \| .* \| .*' <<< "$object_name" 2>&1) ]]; then
                ## This is a Jamf Remote Policy
                ## Setting policy name in array to "JamfRemotePolicy-Ignore"
                echo "    '$object_name' is a Jamf Remote policy"
                continue
            fi
        fi

        # cat "$curl_output_file" # TEMP
        # echo "Checking for groups in '$object_name' ($i)"
        group_names=$(
            xmllint --xpath "//$api_xml_object/scope/computer_groups/computer_group/name" \
            "$curl_output_file" 2>/dev/null \
            | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
        )

        while read -r targeted_group ; do
            # echo "    Checking if '$object_name' ($i) is scoped to $group_name..." # TEMP
            # echo "    Comparing $targeted_group to $group_name..." # TEMP
            if [[ "$targeted_group" == "$group_name" ]]; then
                echo "$object_printname - '$object_name' ($i)"
                scoped_objects+=("$object_name")
            fi
        done <<< "${group_names}"
    done <<< "${object_ids[@]}"

    print_scoped_objects

    if [[ ${#scoped_objects[@]} -eq 0 ]]; then
        echo "No $object_printname objects found scoped to '$group_name'." >> "$output_file"
        echo
    fi
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
            ;;
        -i|--instance)
            shift
            chosen_instances+=("$1")
            ;;
        -a|-ai|--all|--all-instances)
            all_instances=1
            ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        -g|--group)
            shift
            group_name="$1"
        ;;
        -v|--verbose)
            verbose=1
        ;;
        -h|--help)
            usage
            exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# Ensure that a group name is provided
if [[ -z "$group_name" ]]; then
    echo "ERROR: No group name provided. Use the -g or --group option to specify a group name."
    usage
    exit 1
fi

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# run on all chosen instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    prepare_output_file
    echo "Looking for scope of $group_name on $jss_instance..."
    ## Check Policies, Configuration Profiles, Restircted Software and Mac App Store Apps
    find_scoped_objects "Policy" "policy" "$group_name"
    find_scoped_objects "Configuration Profile" "os_x_configuration_profile" "$group_name"
    find_scoped_objects "Restricted Software" "restricted_software" "$group_name"
    find_scoped_objects "Mac App Store App" "mac_application" "$group_name"
done

echo "-------------------------------------------------------------------------------" > "$output_file"

echo
echo "Finished"
echo
