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


###########
## USAGE ##
###########

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


###############
## FUNCTIONS ##
###############

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


##############
## DEFAULTS ##
##############

if [[ ! -f "$jamf_upload_path" ]]; then
    # default path to jamf-upload-sh
    jamf_upload_path="$HOME/Library/AutoPkg/RecipeRepos/com.github.grahampugh.jamf-upload/jamf-upload.sh"
fi
# ensure the path exists, revert to defaults otherwise
if [[ ! -f "$jamf_upload_path" ]]; then
    jamf_upload_path="../jamf-upload/jamf-upload.sh"
fi


###############
## ARGUMENTS ##
###############

ea_type="computer"
args=()

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
        --name)
            shift
            ea_name="$1"
        ;;
        -d|--download-all)
            shift
            ea_name="ALL"
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

# fail if no valid path found
if [[ ! -f "$jamf_upload_path" ]]; then
    echo "ERROR: jamf-upload.sh not found. Please either run 'autopkg repo-add grahampugh/jamf-upload' or clone the grahampugh/jamf-upload repo to the parent folder of this repo"
    exit 1
fi

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# get the EA name
if [[ $ea_name == "ALL" ]]; then
    all_objects=1
elif [[ ! $ea_name ]]; then
    read -r -p "Enter Extension Attribute Name : " ea_name
fi

# select the instances that will be changed
choose_destination_instances

# set jamf-upload args
args+=(read)

if [[ ! $verbosity_mode && ! $quiet_mode ]]; then
    # default verbosity
    args+=(-v)
elif [[ ! $quiet_mode ]]; then
    args+=("$verbosity_mode")
fi

if [[ $ea_type == "device" ]]; then
    args+=(--type mobile_device_extension_attribute)
else
    args+=(--type computer_extension_attribute)
fi

if [[ $all_objects ]]; then
    args+=(--all)
else
    args+=(--name "$ea_name")
fi

args+=(--output "$xml_folder")

# now run jamf-upload
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    set_credentials "$jss_instance"
    echo "Running on $jss_instance..."
    echo "jamf-upload.sh ${args[*]}"
    run_jamfupload
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        set_credentials "$jss_instance"
        echo "Running on $jss_instance..."
        echo "jamf-upload.sh ${args[*]}"
        run_jamfupload
    done
fi




# get specific instance if entered
# if [[ $chosen_instance ]]; then
#     jss_instance="$chosen_instance"
#     if [[ $ea_type == "device" ]]; then
#         fetch_api_object_by_name mobile_device_extension_attribute "$ea_name"
#     else
#         fetch_api_object_by_name computer_extension_attribute "$ea_name"
#     fi
# else
#     for instance in "${instance_choice_array[@]}"; do
#         jss_instance="$instance"
#     if [[ $ea_type == "device" ]]; then
#         fetch_api_object_by_name mobile_device_extension_attribute "$ea_name"
#     else
#         fetch_api_object_by_name computer_extension_attribute "$ea_name"
#     fi
#     done
# fi

echo 
echo "Finished"
echo

open "${xml_folder}"
