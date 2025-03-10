#!/bin/bash

: <<'DOC'
Script for disabling "engage" on all instances
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

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

disable_engage() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
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
            chosen_instance_list_file="$1"
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

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

echo
echo "This script will disable Engage on the chosen instance(s)."

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Disabling engage on $jss_instance..."
    disable_engage
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Disabling engage on $jss_instance..."
        disable_engage
    done
fi

echo 
echo "Finished"
echo
