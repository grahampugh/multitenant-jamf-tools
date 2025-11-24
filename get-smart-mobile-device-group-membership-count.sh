#!/bin/bash

# --------------------------------------------------------------------------------
# Script for getting the membership count of a smart mobile device group across multiple Jamf instances
# USAGE:
# ./get-smart-mobile-device-group-membership-count.sh "SMART_MOBILE_DEVICE_GROUP_NAME"
#   SMART_MOBILE_DEVICE_GROUP_NAME: Name of the smart mobile device group to check
# --------------------------------------------------------------------------------

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
./get-smart-mobile-device-group-membership-count.sh -g "SMART_MOBILE_DEVICE_GROUP_NAME"
  -g | --group "SMART_MOBILE_DEVICE_GROUP_NAME"   - Name of the smart mobile device group to check
USAGE
}   

run_autopkg() {
    # Extract subdomain from jss_instance (e.g., "https://myinstance.jamfcloud.com" -> "myinstance")
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    output_dir="/Users/Shared/Jamf/JamfUploader"
    mkdir -p "$output_dir"
    output_file="$output_dir/$subdomain-smart_mobile_device_group_membership-$SMART_MOBILE_DEVICE_GROUP_NAME.json"

    # delete any existing output file
    if [[ -f "$output_file" ]]; then
        rm "$output_file"
    fi

    if ! "$this_script_dir/autopkg-run.sh" -r "$this_script_dir/recipes/GetSmartMobileDeviceGroupMembership.jamf.recipe.yaml" \
        --instance "$jss_instance" \
        --nointeraction \
        --key SMART_MOBILE_DEVICE_GROUP_NAME="$SMART_MOBILE_DEVICE_GROUP_NAME"; then
        echo "ERROR: AutoPkg run failed for $jss_instance"
        exit 1
    fi
}

create_csv_file() {
    local csv_file="$1"
    # ensure the directory exists
    mkdir -p "$(dirname "$csv_file")"
    # check if the file already exists, if so, back it up
    if [[ -f "$csv_file" ]]; then
        mv "$csv_file" "$csv_file.bak-$(date +%Y-%m%d-%H%M%S)"
    fi
    # create the CSV file with headers
    echo "Instance,Membership Count" > "$csv_file"
}

write_count_to_file() {
    local output_file="$1"
    local csv_file="$2"
    # count the number of items in the members array of the output_file JSON
    count=$(jq '.members | length' "$output_file")
    if [[ -z "$count" ]]; then
        count=0
    fi
    echo "Membership count for '$SMART_MOBILE_DEVICE_GROUP_NAME' in '$jss_instance': $count"
    # we need to escape any commas in SMART_MOBILE_DEVICE_GROUP_NAME
    echo "$jss_instance,$count" >> "$csv_file"
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
        -g|--group)
            shift
            SMART_MOBILE_DEVICE_GROUP_NAME="$1"
            ;;
        *)
            usage
            exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# ensure that parameter 1 is provided
if [[ -z "$SMART_MOBILE_DEVICE_GROUP_NAME" ]]; then
    echo "Usage: $0 -g <smart_mobile_device_group_name>"
    echo "Example: $0 -g 'My Smart Mobile Device Group'"
    exit 1
fi

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# create the CSV file
output_csv_file="/Users/Shared/Jamf/JamfUploader/smart_mobile_device_group_membership_counts-$SMART_MOBILE_DEVICE_GROUP_NAME-$(date +%Y-%m-%d).csv"
create_csv_file "$output_csv_file"

# run on all chosen instances
for instance in "${instance_choice_array[@]}"; do
    # set the instance variable
    jss_instance="$instance"
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
    write_count_to_file "$output_file" "$output_csv_file"
done

echo "CSV file created at: $output_csv_file"
open "$output_csv_file"
echo 
echo "Finished"
echo
