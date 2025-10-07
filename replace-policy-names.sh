#!/bin/bash

# --------------------------------------------------------------------------------
# Script for changing policy names using AutoPkg
# USAGE:
# First download a list of policies using the DownloadPolicyList recipe, as follows:

# ./autopkg-run.sh -r recipes/DownloadPolicyList.jamf.recipe.yaml

# then edit the JSON file to contain only the policies you want to rename, 
# with their new names. The JSON file should be an array of objects with 
# "id" and "name" fields.

# Tip: remove entries that don't need to be changed - this will speed things 
# up considerably!

# Then run this script with the path to the edited JSON file as an argument.

# ./replace-policy-names.sh JSON_FILE

#   JSON_FILE: Path to a JSON file containing an array of objects with 
#   "id" and "name" fields.

# EXAMPLE:
# ./replace-policy-names.sh /path/to/policies.json
# --------------------------------------------------------------------------------

# Define the JSON file path
JSON_FILE="$1"

# source the _common-framework.sh file
source "_common-framework.sh"

if [[ ! -d "$this_script_dir" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# check if autopkg is installed, otherwise this won't work
autopkg_binary="/usr/local/bin/autopkg"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

run_autopkg() {
    # Extract subdomain from jss_instance (e.g., "https://myinstance.jamfcloud.com" -> "myinstance")
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)

    # Extract filename from JSON_FILE (remove path)
    json_filename=$(basename "$JSON_FILE")

    # Check if JSON filename contains the subdomain
    if [[ "$json_filename" != *"$subdomain"* ]]; then
        echo "ERROR: JSON file name does not match the expected subdomain ($subdomain)."
        exit 1
    fi

    # Loop through each object in the JSON file
    jq -c '.[]' "$JSON_FILE" | while read -r obj; do
        id=$(echo "$obj" | jq -r '.id')
        name=$(echo "$obj" | jq -r '.name')

        # Run the autopkg command with the extracted values
        echo OBJECT_ID="$id" 
        echo NEW_NAME="$name"
        "$autopkg_binary" run "$verbosity_mode" "$this_script_dir/recipes/ChangePolicyName.jamf.recipe.yaml" \
            --key OBJECT_ID="$id" \
            --key NEW_NAME="$name" \
            --key "JSS_URL=$jss_instance"
    done
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
chosen_instances=()
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
        -v*)
            verbosity_mode="$1"
            ;;
        -h|--help)
            usage
            exit
            ;;
        -f|--file)
            shift
            JSON_FILE="$1"
            ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
if [[ -z "$JSON_FILE" ]]; then
    echo "ERROR: No JSON file specified. Use the -f or --file option to specify the file."
    exit 1
fi
if [[ ! -f "$JSON_FILE" ]]; then
    echo "ERROR: JSON file not found at $JSON_FILE"
    exit 1
fi
# check it's a valid JSON file
if ! jq empty "$JSON_FILE" 2>/dev/null; then
    echo "ERROR: JSON file is not valid JSON."
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

# run on specified instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    set_credentials "$jss_instance"
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
done

echo 
echo "Finished"
echo
