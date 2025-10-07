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
# FUNCTIONS
# --------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh               - set the Keychain credentials

[no arguments]                     - interactive mode
--il FILENAME (without .txt)       - provide an instance list filename
                                    (must exist in the instance-lists folder)
--i JSS_URL                        - perform action on a single instance
                                     (must exist in the relevant instance list)
--all                              - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list 
-e | --endpoint ENDPOINT_URL       - perform action on a specific endpoint, e.g. /api/v1/engage
-r | --request REQUEST_TYPE        - GET/POST/PUT/DELETE
-s | --sortkey KEY                 - sort key for GET requests to Jamf Pro API
-f | --filter KEY                  - filter key for GET requests to Jamf Pro API
-m | --match VALUE                 - match value for filtering GET requests to Jamf Pro API
--xml                              - use XML output instead of JSON
                                     (only for GET requests to Classic API)
--data DATA                        - data to send with the request
-v                                 - add verbose curl output

Note: for the Classic API, filter directly using the endpoint URL, either with /name/ or /id/
(e.g. /JSSResource/computergroups/name/All%20Computers or /JSSResource/computergroups/id/1)
USAGE
}

request() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    # send request
    curl_url="$jss_url$endpoint"
    curl_args=("--request")
    curl_args+=("$request_type")
    curl_args+=("--header")
    if [[ "$endpoint" == *"JSSResource"* ]]; then
        curl_args+=("Content-Type: application/xml")
    else
        curl_args+=("Content-Type: application/json")
    fi
    if [[ "$request_type" == "GET" && "$endpoint" == *"JSSResource"* && "$xml_output" -eq 1 ]]; then
        curl_args+=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request
    elif [[ "$request_type" == "GET" && "$endpoint" != *"JSSResource"* ]]; then
        if [[ "$filter_key" ]]; then
            if [[ ! "$match" ]]; then
                echo "   [request] ERROR: when using --filter, you must also provide a --match"
                exit 1
            fi
            handle_jpapi_get_request "$endpoint" filter "$filter_key" "$match"
        elif [[ "$sort_key" ]]; then
            handle_jpapi_get_request "$endpoint" sort "$sort_key"
        else
            handle_jpapi_get_request "$endpoint"
        fi
        # write combined output to curl output file
        echo "$combined_output" > "$curl_output_file"
    else
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
        elif xmllint --noout "$curl_output_file" >/dev/null 2>&1; then
            echo "   [request] Output:"
            xmllint --format "$curl_output_file"
            # output pretty XML to file
            formatted_output_file="${curl_output_file%.txt}.xml"
            xmllint --format "$curl_output_file" >"$formatted_output_file"
        elif [[ -s "$curl_output_file" ]]; then
            echo "   [request] Output:"
            cat "$curl_output_file"
        else
            echo "   [request] No output returned."
        fi
        echo
    fi
}

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

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
        --xml)
            xml_output=1
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

# check if endpoint is set
if [[ -z "$endpoint" ]]; then
    echo "Please provide an endpoint URL using the --endpoint option."
    echo "Example: --endpoint /api/v1/engage"
    echo
    echo "   [main] Exiting."
    exit 1
fi

echo
echo "This script will send an API request on the chosen instance."
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# check if request_type is set
if [[ -z "$request_type" ]]; then
    echo "   [main] Request type not set, so setting default as GET."
    request_type="GET"
fi

# perform the request on all chosen instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    echo "   [main] Sending $request_type request to $jss_instance$endpoint..."
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
