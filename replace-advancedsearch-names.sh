#!/bin/bash

# --------------------------------------------------------------------------------
# Script for replacing a string within advanced search names across multiple instances
#
# USAGE:
# ./replace-advancedsearch-names.sh -o "Old String" -n "New String"
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

usage() {
    echo "Usage: $0 -o <old_string> -n <new_string> [options]"
    echo ""
    echo "Required:"
    echo "  -o | --old-string      String to find within advanced search names"
    echo "  -n | --new-string      Replacement string"
    echo ""
    echo "Options:"
    echo "  -i | --instance        Specific Jamf instance URL"
    echo "  -il | --instance-list  Path to a file containing a list of instances"
    echo "  -a | --all-instances   Run on all configured instances"
    echo "  --id | --client-id     Client ID / username override"
    echo "  -x | --nointeraction   Non-interactive mode"
    echo "  -v                     Verbosity (e.g. -v, -vv, -vvv)"
    echo "  -h | --help            Show this help"
    echo ""
    echo "Example:"
    echo "  $0 -o 'Old String' -n 'New String'"
}

run_autopkg() {
    # Extract subdomain from jss_instance (e.g., "https://myinstance.jamfcloud.com" -> "myinstance")
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    output_dir="/Users/Shared/Jamf/JamfUploader"

    # Repeat for advanced computer and mobile device searches
    for object_type in "advanced_computer_search" "advanced_mobile_device_search"; do

        if [[ "$object_type" == "advanced_computer_search" ]]; then
            json_key="advanced_computer_searches"
            change_recipe="$this_script_dir/recipes/ChangeAdvancedComputerSearchName.jamf.recipe.yaml"
        else
            json_key="advanced_mobile_device_searches"
            change_recipe="$this_script_dir/recipes/ChangeAdvancedMobileDeviceSearchName.jamf.recipe.yaml"
        fi

        # Download the full list for this search type
        "$this_script_dir/autopkg-run.sh" \
            --recipe "$this_script_dir/recipes/DownloadObjectList.jamf.recipe.yaml" \
            --key "OBJECT_TYPE=$object_type" \
            --key "OUTPUT_DIR=$output_dir" \
            --instance "$jss_instance" \
            --nointeraction \
            ${verbosity_mode:+"$verbosity_mode"}

        json_file="$output_dir/$subdomain-$json_key.json"
        if [[ ! -f "$json_file" ]]; then
            echo "No $object_type list found at $json_file for $jss_instance."
            continue
        fi

        # Loop through each search, rename those whose name contains OLD_STRING
        jq -c '.[]' "$json_file" | while read -r obj; do
            id=$(echo "$obj" | jq -r '.id')
            name=$(echo "$obj" | jq -r '.name')

            if [[ "$name" != *"$OLD_STRING"* ]]; then
                continue
            fi

            new_name="${name//$OLD_STRING/$NEW_STRING}"
            if [[ "$name" == "$new_name" ]]; then
                continue
            fi

            echo "Renaming '$name' -> '$new_name' (ID: $id)"
            echo "Running: \"$this_script_dir/autopkg-run.sh\" --recipe \"$change_recipe\" --instance \"$jss_instance\" --nointeraction --key \"OBJECT_ID=$id\" --key \"NEW_NAME=$new_name\" --replace${verbosity_mode:+ $verbosity_mode}"
            "$this_script_dir/autopkg-run.sh" \
                --recipe "$change_recipe" \
                --instance "$jss_instance" \
                --nointeraction \
                --key "OBJECT_ID=$id" \
                --key "NEW_NAME=$new_name" \
                --replace \
                ${verbosity_mode:+"$verbosity_mode"}
        done
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
        -o|--old-string)
            shift
            OLD_STRING="$1"
            ;;
        -n|--new-string)
            shift
            NEW_STRING="$1"
            ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

# ensure that both strings are provided
if [[ -z "$OLD_STRING" || -z "$NEW_STRING" ]]; then
    echo "Usage: $0 -o <old_string> -n <new_string>"
    echo "Example: $0 -o 'Old String' -n 'New String'"
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
