#!/bin/bash

# --------------------------------------------------------------------------------
# Script for changing a specific policy name across multiple instances
#
# USAGE:
# ./replace-policy-name.sh -o "Old Policy Name" -n "New Policy Name"
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

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
        "$verbosity_mode"
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
        --id|--client-id|--user|--username)
            shift
            chosen_id="$1"
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
        -o|--old-name)
            shift
            POLICY_NAME_TO_REPLACE="$1"
            ;;
        -n|--new-name)
            shift
            REPLACEMENT_NAME="$1"
            ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

# ensure that parameters 1 and 2 are provided
if [[ -z "$POLICY_NAME_TO_REPLACE" || -z "$REPLACEMENT_NAME" ]]; then
    echo "Usage: $0 <policy_name_to_replace> <replacement_name>"
    echo "Example: $0 'Old Policy Name' 'New Policy Name'"
    exit 1
fi

# select the instances that will be changed
choose_destination_instances

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# run on all chosen instances
for instance in "${instance_choice_array[@]}"; do
    # set the instance variable
    jss_instance="$instance"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
done

echo 
echo "Finished"
echo
