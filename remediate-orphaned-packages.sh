#!/bin/bash

: <<'DOC'
Script for creating package objects for orphaned packages on a File Share Distribution Point
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="macos"

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
-v                            - add verbose curl output
USAGE
}

remediate_packages() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="$jss_instance"

    # check if smb and mount share
    # Check that a DP actually exists
    get_instance_distribution_point

    if [[ $smb_url ]]; then
        # get the smb credentials from the keychain
        get_smb_credentials


        # get a list of all package objects


        # loop through package names and look for the object in the object list


        # create the package object
    else
        echo "No FileShare on this instance"
    fi


    # send request
    curl_url="$jss_url/api/v1/engage"
    curl_args=("--request")
    curl_args+=("PUT")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    curl_args+=("--data")
    curl_args+=("{\"isEnabled\":false}")
    send_curl_request
}

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

## MAIN BODY

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

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

# Set default instance list
default_instance_list_file="instance-lists/default-instance-list.txt"
[[ -f "$default_instance_list_file" ]] && default_instance_list=$(cat "$default_instance_list_file") || default_instance_list="prd"


# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Finding orphaned packages on $jss_instance..."
    remediate_packages
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Finding orphaned packages on $jss_instance..."
        remediate_packages
    done
fi

echo 
echo "Finished"
echo
