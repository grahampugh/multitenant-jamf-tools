#!/bin/bash

# A script to check which policies, configuration profiles, restricted software, Mac App Store apps and eBooks are scoped to a specific computer group

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
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


## MAIN BODY

usage() {
    cat <<'USAGE'
Usage:
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

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

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
            chosen_instance="$1"
        ;;
        -a|--all)
            all_instances=1
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


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTIONS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

prepareOutputFile() {
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

printScopedObjects() {
    # print the scoped objects
    for obj in "${scoped_objects[@]}"; do
        printf "%-22s %s\n" "$object_printname" "$obj" >> "$output_file"
    done
    echo
}


findScopedObjects() {
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

    printScopedObjects

}

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    prepareOutputFile
    echo "Looking for scope of $group_name on $jss_instance..."
    ## Check Policies, Configuration Profiles, Restircted Software and Mac App Store Apps
    findScopedObjects "Policy" "policy" "$group_name"
    findScopedObjects "Configuration Profile" "os_x_configuration_profile" "$group_name"
    findScopedObjects "Restricted Software" "restricted_software" "$group_name"
    findScopedObjects "Mac App Store App" "mac_application" "$group_name"
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        prepareOutputFile
        echo "Looking for scope of $group_name on $jss_instance..."
        ## Check Policies, Configuration Profiles, Restircted Software and Mac App Store Apps
        findScopedObjects "Policy" "policy" "$group_name"
        findScopedObjects "Configuration Profile" "os_x_configuration_profile" "$group_name"
        findScopedObjects "Restricted Software" "restricted_software" "$group_name"
        findScopedObjects "Mac App Store App" "mac_application" "$group_name"
    done
fi

    echo "-------------------------------------------------------------------------------" > "$output_file"


echo 
echo "Finished"
echo
