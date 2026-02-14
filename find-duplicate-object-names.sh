#!/bin/bash

# --------------------------------------------------------------------------------
# Script for finding duplicate object names using AutoPkg
# USAGE:
# ./find-duplicate-object-names.sh --object-type policy
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "$this_script_dir" ]]; then
    echo "   [request] ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# check if autopkg is installed, otherwise this won't work
autopkg_binary="/usr/local/bin/autopkg"
if [[ ! -x "$autopkg_binary" ]]; then
    echo "   [request] ERROR: AutoPkg not found at $autopkg_binary. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

run_autopkg() {
    # Extract subdomain from jss_instance (e.g., "https://myinstance.jamfcloud.com" -> "myinstance")
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)

    # Run the autopkg command with the extracted values
    echo "   [request] OBJECT_TYPE=$OBJECT_TYPE"
    echo
    "$autopkg_binary" run "$verbosity_mode" "$this_script_dir/recipes/DownloadObjectList.jamf.recipe.yaml" \
        --key OBJECT_TYPE="$OBJECT_TYPE" \
        --key "JSS_URL=$jss_instance" \
        --key OUTPUT_DIR="/Users/Shared/Jamf/JamfUploader"

    object_api_type=$(get_plural_from_api_xml_object "$OBJECT_TYPE")
    if [[ -z "$object_api_type" ]]; then
        echo "   [request] ERROR: Could not determine API object type for $OBJECT_TYPE. Aborting."
        exit 1
    fi

    output_file="/Users/Shared/Jamf/JamfUploader/${subdomain}-${object_api_type}.json"
    if [[ ! -f "$output_file" ]]; then
        echo "   [request] ERROR: Expected output file $output_file not found. Aborting."
        exit 1
    fi
}

find_duplicates() {
    # Function to find duplicate names in the downloaded object list and output to a new file
    duplicates_file="/Users/Shared/Jamf/JamfUploader/${subdomain}-${object_api_type}-duplicates.txt"
    duplicates_output_file="/Users/Shared/Jamf/JamfUploader/${subdomain}-${object_api_type}-duplicates-ids.csv"

    echo
    echo "   [request] Finding duplicate names in $output_file..."
    jq -r '.[].name' "$output_file" | sort | uniq -d > "$duplicates_file"

    # now print out all duplicates in the form ID: Name
    if [[ -s "$duplicates_file" ]]; then
        echo "$OBJECT_TYPE id,$OBJECT_TYPE name" > "$duplicates_output_file"
        echo
        echo "----------------------------------------------------------------------"
        echo "Duplicate names found for $jss_instance ($OBJECT_TYPE):"
        echo "----------------------------------------------------------------------"
        while IFS= read -r duplicate_name; do
            # echo "Duplicates for name: $duplicate_name"
            jq -r --arg name "$duplicate_name" '.[] | select(.name == $name) | "\(.id): \(.name)"' "$output_file" 
            jq -r --arg name "$duplicate_name" '.[] | select(.name == $name) | "\(.id),\"\(.name)\""' "$output_file" >> "$duplicates_output_file"
        echo "----------------------------------------------------------------------"
        done < "$duplicates_file"
        echo
        echo "----------------------------------------------------------------------"
        echo "CSV file outputted to $duplicates_output_file"
        echo
    else
        echo
        echo "----------------------------------------------------------------------"
        echo "No duplicate names found for $jss_instance ($OBJECT_TYPE)."
        echo "----------------------------------------------------------------------"
        echo
    fi
    rm -f "$duplicates_file"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
chosen_instances=()
verbosity_mode="-v"
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
        -t|-o|--type|--object-type)
            shift
            OBJECT_TYPE="$1"
            ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
if [[ -z "$OBJECT_TYPE" ]]; then
    echo "   [request] ERROR: No object type specified. Use the -t or --type option to specify the object type."
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
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    echo "   [request] Running AutoPkg on $jss_instance..."
    run_autopkg
    find_duplicates
done

echo 
echo "Finished"
echo
