#!/bin/bash

: <<'DOC'
Script for setting the SMTP server on all instances.
Requires a template XML file
DOC

# source the get-token.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "get-token.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh                - set the Keychain credentials

[no arguments]                      - interactive mode
--template /path/to/Template.xml    - template to use (must be a .xml file)
--il FILENAME (without .txt)        - provide an instance list filename
                                        (must exist in the instance-lists folder)
--i JSS_URL                         - perform action on a single instance
                                        (must exist in the relevant instance list)
--all                               - perform action on ALL instances in the instance list
-v                                  - add verbose curl output

NOTE: the SMTP server name, sender name, email address and any other specifics should be added directly to the XML template file.
USAGE
}

upload_smtpserver_data() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"
    # send request
    curl_url="$jss_url/JSSResource/smtpserver"
    curl_args=("--request")
    curl_args+=("PUT")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/xml")
    curl_args+=("--data-binary")
    curl_args+=(@"$template")
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
        -t|--template)
            shift
            template="$1"
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

# get template
choose_template_file

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Setting the SMTP server on $jss_instance..."
    upload_smtpserver_data
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Setting the SMTP server on $jss_instance..."
        upload_smtpserver_data
    done
fi

echo 
echo "Finished"
echo
