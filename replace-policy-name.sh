#!/bin/bash

# --------------------------------------------------------------------------------
# Script for changing a specific policy name across multiple instances
#
# USAGE:
# ./replace-policy-name.sh "Old Policy Name" "New Policy Name"
# --------------------------------------------------------------------------------

# Define the policy name
POLICY_NAME_TO_REPLACE="$1"
REPLACEMENT_NAME="$2"

source "_common-framework.sh"

if [[ ! -d "$this_script_dir" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

run_autopkg() {
    # Extract subdomain from jss_instance (e.g., "https://myinstance.jamfcloud.com" -> "myinstance")
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    output_dir="/Users/Shared/Jamf/JamfUploader"
    mkdir -p "$output_dir"
    output_file="$output_dir/$subdomain-policies-$POLICY_NAME_TO_REPLACE.xml"
    # delete any existing output file
    if [[ -f "$output_file" ]]; then
        rm "$output_file"
    fi

    # first, check if a policy of this name exists
    "$this_script_dir/jamfuploader-run.sh" read \
        --type policy \
        --name "$POLICY_NAME_TO_REPLACE" \
        --instance "$jss_instance" \
        --nointeraction \
        --output "$output_dir"

    if [[ ! -f "$output_file" ]]; then
        echo "No policy found with the name '$POLICY_NAME_TO_REPLACE' on $jss_instance."
        return
    fi
    
    # get value of id key from the output xml file
    id=$(xmllint --xpath 'string(//general/id)' "$output_file" 2>/dev/null) 
    if [[ -z "$id" ]]; then
        echo "No ID found for the policy '$POLICY_NAME_TO_REPLACE' on $jss_instance."
        return
    fi

    # Run the autopkg command with the extracted values
    echo OBJECT_ID="$id" 
    echo NEW_NAME="$REPLACEMENT_NAME"
    "$this_script_dir/autopkg-run.sh" \
        --recipe "$this_script_dir/recipes/ChangePolicyName.jamf.recipe.yaml" \
        --instance "$jss_instance" \
        --nointeraction \
        --key OBJECT_ID="$id" \
        --key NEW_NAME="$REPLACEMENT_NAME" \
        --replace \
        -v
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# ensure that parameters 1 and 2 are provided
if [[ -z "$POLICY_NAME_TO_REPLACE" || -z "$REPLACEMENT_NAME" ]]; then
    echo "Usage: $0 <policy_name_to_replace> <replacement_name>"
    echo "Example: $0 'Old Policy Name' 'New Policy Name'"
    exit 1
fi

# select the instances that will be changed
choose_destination_instances
chosen_instance_list_file=$(basename "$instance_list_file" | cut -d'.' -f1)

# run on all chosen instances
for instance in "${instance_choice_array[@]}"; do
    # set the instance variable
    jss_instance="$instance"
    set_credentials "$jss_instance"
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
done

echo 
echo "Finished"
echo
