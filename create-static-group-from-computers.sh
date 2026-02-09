#!/bin/bash

# --------------------------------------------------------------------------------
# Script for creating static computer groups from individually scoped computers
# in policies, and updating those policies to use the groups instead.
#
# This script will:
# 1. Download all policies from a Jamf Pro instance
# 2. Identify policies with individually targeted or excluded computers
# 3. Create static computer groups for those computers
# 4. Update the policies to use the groups instead of individual computers
#
# USAGE:
# ./create-static-group-from-computers.sh [-i instance] [-il instance-list] [-a]
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

# set up output directory
output_dir="/Users/Shared/Jamf/JamfUploaderTests"
mkdir -p "$output_dir"

# temp directory for generated templates
temp_dir="/tmp/create-static-groups"
mkdir -p "$temp_dir"

# Array to store errors
declare -a errors

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
# Create Static Groups from Computers in Policies

This script identifies policies with individually targeted or excluded computers,
creates static computer groups for those computers, and updates the policies to
use the groups instead.

Usage:
./create-static-group-from-computers.sh [options]

Options:
-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
-i | --instance JSS_URL            - perform action on a specific instance
-a | --all | --all-instances       - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list
--id | --client-id CLIENT_ID       - use the specified client ID or username
-v[vvv]                            - add verbose output
-h | --help                        - show this help message

USAGE
}

create_static_group_xml() {
    local group_name="$1"
    local computer_ids="$2"
    local output_file="$3"

    cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<computer_group>
    <name>$group_name</name>
    <is_smart>false</is_smart>
    <computers>
EOF

    # Add each computer ID to the XML
    IFS=',' read -ra ADDR <<< "$computer_ids"
    for computer_id in "${ADDR[@]}"; do
        cat >> "$output_file" <<EOF
        <computer>
            <id>$computer_id</id>
        </computer>
EOF
    done

    cat >> "$output_file" <<EOF
    </computers>
</computer_group>
EOF
}

create_policy_scope_xml() {
    local original_policy_file="$1"
    local output_file="$2"
    local target_group_name="$3"
    local exclusion_group_name="$4"

    # Start the policy XML with just the scope element
    echo '<?xml version="1.0" encoding="UTF-8"?>' > "$output_file"
    echo '<policy>' >> "$output_file"

    # Extract the existing scope element and modify it
    xmllint --xpath '//scope' "$original_policy_file" 2>/dev/null > "$temp_dir/scope_temp.xml"

    # Create a modified scope with computers removed and groups added
    echo '    <scope>' >> "$output_file"

    # Copy all_computers element if it exists
    if xmllint --xpath '//scope/all_computers' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/all_computers' "$original_policy_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Handle computer_groups - preserve existing and add new target group
    echo '        <computer_groups>' >> "$output_file"
    if xmllint --xpath '//scope/computer_groups/computer_group' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/computer_groups/computer_group' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    # Add new target group if specified
    if [[ -n "$target_group_name" ]]; then
        echo "            <computer_group>" >> "$output_file"
        echo "                <name>$target_group_name</name>" >> "$output_file"
        echo "            </computer_group>" >> "$output_file"
    fi
    echo '        </computer_groups>' >> "$output_file"

    # Remove individual computers by creating empty computers element
    echo '        <computers/>' >> "$output_file"

    # Copy buildings if they exist
    if xmllint --xpath '//scope/buildings' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/buildings' "$original_policy_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Copy departments if they exist
    if xmllint --xpath '//scope/departments' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/departments' "$original_policy_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Copy limitations if they exist
    if xmllint --xpath '//scope/limitations' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/limitations' "$original_policy_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Handle exclusions
    echo '        <exclusions>' >> "$output_file"

    # Copy existing exclusion computer_groups and add new one if specified
    echo '            <computer_groups>' >> "$output_file"
    if xmllint --xpath '//scope/exclusions/computer_groups/computer_group' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/computer_groups/computer_group' "$original_policy_file" 2>/dev/null | sed 's/^/                /' >> "$output_file"
    fi
    # Add new exclusion group if specified
    if [[ -n "$exclusion_group_name" ]]; then
        echo "                <computer_group>" >> "$output_file"
        echo "                    <name>$exclusion_group_name</name>" >> "$output_file"
        echo "                </computer_group>" >> "$output_file"
    fi
    echo '            </computer_groups>' >> "$output_file"

    # Remove individual excluded computers
    echo '            <computers/>' >> "$output_file"

    # Copy other exclusion elements if they exist
    if xmllint --xpath '//scope/exclusions/buildings' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/buildings' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/departments' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/departments' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/users' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/users' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/user_groups' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/user_groups' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/network_segments' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/network_segments' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/ibeacons' "$original_policy_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/ibeacons' "$original_policy_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi

    echo '        </exclusions>' >> "$output_file"

    echo '    </scope>' >> "$output_file"
    echo '</policy>' >> "$output_file"
}

process_policies() {
    # Extract subdomain from jss_instance
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    
    echo
    echo "================================================"
    echo "Processing instance: $jss_instance"
    echo "================================================"
    echo

    # Step 1: Download all policies
    echo "Step 1: Downloading all policies from $jss_instance..."
    "$this_script_dir/autopkg-run.sh" \
        -r "$this_script_dir/recipes/DownloadAllObjects.jamf.recipe.yaml" \
        --nointeraction \
        --instance "$jss_instance" \
        --key "OUTPUT_DIR=$output_dir" \
        --key OBJECT_TYPE=policy

    if [[ $? -ne 0 ]]; then
        errors+=("Failed to download policies from $jss_instance")
        return 1
    fi

    # Step 2: Find and process policies with individual computers
    echo
    echo "Step 2: Analyzing policies for individually scoped computers..."
    
    # Find all policy files for this instance
    policy_files=("$output_dir/$subdomain-policies-"*.xml)
    
    if [[ ! -e "${policy_files[0]}" ]]; then
        echo "No policy files found for $subdomain"
        return 0
    fi

    policies_processed=0
    policies_with_individual_computers=0

    for policy_file in "${policy_files[@]}"; do
        if [[ ! -f "$policy_file" ]]; then
            continue
        fi

        # Extract policy name from filename
        policy_name=$(basename "$policy_file" | sed "s/^$subdomain-policies-//" | sed 's/\.xml$//')
        
        echo
        echo "  Checking policy: $policy_name"
        
        ((policies_processed++))

        # Check for targeted computers
        targeted_computer_ids=""
        if xmllint --xpath '//scope/computers/computer/id' "$policy_file" &>/dev/null; then
            targeted_computer_ids=$(xmllint --xpath '//scope/computers/computer/id/text()' "$policy_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        fi

        # Check for excluded computers
        excluded_computer_ids=""
        if xmllint --xpath '//scope/exclusions/computers/computer/id' "$policy_file" &>/dev/null; then
            excluded_computer_ids=$(xmllint --xpath '//scope/exclusions/computers/computer/id/text()' "$policy_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        fi

        # Skip if no individual computers found
        if [[ -z "$targeted_computer_ids" && -z "$excluded_computer_ids" ]]; then
            echo "    No individually scoped computers found."
            continue
        fi

        ((policies_with_individual_computers++))
        echo "    Found individually scoped computers!"

        # Process targeted computers
        target_group_name=""
        if [[ -n "$targeted_computer_ids" ]]; then
            target_group_name="Testing - $policy_name"
            echo "    Creating target group: $target_group_name"
            
            # Create the static group XML template
            target_group_template="$temp_dir/$subdomain-target-group-$policies_with_individual_computers.xml"
            create_static_group_xml "$target_group_name" "$targeted_computer_ids" "$target_group_template"
            
            # Upload the group
            echo "    Uploading target group..."
            "$this_script_dir/autopkg-run.sh" \
                -r "$this_script_dir/recipes/UploadObject.jamf.recipe.yaml" \
                --nointeraction \
                --instance "$jss_instance" \
                --key "OBJECT_NAME=$target_group_name" \
                --key OBJECT_TYPE=computer_group \
                --key "OBJECT_TEMPLATE=$target_group_template"
            
            if [[ $? -ne 0 ]]; then
                errors+=("Failed to create target group '$target_group_name' for policy '$policy_name' on $jss_instance")
            fi
        fi

        # Process excluded computers
        exclusion_group_name=""
        if [[ -n "$excluded_computer_ids" ]]; then
            exclusion_group_name="Testing - Exclude - $policy_name"
            echo "    Creating exclusion group: $exclusion_group_name"
            
            # Create the static group XML template
            exclusion_group_template="$temp_dir/$subdomain-exclusion-group-$policies_with_individual_computers.xml"
            create_static_group_xml "$exclusion_group_name" "$excluded_computer_ids" "$exclusion_group_template"
            
            # Upload the group
            echo "    Uploading exclusion group..."
            "$this_script_dir/autopkg-run.sh" \
                -r "$this_script_dir/recipes/UploadObject.jamf.recipe.yaml" \
                --nointeraction \
                --instance "$jss_instance" \
                --key "OBJECT_NAME=$exclusion_group_name" \
                --key OBJECT_TYPE=computer_group \
                --key "OBJECT_TEMPLATE=$exclusion_group_template"
            
            if [[ $? -ne 0 ]]; then
                errors+=("Failed to create exclusion group '$exclusion_group_name' for policy '$policy_name' on $jss_instance")
            fi
        fi

        # Update the policy
        echo "    Updating policy scope..."
        
        # Create the modified policy scope template
        policy_scope_template="$temp_dir/$subdomain-policy-scope-$policies_with_individual_computers.xml"
        create_policy_scope_xml "$policy_file" "$policy_scope_template" "$target_group_name" "$exclusion_group_name"
        
        # Upload the updated policy
        "$this_script_dir/autopkg-run.sh" \
            -r "$this_script_dir/recipes/UploadObject.jamf.recipe.yaml" \
            --nointeraction \
            --instance "$jss_instance" \
            --key "OBJECT_NAME=$policy_name" \
            --key OBJECT_TYPE=policy \
            --key "OBJECT_TEMPLATE=$policy_scope_template" \
            --replace
        
        if [[ $? -ne 0 ]]; then
            errors+=("Failed to update policy '$policy_name' on $jss_instance")
        else
            echo "    ✓ Successfully updated policy: $policy_name"
        fi
    done

    echo
    echo "Summary for $jss_instance:"
    echo "  Total policies analyzed: $policies_processed"
    echo "  Policies with individual computers: $policies_with_individual_computers"
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
echo "This script will create static computer groups from individually scoped"
echo "computers in policies and update those policies to use the groups."
echo

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
    
    process_policies
done

# Clean up temp directory
rm -rf "$temp_dir"

# Print error summary
echo
echo "================================================"
echo "FINAL SUMMARY"
echo "================================================"
if [[ ${#errors[@]} -eq 0 ]]; then
    echo "All operations completed successfully!"
else
    echo "Errors encountered:"
    for error in "${errors[@]}"; do
        echo "  - $error"
    done
fi

echo 
echo "Finished"
echo
