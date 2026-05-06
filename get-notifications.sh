#!/bin/bash

# --------------------------------------------------------------------------------
# Script for getting notifications from all Jamf Pro instances
# and generating a markdown report and optional Slack notification
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

# define autopkg_prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

# output directory
output_dir_default="/Users/Shared/Jamf/Notifications"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh               - set the Keychain credentials

[no arguments]                     - interactive mode
-il FILENAME (without .txt)        - provide an instance list filename
                                     (must exist in the instance-lists folder)
-i JSS_URL                         - perform action on a single instance
                                     (must exist in the relevant instance list)
-ai | --all-instances              - perform action on ALL instances in the instance list
--user | --client-id CLIENT_ID     - use the specified client ID or username
-o | --output DIR                  - output directory (default: /Users/Shared/Jamf/Notifications)
--slack                            - send the report via Slack webhook
-v                                 - add verbose curl output

USAGE
}

get_notifications() {
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [get_notifications] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [get_notifications] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"
    # send request
    curl_url="$jss_url/api/v1/notifications"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request
}

humanize_type() {
    # Transform UPPER_SNAKE_CASE to Title Case
    # e.g. EXCEEDED_LICENSE_COUNT -> Exceeded License Count
    echo "$1" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1'
}

humanize_key() {
    # Transform camelCase to Title Case
    # e.g. extensionAttributeName -> Extension Attribute Name
    echo "$1" | sed 's/\([a-z]\)\([A-Z]\)/\1 \2/g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2);}1'
}

generate_markdown_report() {
    local json_file="$1"
    local md_file="$2"

    echo "# Notifications Report" > "$md_file"
    echo "" >> "$md_file"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$md_file"
    echo "" >> "$md_file"

    # iterate through each instance in the combined JSON
    local instance_count
    instance_count=$(jq 'length' "$json_file")

    for ((idx=0; idx<instance_count; idx++)); do
        local notification_count
        notification_count=$(jq ".[$idx].notifications | length" "$json_file")

        if [[ "$notification_count" -eq 0 ]]; then
            continue
        fi

        local instance_url instance_display
        instance_url=$(jq -r ".[$idx].instance" "$json_file")
        instance_display="${instance_url#https://}"
        echo "## $instance_display" >> "$md_file"
        echo "" >> "$md_file"

        for ((n=0; n<notification_count; n++)); do
            local ntype ntype_display
            ntype=$(jq -r ".[$idx].notifications[$n].type" "$json_file")
            ntype_display=$(humanize_type "$ntype")
            echo "- $ntype_display" >> "$md_file"

            # get params excluding any "id" keys
            local params_json
            params_json=$(jq -r ".[$idx].notifications[$n].params | del(.id) | to_entries[]" "$json_file" 2>/dev/null)

            if [[ -n "$params_json" ]]; then
                while IFS= read -r param_line; do
                    local pkey pvalue pkey_display
                    pkey=$(echo "$param_line" | jq -r '.key')
                    pvalue=$(echo "$param_line" | jq -r '.value')
                    pkey_display=$(humanize_key "$pkey")
                    echo "    - $pkey_display: $pvalue" >> "$md_file"
                done < <(jq -c ".[$idx].notifications[$n].params | del(.id) | to_entries[]" "$json_file" 2>/dev/null)
            fi
        done
        echo "" >> "$md_file"
    done
}

generate_slack_payload() {
    local json_file="$1"

    local text=""
    text+=":bell: *Notifications Report*\n"
    text+="_Generated: $(date '+%Y-%m-%d %H:%M:%S')_\n\n"

    local instance_count
    instance_count=$(jq 'length' "$json_file")

    for ((idx=0; idx<instance_count; idx++)); do
        local instance_url
        instance_url=$(jq -r ".[$idx].instance" "$json_file")
        text+="*$instance_url*\n"

        local notification_count
        notification_count=$(jq ".[$idx].notifications | length" "$json_file")

        if [[ "$notification_count" -eq 0 ]]; then
            text+="No notifications.\n\n"
            continue
        fi

        for ((n=0; n<notification_count; n++)); do
            local ntype
            ntype=$(jq -r ".[$idx].notifications[$n].type" "$json_file")
            text+="\`$ntype\`\n"

            local params
            params=$(jq -r ".[$idx].notifications[$n].params | del(.id) | to_entries[] | \"  • \(.key): \(.value)\"" "$json_file" 2>/dev/null)

            if [[ -n "$params" ]]; then
                text+="$params\n"
            fi
        done
        text+="\n"
    done

    # construct the Slack payload JSON
    printf '{"text": "%s"}' "$text"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
    -il | --instance-list)
        shift
        chosen_instance_list_file="$1"
        ;;
    -i | --instance)
        shift
        chosen_instances+=("$1")
        ;;
    -a | -ai | --all | --all-instances)
        all_instances=1
        ;;
    --id | --client-id | --user | --username)
        shift
        chosen_id="$1"
        ;;
    -x | --nointeraction)
        no_interaction=1
        ;;
    -o | --output)
        shift
        output_dir="$1"
        ;;
    --slack)
        send_slack=1
        ;;
    -v | --verbose)
        verbose=1
        ;;
    -h | --help)
        usage
        exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

echo
echo "This script will retrieve notifications from the chosen Jamf Pro instance(s)."
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances
choose_destination_instances

# set output directory
if [[ ! "$output_dir" ]]; then
    output_dir="$output_dir_default"
fi
mkdir -p "$output_dir"

# set output file paths
timestamp=$(date '+%Y-%m-%d_%H%M%S')
combined_json_file="$output_dir/notifications_${timestamp}.json"
report_file="$output_dir/notifications_${timestamp}.md"

# make temp file for curl output
curl_output_file=$(mktemp)
curl_headers_file=$(mktemp)
cookie_jar="$output_location/curl_cookies_$(date +%s)"
trap 'rm -f "$curl_output_file" "$curl_headers_file" "$cookie_jar"' EXIT

# initialize the combined JSON array
echo "[]" > "$combined_json_file"

echo
echo "Retrieving notifications..."
echo

for jss_instance in "${instance_choice_array[@]}"; do
    echo "   [main] Processing $jss_instance..."
    get_notifications

    if [[ "$http_response" == "200" ]]; then
        # read the notifications from the curl output
        notifications=$(jq '.' "$curl_output_file" 2>/dev/null)
        if [[ -z "$notifications" || "$notifications" == "null" ]]; then
            notifications="[]"
        fi
    else
        echo "   [main] WARNING: Failed to get notifications from $jss_instance (HTTP $http_response)"
        notifications="[]"
    fi

    # append this instance's data to the combined JSON
    jq --arg instance "$jss_instance" --argjson notifs "$notifications" \
        '. += [{"instance": $instance, "notifications": $notifs}]' \
        "$combined_json_file" > "${combined_json_file}.tmp" \
        && mv "${combined_json_file}.tmp" "$combined_json_file"
done

# generate the markdown report
generate_markdown_report "$combined_json_file" "$report_file"

echo
echo "Results:"
echo
cat "$report_file"
echo
echo "Files saved to:"
echo "   JSON: $combined_json_file"
echo "   Report: $report_file"

# send Slack notification if requested
if [[ $send_slack -eq 1 ]]; then
    slack_text=$(generate_slack_payload "$combined_json_file")
    send_slack_notification "$slack_text"
fi

echo
echo "Finished"
echo
