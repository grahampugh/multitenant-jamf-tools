#!/bin/bash

# --------------------------------------------------------------------------------
# Script for reading Inventory Collection Settings on all instances
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="ios"

# set the curl tries
max_tries_override=2

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
--template /path/to/Template.json  - template to use (must be a json file)
--il FILENAME (without .txt)       - provide a server-list filename
                                     (must exist in the instance-lists folder)
--i JSS_URL                        - perform action on a single instance
                                     (must exist in the relevant instance list)
--all                              - perform action on ALL instances in the instance list
--user | --client-id CLIENT_ID     - use the specified client ID or username
-v                                 - add verbose curl output
USAGE
}

get_inventory_collection() {
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="${jss_instance}"
    # send request
    curl_url="$jss_url/api/v1/computer-inventory-collection-settings"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request
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

# set default output file
if [[ ! $output_file ]]; then
    output_file="/Users/Shared/Jamf/MJT/inventory-collection-settings.txt"
fi
if [[ ! $csv ]]; then
    output_csv="/Users/Shared/Jamf/MJT/inventory-collection-settings.csv"
fi

# ensure the directories can be written to, and empty the files
mkdir -p "$(dirname "$output_file")"
echo "" > "$output_file"
mkdir -p "$(dirname "$output_csv")"
echo "" > "$output_csv"

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# heading for csv
echo "Context,Software Update" >> "$output_csv"
# heading for text file
(
    echo "--------------------------------------------------------------------------"
    echo "Jamf Pro Inventory Collection Settings       $(date)"
    echo "--------------------------------------------------------------------------"
    echo "Context                                                                SWU"
    echo "--------------------------------------------------------------------------"
) >> "$output_file"

# start the count
includeSoftwareUpdates_count=0

# get specific instance if entered
instance_count=0
for instance in "${instance_choice_array[@]}"; do
    ((instance_count++))
    jss_instance="$instance"
    echo "Getting Inventory Collection settings on $jss_instance..."
    get_inventory_collection
    # cat "$curl_output_file"
    includeSoftwareUpdates=$(plutil -extract "computerInventoryCollectionPreferences.includeSoftwareUpdates" raw "$curl_output_file")
    if [[ $includeSoftwareUpdates != "true" && $includeSoftwareUpdates != "false" ]]; then
        includeSoftwareUpdates="-"
    fi

    if [[ $includeSoftwareUpdates == "true" ]]; then
        (( includeSoftwareUpdates_count++ ))
    fi

    # format for csv
    echo "$instance,$includeSoftwareUpdates" >> "$output_csv"

    # format for text file
    printf "%-65s %+8s\n" \
    "$instance" "$includeSoftwareUpdates" >> "$output_file"
done

# end for text file
(
    echo "--------------------------------------------------------------------------"
    printf "Total: Contexts: %-28s %+28s\n" "$instance_count" "$includeSoftwareUpdates_count"
    echo "--------------------------------------------------------------------------"
    echo
) >> "$output_file"

# now echo the file
echo
echo "Results:"
echo
cat "$output_file"
echo
echo "These results are saved to:"
echo "   Text format: $output_file"
echo "   CSV format:  $output_csv"
echo

echo 
echo "Finished"
echo
