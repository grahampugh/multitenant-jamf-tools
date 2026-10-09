#!/bin/bash

# --------------------------------------------------------------------------------
# Script to download FileVault personal recovery keys and LAPS passwords for all
# computers in a Jamf Pro instance, and output them to a CSV file.
#
# Output columns: Computer Name, Serial Number, FileVault Recovery Key, LAPS Password
#
# Requires:
# - Credentials with access to the following endpoints:
#     GET /api/v1/computers-inventory (sections: GENERAL, HARDWARE)
#     GET /api/v2/local-admin-password/{managementId}/account/lapsadmin/password
#     GET /api/v3/computers-inventory/filevault
# - jq installed on the system
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="mac"

# reduce the curl tries
max_tries_override=2

# default LAPS account name
laps_account="lapsadmin"

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

# prepare working directory
workdir="/Users/Shared/Jamf/FileVaultLAPS"
mkdir -p "$workdir"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'

# Download FileVault and LAPS Keys Script
Downloads FileVault personal recovery keys and LAPS passwords for all
computers in one or more Jamf Pro instances, and writes the results to a CSV file.

# Usage:
[no arguments]                     - interactive mode
--il FILENAME (without .txt)       - provide an instance list filename
                                     (must exist in the instance-lists folder)
--i JSS_URL                        - perform action on a single instance
                                     (must exist in the relevant instance list)
--all                              - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list
                                     (prevents interactive mode)
--user | --client-id CLIENT_ID     - use the specified client ID or username
--laps-account ACCOUNT_NAME        - LAPS account name to retrieve password for
                                     (default: lapsadmin)
-o | --output /path/to/folder      - output folder for CSV files
                                     (default: /Users/Shared/Jamf/FileVaultLAPS)
                                     Each instance produces a separate file named
                                     <instance>-filevault-laps-keys-<date>.csv
-v                                 - add verbose curl output
USAGE
}

get_computers_inventory() {
    jss_url="$jss_instance"

    # request all computers with the sections we need (GENERAL for managementId/name, HARDWARE for serialNumber)
    local page=0
    local page_size=100
    local total_count=1
    all_computers_json="[]"

    while [[ $((page * page_size)) -lt $total_count ]]; do
        echo "   [get_computers_inventory] Fetching page $page..."
        curl_url="$jss_url/api/v1/computers-inventory?section=GENERAL&section=HARDWARE&page=$page&page-size=$page_size&sort=general.name%3Aasc"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request

        if [[ $curl_failed == "true" ]]; then
            echo "   [get_computers_inventory] ERROR: request failed."
            curl_failed=""
            return 1
        fi

        total_count=$(/usr/bin/jq -r '.totalCount' "$curl_output_file" 2>/dev/null)
        if [[ -z "$total_count" || "$total_count" == "null" ]]; then
            echo "   [get_computers_inventory] ERROR: could not determine totalCount."
            return 1
        fi

        page_results=$(/usr/bin/jq -r '.results' "$curl_output_file" 2>/dev/null)
        all_computers_json=$(/usr/bin/jq -n --argjson acc "$all_computers_json" --argjson new "$page_results" '$acc + $new')

        echo "   [get_computers_inventory] Page $page: got $(echo "$page_results" | /usr/bin/jq 'length') computers (total: $total_count)"
        ((page++))
    done

    echo "   [get_computers_inventory] Total computers retrieved: $(/usr/bin/jq 'length' <<<"$all_computers_json")"
}

get_filevault_keys() {
    jss_url="$jss_instance"

    # request all FileVault keys with pagination
    local page=0
    local page_size=100
    local total_count=1
    all_fv_json="[]"

    while [[ $((page * page_size)) -lt $total_count ]]; do
        echo "   [get_filevault_keys] Fetching page $page..."
        curl_url="$jss_url/api/v3/computers-inventory/filevault?page=$page&page-size=$page_size"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request

        if [[ $curl_failed == "true" ]]; then
            echo "   [get_filevault_keys] ERROR: request failed."
            curl_failed=""
            return 1
        fi

        total_count=$(/usr/bin/jq -r '.totalCount' "$curl_output_file" 2>/dev/null)
        if [[ -z "$total_count" || "$total_count" == "null" ]]; then
            echo "   [get_filevault_keys] ERROR: could not determine totalCount."
            return 1
        fi

        page_results=$(/usr/bin/jq -r '.results' "$curl_output_file" 2>/dev/null)
        all_fv_json=$(/usr/bin/jq -n --argjson acc "$all_fv_json" --argjson new "$page_results" '$acc + $new')

        echo "   [get_filevault_keys] Page $page: got $(echo "$page_results" | /usr/bin/jq 'length') records (total: $total_count)"
        ((page++))
    done

    echo "   [get_filevault_keys] Total FileVault records retrieved: $(/usr/bin/jq 'length' <<<"$all_fv_json")"
}

get_laps_password() {
    local management_id="$1"
    jss_url="$jss_instance"

    curl_url="$jss_url/api/v2/local-admin-password/$management_id/account/$laps_account/password"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $curl_failed == "true" ]]; then
        curl_failed=""
        laps_password=""
        return 1
    fi

    laps_password=$(/usr/bin/jq -r '.password // empty' "$curl_output_file" 2>/dev/null)
}

do_the_download() {
    # get credentials
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"

    # derive a short display name from the instance URL (last path component, e.g. "myinstance.jamfcloud.com")
    instance_pretty=$(echo "$jss_instance" | rev | cut -d"/" -f1 | rev)

    # set per-instance output file
    instance_output_csv="$output_dir/${instance_pretty}-filevault-laps-keys-$(date +%Y-%m-%d).csv"
    mkdir -p "$output_dir"
    echo "Computer Name,Serial Number,FileVault Recovery Key,LAPS Password" > "$instance_output_csv"

    echo
    echo "   [do_the_download] Fetching computer inventory for $jss_instance..."
    if ! get_computers_inventory; then
        echo "   [do_the_download] ERROR: could not retrieve computers inventory for $jss_instance. Skipping."
        return 1
    fi

    echo
    echo "   [do_the_download] Fetching FileVault keys for $jss_instance..."
    if ! get_filevault_keys; then
        echo "   [do_the_download] WARNING: could not retrieve FileVault keys for $jss_instance."
        all_fv_json="[]"
    fi

    # build a lookup map: computer id -> personalRecoveryKey
    fv_lookup=$(/usr/bin/jq -r 'reduce .[] as $c ({}; . + {($c.computerId | tostring): ($c.personalRecoveryKey // "")})' <<<"$all_fv_json" 2>/dev/null)

    # iterate over each computer and write a CSV row
    computer_count=$(/usr/bin/jq 'length' <<<"$all_computers_json")
    echo
    echo "   [do_the_download] Processing $computer_count computers..."

    local i=0
    while [[ $i -lt $computer_count ]]; do
        computer_name=$(/usr/bin/jq -r ".[$i].general.name // \"\"" <<<"$all_computers_json")
        serial_number=$(/usr/bin/jq -r ".[$i].hardware.serialNumber // \"\"" <<<"$all_computers_json")
        management_id=$(/usr/bin/jq -r ".[$i].general.managementId // \"\"" <<<"$all_computers_json")
        computer_id=$(/usr/bin/jq -r ".[$i].id // \"\"" <<<"$all_computers_json")

        # look up FileVault key by computer id
        fv_key=$(/usr/bin/jq -r --arg id "$computer_id" '.[$id] // ""' <<<"$fv_lookup" 2>/dev/null)

        # get LAPS password for this management ID
        laps_password=""
        if [[ "$management_id" ]]; then
            get_laps_password "$management_id"
        fi

        # escape any commas or quotes in fields for CSV
        computer_name_csv=$(echo "$computer_name" | sed 's/"/""/g')
        serial_number_csv=$(echo "$serial_number" | sed 's/"/""/g')
        fv_key_csv=$(echo "$fv_key" | sed 's/"/""/g')
        laps_password_csv=$(echo "$laps_password" | sed 's/"/""/g')

        echo "\"$computer_name_csv\",\"$serial_number_csv\",\"$fv_key_csv\",\"$laps_password_csv\"" >> "$instance_output_csv"

        if [[ $verbose -gt 0 ]]; then
            echo "   [$((i+1))/$computer_count] $computer_name ($serial_number)"
        else
            echo -n "."
        fi
        ((i++))
    done
    [[ $verbose -eq 0 ]] && echo

    echo "   [do_the_download] Done for $jss_instance ($computer_count computers written to $instance_output_csv)."
}

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
        --id|--client-id|--user|--username)
            shift
            chosen_id="$1"
            ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        --laps-account)
            shift
            laps_account="$1"
            ;;
        -o|--output)
            shift
            output_dir="$1"
            ;;
        -v|--verbose)
            verbose=1
            ;;
        -h|--help)
            usage
            exit
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done
echo

# set default output directory
if [[ ! $output_dir ]]; then
    output_dir="$workdir"
fi

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances to run against
choose_destination_instances

# run on all chosen instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    echo
    echo "Processing: $jss_instance"
    echo "-----------------------------------------------------------"
    do_the_download
done

echo
echo "Results saved to: $output_dir"
echo
echo "Finished"
echo
