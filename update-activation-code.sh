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

are_you_sure() {
    if [[ $confirmed != "yes" ]]; then
        echo
        read -r -p "Are you sure you want to update the activation code on $jss_instance? (Y/N) : " sure
        case "$sure" in
            Y|y)
                return
                ;;
            *)
                echo "   [are_you_sure] Action cancelled, quitting"
                exit
                ;;
        esac
    fi
}

send_slack_notification() {
    local jss_url="$1"
    local acode="$2"

    if get_slack_webhook "$instance_list_file"; then
        if [[ $slack_webhook_url ]]; then
            slack_text="{'username': '$jss_url', 'text': 'Instance: $jss_url\nActivation Code Update: $acode'}"
        
            response=$(
                curl -s -o /dev/null -S -i -X POST -H "Content-Type: application/json" \
                --write-out '%{http_code}' \
                --data "$slack_text" \
                "$slack_webhook_url"
            )
            echo "   [send_slack_notification] Sent Slack notification (response: $response)"
        fi
    else
        echo "   [send_slack_notification] Not sending slack notification as no webhook found"
    fi
}

get_activation_code() {
    # get the original activation code for outputting
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"
    # send request
    curl_url="$jss_url/JSSResource/activationcode"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    old_activation_code=$(plutil -extract "activation_code.code" raw "$curl_output_file")
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


    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*update-activation-code.sh*\nUser: $jss_api_user\nInstance: $jss_url\nActivation Code: $activation_code'}"
    send_slack_notification "$slack_text"
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
            chosen_instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        -a|--all)
            all_instances=1
        ;;
        --confirm)
            echo "   [main] CLI: Action: auto-confirm copy or delete, for non-interactive use."
            confirmed="yes"
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
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    get_activation_code
    echo "Existing Activation Code on $jss_instance: $old_activation_code"
    if [[ "$old_activation_code" == "$activation_code" ]]; then
        echo "Existing Activation Code on $jss_instance matches the inputted code. No need to update."
    else
        # are we sure to proceed?
        are_you_sure

        echo "Updating Activation Code on $jss_instance..."
        write_activation_code
    fi
done

echo 
echo "Finished"
echo
