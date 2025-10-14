#!/bin/bash

# --------------------------------------------------------------------------------
# Script for sending a non-specific request to the Jamf Platform API
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "   [main] ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------
# FUNCTIONS
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
-s | --sortkey KEY                 - sort key for GET requests to Jamf Pro API
-f | --filter KEY                  - filter key for GET requests to Jamf Pro API
-m | --match VALUE                 - match value for filtering GET requests to Jamf Pro API
--data DATA                        - data to send with the request
-v                                 - add verbose curl output
USAGE
}

request() {
    # get token
    if [[ "$chosen_id" && "$chosen_secret" ]]; then
        platform_api_client_id="$chosen_id"
        platform_api_client_secret="$chosen_secret"
    else
        set_platform_api_credentials "$api_base_url"
        echo "   [request] Using stored credentials for $api_base_url"
    fi

    # set url
    curl_url="$api_base_url$endpoint"

    if [[ $request_type == "GET" ]]; then
        if [[ "$filter_key" ]]; then
            if [[ ! "$match" ]]; then
                echo "   [request] ERROR: when using --filter, you must also provide a --match"
                exit 1
            fi
            handle_platform_api_get_request "$endpoint" filter "$filter_key" "$match"
        elif [[ "$sort_key" ]]; then
            handle_platform_api_get_request "$endpoint" sort "$sort_key"
        else
            handle_platform_api_get_request "$endpoint"
        fi
        # write combined output to curl output file
        echo "$combined_output" > "$curl_output_file"
    else
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
    fi
    echo "   [request] HTTP response: $http_response"
    if [[ "$http_response" -eq 200 ]]; then
        echo "   [request] Request successful."
        # if the output is valid JSON or XML, pretty print it and save it to file
        if jq -e . >/dev/null 2>&1 <"$curl_output_file"; then
            echo "   [request] Output:"
            jq . "$curl_output_file"
            # output pretty JSON to file
            formatted_output_file="${curl_output_file%.txt}.json"
            jq . "$curl_output_file" >"$formatted_output_file"
        elif [[ -s "$curl_output_file" ]]; then
            echo "   [request] Output:"
            cat "$curl_output_file"
        else
            echo "   [request] No output returned."
        fi
        echo
    fi
}

# -------------------------------------------------------------------------
# MAIN
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
            chosen_instances+=("$1")
            ;;
        -a|-ai|--all|--all-instances)
            all_instances=1
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
        -f|--filter)
            shift
            filter_key="$1"
        ;;
        -s|--sortkey)
            shift
            sort_key="$1"
        ;;
        -m|--match)
            shift
            match="$1"
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

echo
echo "This script will send a Platform API request using the chosen region and credentials.
The credentials must have the correct permissions for the chosen platform and endpoint."
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# set the region based on the chosen instances if not already set
if [[ ! $chosen_region ]]; then
    get_platform_api_region
fi

# perform the request on all chosen instances
for instance in "${instance_choice_array[@]}"; do

    # set the URL based on the chosen region
    if [[ $chosen_region ]]; then
        get_region_url
    else
        echo "   [main] ERROR: No region specified. Please provide a region using the --region option."
        exit 1
    fi

    # check if endpoint is set
    if [[ -z "$endpoint" ]]; then
        echo "Please provide an endpoint URL using the --endpoint option."
        echo "Example: --endpoint /api/v1/engage"
        echo
        echo "   [main] Exiting."
        exit 1
    fi

    # check if request_type is set
    if [[ -z "$request_type" ]]; then
        echo "   [main] Request type not set, so setting default as GET."
        request_type="GET"
    fi

    echo "   [main] Sending $request_type request to $api_base_url$endpoint..."
    request

    echo
    echo "   [main] Output saved to $curl_output_file"
    if [[ -f "$formatted_output_file" ]]; then
        echo "   [main] Formatted output saved to $formatted_output_file"
    fi
done

echo
echo "   [main] Finished"
echo
