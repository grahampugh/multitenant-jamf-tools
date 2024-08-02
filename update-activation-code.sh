#!/bin/bash

: <<'DOC'
Script for updating the activation code on all instances
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
--code ACTIVATION-CODE        - provide activation code
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--all                         - perform action on ALL instances in the instance list
-v                            - add verbose curl output
USAGE
}

write_activation_code() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"
    # send request
    curl_url="$jss_url/JSSResource/activationcode"
    curl_args=("--request")
    curl_args+=("PUT")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/xml")
    curl_args+=("--data")
    curl_args+=("<activation_code><code>$activation_code</code></activation_code>")
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
        --code)
            shift
            activation_code="$1"
        ;;
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

# Set default instance list
default_instance_list="prd"

# select the instances that will be changed
choose_destination_instances

# set activation code
if [[ ! $activation_code ]]; then
    read -r -p "Enter the activation code : " activation_code
    echo
fi
if [[ ! $activation_code  ]]; then
    echo "ERROR: no code supplied"
fi

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Updating Activation Code on $jss_instance..."
    write_activation_code
else
    for instance in "${instances_list[@]}"; do
        jss_instance="$instance"
        echo "Updating Activation Code on $jss_instance..."
        write_activation_code
    done
fi

echo 
echo "Finished"
echo
