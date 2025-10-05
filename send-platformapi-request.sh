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

# --------------------------------------------------------------------
# Functions
# --------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh               - set the Keychain credentials

[no arguments]                     - interactive mode
--region REGION                    - Platform API region (one of US, EU, APAC)
--id ID                            - Platform API ID
--secret SECRET                    - Platform API Secret
-e | --endpoint ENDPOINT_URL       - perform action on a specific endpoint, e.g. /api/v1/engage
-r | --request REQUEST_TYPE        - GET/POST/PUT/PATCH/DELETE
--data DATA                        - data to send with the request
-v                                 - add verbose curl output
USAGE
}

# temp files for tokens, cookies and headers
output_location="/tmp/jamf_pro_api"
mkdir -p "$output_location"

request() {
    # determine api_url
    curl_url="$api_url"
    # send request
    curl_args=("--request")
    curl_args+=("$request_type")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    if [[ "$data" ]]; then
        curl_args+=("--data")
        curl_args+=("$data")
    fi
    send_curl_request
    echo "HTTP response: $http_response"
    if [[ "$http_response" -eq 200 ]]; then
        echo "Request successful."
        # if the output is valid JSON or XML, pretty print it and save it to file
        if jq -e . >/dev/null 2>&1 <"$curl_output_file"; then
            echo "Output:"
            jq . "$curl_output_file"
            # output pretty JSON to file
            formatted_output_file="${curl_output_file%.txt}.json"
            jq . "$curl_output_file" >"$formatted_output_file"
        elif [[ -s "$curl_output_file" ]]; then
            echo "Output:"
            cat "$curl_output_file"
        else
            echo "No output returned."
        fi
        echo
    fi
}

# -------------------------------------------------------------------------
# MAIN BODY
# -------------------------------------------------------------------------

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

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
        -x|--nointeraction)
            no_interaction=1
            ;;
        --region)
            shift
            # Set the chosen region, convert to lowercase
            chosen_region="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
        ;;
        --id)
            shift
            chosen_id="$1"
        ;;
        --secret)
            shift
            chosen_secret="$1"
        ;;
        -e|--endpoint)
            shift
            endpoint="$1"
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
echo "This script will send a Platform API request using the chosen region and credentials.
The credentials must have the correct permissions for the chosen platform and endpoint."

# get specific instance if entered
if [[ ! $chosen_instance ]]; then
    # select the instances that will be changed
    choose_destination_instances
    chosen_instance="${instance_choice_array[0]}"
fi

# set the region based on the chosen instance
get_platform_api_region

# set the URL based on the chosen region
if [[ $chosen_region ]]; then
    case $chosen_region in
        us)
            api_base_url="https://us.apigw.jamf.com"
            ;;
        eu)
            api_base_url="https://eu.apigw.jamf.com"
            ;;
        apac)
            api_base_url="https://apac.apigw.jamf.com"
            ;;
        *)
            echo "ERROR: Invalid region specified. Please use one of: us, eu, apac."
            exit 1
            ;;
    esac
else
    echo "ERROR: No region specified. Please provide a region using the --region option."
    exit 1
fi

# check if endpoint_url is set
if [[ -z "$endpoint" ]]; then
    echo "Please provide an endpoint URL using the --endpoint option."
    echo "Example: --endpoint /api/v1/engage"
    echo "Exiting."
    exit 1
fi

# get token
if [[ "$chosen_id" && "$chosen_secret" ]]; then
    platform_api_client_id="$chosen_id"
    platform_api_client_secret="$chosen_secret"
else
    set_platform_api_credentials "$api_base_url"
fi
check_platform_api_token

# set url
api_url="$api_base_url$endpoint"

# check if request_type is set
if [[ -z "$request_type" ]]; then
    echo "Request type not set, so setting default as GET."
    request_type="GET"
fi

echo "Sending $request_type request to $api_url..."
request

echo
echo "Output saved to $curl_output_file"
if [[ -f "$formatted_output_file" ]]; then
    echo "Formatted output saved to $formatted_output_file"
fi
echo
echo "Finished"
echo
