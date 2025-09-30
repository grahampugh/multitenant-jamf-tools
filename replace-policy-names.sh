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
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
mjt_repo_dir=$(mdfind -literal "kMDItemDisplayName == 'multitenant-jamf-tools'" 2>/dev/null)
if [[ ! -d "$mjt_repo_dir" ]]; then
    echo "ERROR: multitenant-jamf-tools not found"
    exit 1
fi
source "$mjt_repo_dir/_common-framework.sh"

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
        "$autopkg_binary" run -v "$mjt_repo_dir/recipes/ChangePolicyName.jamf.recipe.yaml" \
            --key OBJECT_ID="$id" \
            --key NEW_NAME="$name" \
            --key "JSS_URL=$jss_instance"
    done
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# select the instances that will be changed
choose_destination_instances
chosen_instance_list_file=$(basename "$instance_list_file" | cut -d'.' -f1)

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    set_credentials "$jss_instance"
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
else
    # only run this script on the first chosen instance!
    jss_instance="${instance_choice_array[0]}"
    set_credentials "$jss_instance"
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
fi

echo 
echo "Finished"
echo
