#!/bin/bash

# --------------------------------------------------------------------------------
# Script for creating static computer groups from individually scoped computers
# in scopeable opjects, and updating those objects to use the groups instead.
#
# This script will:
# 1. Download all objects of a specified type from a Jamf Pro instance
# 2. Identify objects with individually targeted or excluded computers
# 3. Create static computer groups for those computers
# 4. Update the objects to use the groups instead of individual computers
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
# Create Static Groups from Computers in Scoped Objects

This script identifies objects with individually targeted or excluded computers,
creates static computer groups for those computers, and updates the objects to
use the groups instead.

Usage:
./create-static-group-from-computers.sh -t <object_type> [options]

Options:
-t | --type OBJECT_TYPE            - REQUIRED: object type to process
                                     Valid types: policy, os_x_configuration_profile,
                                     configuration_profile, restricted_software,
                                     mac_application, mobile_device_application
-n | --name OBJECT_NAME            - process a single named object (optional)
-p | --prefix PREFIX               - prefix for target groups (default: "Testing - ")
-e | --exclusion-prefix PREFIX       - prefix for exclusion groups (default: "Testing - Exclude - ")
-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
-i | --instance JSS_URL            - perform action on a specific instance
-a | --all | --all-instances       - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list
--id | --client-id CLIENT_ID       - use the specified client ID or username
-v[vvv]                            - add verbose output
-h | --help                        - show this help message

USAGE
}

validate_object_type() {
    local object_type="$1"
    local valid_types=("policy" "os_x_configuration_profile" "configuration_profile" 
                       "restricted_software" "mac_application" "mobile_device_application")
    
    for valid_type in "${valid_types[@]}"; do
        if [[ "$object_type" == "$valid_type" ]]; then
            return 0
        fi
    done
    return 1
}

is_mobile_device_type() {
    local object_type="$1"
    case "$object_type" in
        configuration_profile|mobile_device_application)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

create_static_group_xml() {
    local group_name="$1"
    local device_ids_string="$2"
    local output_file="$3"
    local is_mobile_device="$4"

    if [[ "$is_mobile_device" == "true" ]]; then
        cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mobile_device_group>
    <name>$group_name</name>
    <is_smart>false</is_smart>
    <mobile_devices>
EOF

        # Add each mobile device ID to the XML
        IFS=',' read -ra ADDR <<< "$device_ids_string"
        for device_id in "${ADDR[@]}"; do
            cat >> "$output_file" <<EOF
        <mobile_device>
            <id>$device_id</id>
        </mobile_device>
EOF
        done

        cat >> "$output_file" <<EOF
    </mobile_devices>
</mobile_device_group>
EOF
    else
        cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<computer_group>
    <name>$group_name</name>
    <is_smart>false</is_smart>
    <computers>
EOF

        # Add each computer ID to the XML
        IFS=',' read -ra ADDR <<< "$device_ids_string"
        for device_id in "${ADDR[@]}"; do
            cat >> "$output_file" <<EOF
        <computer>
            <id>$device_id</id>
        </computer>
EOF
        done

        cat >> "$output_file" <<EOF
    </computers>
</computer_group>
EOF
    fi
}

create_object_scope_xml() {
    local original_file="$1"
    local output_file="$2"
    local target_group_name="$3"
    local exclusion_group_name="$4"
    local object_type="$5"

    # Determine the root element based on object type
    local root_element
    case "$object_type" in
        policy)
            root_element="policy"
            ;;
        os_x_configuration_profile)
            root_element="os_x_configuration_profile"
            ;;
        configuration_profile)
            root_element="configuration_profile"
            ;;
        restricted_software)
            root_element="restricted_software"
            ;;
        mac_application)
            root_element="mac_application"
            ;;
        mobile_device_application)
            root_element="mobile_device_application"
            ;;
    esac

    # Start the XML with just the scope element
    echo '<?xml version="1.0" encoding="UTF-8"?>' > "$output_file"
    echo "<$root_element>" >> "$output_file"

    # Extract the existing scope element and modify it
    xmllint --xpath '//scope' "$original_file" 2>/dev/null > "$temp_dir/scope_temp.xml"

    # Determine if this is a mobile device type
    local device_element device_group_element device_groups_element all_devices_element
    if is_mobile_device_type "$object_type"; then
        device_element="mobile_device"
        device_group_element="mobile_device_group"
        device_groups_element="mobile_device_groups"
        all_devices_element="all_mobile_devices"
    else
        device_element="computer"
        device_group_element="computer_group"
        device_groups_element="computer_groups"
        all_devices_element="all_computers"
    fi

    # Create a modified scope with devices removed and groups added
    echo '    <scope>' >> "$output_file"

    # Copy all_computers or all_mobile_devices element if it exists
    if xmllint --xpath "//scope/$all_devices_element" "$original_file" &>/dev/null; then
        xmllint --xpath "//scope/$all_devices_element" "$original_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Handle device groups - preserve existing and add new target group
    echo "        <$device_groups_element>" >> "$output_file"
    if xmllint --xpath "//scope/$device_groups_element/$device_group_element" "$original_file" &>/dev/null; then
        xmllint --xpath "//scope/$device_groups_element/$device_group_element" "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    # Add new target group if specified
    if [[ -n "$target_group_name" ]]; then
        echo "            <$device_group_element>" >> "$output_file"
        echo "                <name>$target_group_name</name>" >> "$output_file"
        echo "            </$device_group_element>" >> "$output_file"
    fi
    echo "        </$device_groups_element>" >> "$output_file"

    # Remove individual devices by creating empty devices element
    local devices_element
    if is_mobile_device_type "$object_type"; then
        devices_element="mobile_devices"
    else
        devices_element="computers"
    fi
    echo "        <$devices_element/>" >> "$output_file"

    # Copy buildings if they exist
    if xmllint --xpath '//scope/buildings' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/buildings' "$original_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Copy departments if they exist
    if xmllint --xpath '//scope/departments' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/departments' "$original_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Copy limitations if they exist
    if xmllint --xpath '//scope/limitations' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/limitations' "$original_file" 2>/dev/null | sed 's/^/        /' >> "$output_file"
    fi

    # Handle exclusions
    echo '        <exclusions>' >> "$output_file"

    # Copy existing exclusion device groups and add new one if specified
    echo "            <$device_groups_element>" >> "$output_file"
    if xmllint --xpath "//scope/exclusions/$device_groups_element/$device_group_element" "$original_file" &>/dev/null; then
        xmllint --xpath "//scope/exclusions/$device_groups_element/$device_group_element" "$original_file" 2>/dev/null | sed 's/^/                /' >> "$output_file"
    fi
    # Add new exclusion group if specified
    if [[ -n "$exclusion_group_name" ]]; then
        echo "                <$device_group_element>" >> "$output_file"
        echo "                    <name>$exclusion_group_name</name>" >> "$output_file"
        echo "                </$device_group_element>" >> "$output_file"
    fi
    echo "            </$device_groups_element>" >> "$output_file"

    # Remove individual excluded devices
    echo "            <$devices_element/>" >> "$output_file"

    # Copy other exclusion elements if they exist
    if xmllint --xpath '//scope/exclusions/buildings' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/buildings' "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/departments' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/departments' "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/users' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/users' "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/user_groups' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/user_groups' "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/network_segments' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/network_segments' "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi
    if xmllint --xpath '//scope/exclusions/ibeacons' "$original_file" &>/dev/null; then
        xmllint --xpath '//scope/exclusions/ibeacons' "$original_file" 2>/dev/null | sed 's/^/            /' >> "$output_file"
    fi

    echo '        </exclusions>' >> "$output_file"

    echo '    </scope>' >> "$output_file"
    echo "</$root_element>" >> "$output_file"
}

process_objects() {
    # Extract subdomain from jss_instance
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    
    # Get plural form of object type for filename matching
    object_type_plural=$(get_plural_from_api_xml_object "$OBJECT_TYPE")
    
    echo
    echo "================================================"
    echo "Processing instance: $jss_instance"
    echo "Object type: $OBJECT_TYPE"
    if [[ -n "$OBJECT_NAME" ]]; then
        echo "Object name: $OBJECT_NAME"
    fi
    echo "================================================"
    echo

    # Step 1: Download objects
    if [[ -n "$OBJECT_NAME" ]]; then
        echo "Step 1: Downloading '$OBJECT_NAME' from $jss_instance..."
        "$this_script_dir/autopkg-run.sh" "$verbosity_mode" \
            -r "$this_script_dir/recipes/DownloadObject.jamf.recipe.yaml" \
            --nointeraction \
            --instance "$jss_instance" \
            --key "OUTPUT_DIR=$output_dir" \
            --key "OBJECT_NAME=$OBJECT_NAME" \
            --key OBJECT_TYPE="$OBJECT_TYPE"
    else
        echo "Step 1: Downloading all ${object_type_plural} from $jss_instance..."
        "$this_script_dir/autopkg-run.sh" "$verbosity_mode" \
            -r "$this_script_dir/recipes/DownloadAllObjects.jamf.recipe.yaml" \
            --nointeraction \
            --instance "$jss_instance" \
            --key "OUTPUT_DIR=$output_dir" \
            --key OBJECT_TYPE="$OBJECT_TYPE"
    fi

    if [[ $? -ne 0 ]]; then
        errors+=("Failed to download ${object_type_plural} from $jss_instance")
        return 1
    fi

    # Step 2: Find and process objects with individual computers
    echo
    echo "Step 2: Analyzing ${object_type_plural} for individually scoped computers..."
    
    # Find all object files for this instance
    object_files=("$output_dir/$subdomain-${object_type_plural}-"*.xml)
    
    if [[ ! -e "${object_files[0]}" ]]; then
        echo "No policy files found for $subdomain"
        return 0
    fi

    objects_processed=0
    objects_with_individual_computers=0

    # Determine if this object type uses mobile devices
    local is_mobile_device="false"
    local device_element devices_element device_group_type
    if is_mobile_device_type "$OBJECT_TYPE"; then
        is_mobile_device="true"
        device_element="mobile_device"
        devices_element="mobile_devices"
        device_group_type="mobile_device_group"
    else
        device_element="computer"
        devices_element="computers"
        device_group_type="computer_group"
    fi

    for object_file in "${object_files[@]}"; do
        if [[ ! -f "$object_file" ]]; then
            continue
        fi

        # Extract object name from filename
        object_name=$(basename "$object_file" | sed "s/^$subdomain-$object_type_plural-//" | sed 's/\.xml$//')
        
        echo
        echo "  Checking $OBJECT_TYPE: $object_name"
        
        ((objects_processed++))

        # Check for targeted devices
        targeted_device_ids=""
        if xmllint --xpath "//scope/$devices_element/$device_element/id" "$object_file" &>/dev/null; then
            targeted_device_ids=$(xmllint --xpath "//scope/$devices_element/$device_element/id/text()" "$object_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        fi

        # Check for excluded devices
        excluded_device_ids=""
        if xmllint --xpath "//scope/exclusions/$devices_element/$device_element/id" "$object_file" &>/dev/null; then
            excluded_device_ids=$(xmllint --xpath "//scope/exclusions/$devices_element/$device_element/id/text()" "$object_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        fi

        # Skip if no individual devices found
        if [[ -z "$targeted_device_ids" && -z "$excluded_device_ids" ]]; then
            if [[ "$is_mobile_device" == "true" ]]; then
                echo "    No individually scoped mobile devices found."
            else
                echo "    No individually scoped computers found."
            fi
            continue
        fi

        ((objects_with_individual_computers++))
        if [[ "$is_mobile_device" == "true" ]]; then
            echo "    Found individually scoped mobile devices!"
        else
            echo "    Found individually scoped computers!"
        fi

        # Process targeted devices
        target_group_name=""
        if [[ -n "$targeted_device_ids" ]]; then
            target_group_name="${TARGET_GROUP_PREFIX}${object_name}"
            echo "    Creating target group: $target_group_name"
            
            # Create the static group XML template
            target_group_template="$temp_dir/$subdomain-target-group-$objects_with_individual_computers.xml"
            create_static_group_xml "$target_group_name" "$targeted_device_ids" "$target_group_template" "$is_mobile_device"
            
            # Upload the group
            echo "    Uploading target group..."
            "$this_script_dir/autopkg-run.sh" "$verbosity_mode" \
                -r "$this_script_dir/recipes/UploadObject.jamf.recipe.yaml" \
                --nointeraction \
                --instance "$jss_instance" \
                --key "OBJECT_NAME=$target_group_name" \
                --key OBJECT_TYPE="$device_group_type" \
                --key "OBJECT_TEMPLATE=$target_group_template"
            
            if [[ $? -ne 0 ]]; then
                errors+=("Failed to create target group '$target_group_name' for $OBJECT_TYPE '$object_name' on $jss_instance")
            fi
        fi

        # Process excluded devices
        exclusion_group_name=""
        if [[ -n "$excluded_device_ids" ]]; then
            exclusion_group_name="${EXCLUSION_GROUP_PREFIX}${object_name}"
            echo "    Creating exclusion group: $exclusion_group_name"
            
            # Create the static group XML template
            exclusion_group_template="$temp_dir/$subdomain-exclusion-group-$objects_with_individual_computers.xml"
            create_static_group_xml "$exclusion_group_name" "$excluded_device_ids" "$exclusion_group_template" "$is_mobile_device"
            
            # Upload the group
            echo "    Uploading exclusion group..."
            "$this_script_dir/autopkg-run.sh" "$verbosity_mode" \
                -r "$this_script_dir/recipes/UploadObject.jamf.recipe.yaml" \
                --nointeraction \
                --instance "$jss_instance" \
                --key "OBJECT_NAME=$exclusion_group_name" \
                --key OBJECT_TYPE="$device_group_type" \
                --key "OBJECT_TEMPLATE=$exclusion_group_template"
            
            if [[ $? -ne 0 ]]; then
                errors+=("Failed to create exclusion group '$exclusion_group_name' for $OBJECT_TYPE '$object_name' on $jss_instance")
            fi
        fi

        # Update the object
        echo "    Updating $OBJECT_TYPE scope..."
        
        # Create the modified object scope template
        object_scope_template="$temp_dir/$subdomain-object-scope-$objects_with_individual_computers.xml"
        create_object_scope_xml "$object_file" "$object_scope_template" "$target_group_name" "$exclusion_group_name" "$OBJECT_TYPE"
        
        # Upload the updated object
        "$this_script_dir/autopkg-run.sh" "$verbosity_mode" \
            -r "$this_script_dir/recipes/UploadObject.jamf.recipe.yaml" \
            --nointeraction \
            --instance "$jss_instance" \
            --key "OBJECT_NAME=$object_name" \
            --key OBJECT_TYPE="$OBJECT_TYPE" \
            --key "OBJECT_TEMPLATE=$object_scope_template" \
            --replace
        
        if [[ $? -ne 0 ]]; then
            errors+=("Failed to update $OBJECT_TYPE '$object_name' on $jss_instance")
        else
            echo "    Successfully updated $OBJECT_TYPE: $object_name"
        fi
    done

    echo
    echo "Summary for $jss_instance:"
    echo "  Total ${object_type_plural} analyzed: $objects_processed"
    if [[ "$is_mobile_device" == "true" ]]; then
        echo "  ${OBJECT_TYPE}s with individual mobile devices: $objects_with_individual_computers"
    else
        echo "  ${OBJECT_TYPE}s with individual computers: $objects_with_individual_computers"
    fi
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
chosen_instances=()
OBJECT_TYPE=""
OBJECT_NAME=""
TARGET_GROUP_PREFIX="Testing - "
EXCLUSION_GROUP_PREFIX="Testing - Exclude - "
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -t|--type)
            shift
            OBJECT_TYPE="$1"
            ;;
        -n|--name)
            shift
            OBJECT_NAME="$1"
            ;;
        -p|--prefix)
            shift
            TARGET_GROUP_PREFIX="$1"
            ;;
        -e|--exclusion-prefix)
            shift
            EXCLUSION_GROUP_PREFIX="$1"
            ;;
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
    esac
    # Shift after checking all the cases to get the next option
    shift
done

# Validate that object type is provided
if [[ -z "$OBJECT_TYPE" ]]; then
    echo "ERROR: Object type is required."
    echo
    usage
    exit 1
fi

# Validate object type
if ! validate_object_type "$OBJECT_TYPE"; then
    echo "ERROR: Invalid object type: $OBJECT_TYPE"
    echo
    usage
    exit 1
fi

echo
if [[ -n "$OBJECT_NAME" ]]; then
    echo "This script will create static computer groups from individually scoped"
    echo "computers in the specified $OBJECT_TYPE and update it to use the groups."
else
    echo "This script will create static computer groups from individually scoped"
    echo "computers in ${OBJECT_TYPE}s and update those objects to use the groups."
fi
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
    
    process_objects
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
