#!/bin/bash

: <<'DOC'
Script for downloading EA objects on all instances
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

# Check and create the JSS xml folder and archive folders if missing.
xml_folder_default="/Users/Shared/Jamf/EA-Downloads"
xml_folder="$xml_folder_default"
mkdir -p "${xml_folder}"


usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--name EA_NAME                - Extension Attribute Name
--ios                         - download mobile device extension attributes 
--computer                    - download computer extension attributes 
                                (Default is computer extension attributes)
--all                         - perform action on ALL instances in the instance list
-v                            - add verbose curl output
USAGE
}

encode_name() {
    # encode space, '&amp;', percent
    name_url_encoded="$( echo "$1" | sed -e 's|\%|%25|g' | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"
    echo "$name_url_encoded"
}

fetch_api_object_by_name() {
    local api_xml_object="$1"
    local chosen_api_obj_name="$2"

    api_object_type=$( get_api_object_type $api_xml_object )

    chosen_api_obj_name_url_encoded=$(encode_name "$chosen_api_obj_name")

    # Get the full XML of the selected API object
    echo "   [fetch_api_object_by_name] Fetching $api_xml_object name ${chosen_api_obj_name} from $jss_instance"
    # echo "   [fetch_api_object_by_name] (encoded): ${chosen_api_obj_name_url_encoded}" # TEST

    # Set the source server
    set_credentials "${jss_instance}"
    # determine jss_url
    jss_url="${jss_instance}"
    url_in_filename=${jss_instance//https:\/\//}

    # send request
    curl_url="$jss_url/JSSResource/$api_object_type/name/${chosen_api_obj_name_url_encoded}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # save formatted fetch file
    xmllint --format "$curl_output_file" > "${xml_folder}/${url_in_filename}-${api_xml_object}-${chosen_api_obj_name}-fetched.xml"
}

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

## MAIN BODY

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

ea_type="computer"

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -il|--instance-list)
            shift
            instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        --name)
            shift
            ea_name="$1"
        ;;
        --ios|--device)
            shift
            ea_type="device"
        ;;
        --computer)
            shift
            ea_type="computer"
        ;;
        -a|--all)
            all_instances=1
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

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# set ldap user
if [[ ! $ea_name ]]; then
    read -r -p "Enter Extension Attribute Name : " ea_name
fi

# Set default instance list
default_instance_list="prd"

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    if [[ $ea_type == "device" ]]; then
        fetch_api_object_by_name mobile_device_extension_attribute "$ea_name"
    else
        fetch_api_object_by_name computer_extension_attribute "$ea_name"
    fi
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
    if [[ $ea_type == "device" ]]; then
        fetch_api_object_by_name mobile_device_extension_attribute "$ea_name"
    else
        fetch_api_object_by_name computer_extension_attribute "$ea_name"
    fi
    done
fi

echo 
echo "Finished"
echo

open "${xml_folder}"
