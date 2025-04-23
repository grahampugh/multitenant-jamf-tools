#!/bin/bash

: <<'DOC'
Script for sending a non-specific request to the Jamf Pro API
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
--endpoint ENDPOINT_URL       - perform action on a specific endpoint, e.g. /api/v1/engage
--request REQUEST_TYPE        - GET/POST/PUT/DELETE
--data DATA                   - data to send with the request
-v                            - add verbose curl output
USAGE
}

request() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    # send request
    curl_url="$jss_url$endpoint_url"
    curl_args=("--request")
    curl_args+=("$request_type")
    curl_args+=("--header")
    if [[ "$endpoint_url" == *"JSSResource"* ]]; then
        curl_args+=("Content-Type: application/xml")
    else
        curl_args+=("Content-Type: application/json")
    fi
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    if [[ "$data" ]]; then
        curl_args+=("--data")
        curl_args+=("$data")
    fi
    send_curl_request
    echo "HTTP response: $http_response"
    if [[ "$http_response" -eq 200 ]]; then
        echo "Output:"
        cat "$curl_output_file"
    fi
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
        -e|--endpoint)
            shift
            endpoint_url="$1"
        ;;
        -r|--request)
            shift
            request_type="$1"
        ;;
        -d|--data)
            shift
            data="$1"
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
echo "This script will send an API request on the chosen instance(s)."

# select the instances that will be changed
choose_destination_instances

# check if endpoint_url is set
if [[ -z "$endpoint_url" ]]; then
    echo "Please provide an endpoint URL using the --endpoint option."
    echo "Example: --endpoint /api/v1/engage"
    echo "Exiting."
    exit 1
fi
# check if request_type is set
if [[ -z "$request_type" ]]; then
    echo "Request type not set, so setting default as GET."
    request_type="GET"
fi

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Sending $request_type request to $jss_instance$endpoint_url..."
    request
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Sending $request_type request to $jss_instance$endpoint_url..."
        request
    done
fi

echo 
echo "Finished"
echo
