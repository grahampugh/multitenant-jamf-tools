#!/bin/bash

# --------------------------------------------------------------------------------
# Script for dissecting a monolithic configuration profile into discrete payloads
# and uploading each payload back to Jamf Pro as its own profile using AutoPkg.
# 
# By Graham Pugh (@grahampugh), based off an idea for reporting non-default keys 
# in a monolithic profile by Neil Martin (@neilmartin83).
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "$this_script_dir" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# CONSTANTS
# --------------------------------------------------------------------------------

convert_recipe_identifier="com.github.autopkg.grahampugh-recipes.jamf.ConvertMonolithicProfile"
upload_recipe_path="$this_script_dir/recipes/UploadCustomComputerProfile.jamf.recipe.yaml"
default_profile_template="$this_script_dir/templates/Profile-no-scope.xml"
output_dir="/Users/Shared/Jamf/JamfUploader"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: ./dissect-monolithic-profile.sh [options]

Required:
  -p, --profile-name NAME          Display name of the monolithic profile to download.

Recommended:
      --profile-template PATH      Path to Jamf profile template XML (default: templates/Profile-single-group.xml).

Optional:
      --profile-category NAME      Jamf category for uploaded profiles (default: Global Policy).
      --target-group NAME          Smart/static group assigned to the profile scope (default: No scope).
      --organization NAME          Organization string to embed in the profile (default: None).
      --name-prefix TEXT           Text prefixed to each generated profile name.
      --name-suffix TEXT           Text appended to each generated profile name.
      --identifier-prefix TEXT     Prefix used to build profile identifiers (default: com.example.converted).
      --profile-description TEXT   Overrides the description for uploaded profiles. When omitted, a helpful
                                   description mentioning the payload and source profile is generated.

Instance selection flags (-i, -il, -a, --id, -x) and verbosity flags (-v*), match other toolkit scripts.
USAGE
}

converted_files=()

run_conversion() {
    converted_files=()
    local timestamp_file
    timestamp_file=$(mktemp /tmp/dissect-profile.XXXX)
    /usr/bin/touch "$timestamp_file"

    local autopkg_cmd=(
        "$this_script_dir/autopkg-run.sh"
        --recipe "$convert_recipe_identifier"
        --instance "$jss_instance"
        --nointeraction
        --key NAME="$MONOLITHIC_PROFILE_NAME"
    )
    if [[ $verbosity_mode ]]; then
        autopkg_cmd+=("$verbosity_mode")
    fi

    echo "Downloading and dissecting '$MONOLITHIC_PROFILE_NAME' from $jss_instance..."
    if ! "${autopkg_cmd[@]}"; then
        echo "ERROR: AutoPkg conversion failed for $jss_instance."
        rm -f "$timestamp_file"
        return 1
    fi

    while IFS= read -r -d '' plist_path; do
        converted_files+=("$plist_path")
    done < <(find "$output_dir" -maxdepth 1 -type f -name "*.plist" -newer "$timestamp_file" -print0)

    rm -f "$timestamp_file"

    if [[ ${#converted_files[@]} -eq 0 ]]; then
        echo "No discrete payload files were created. Nothing to upload."
        return 1
    fi

    echo "Created ${#converted_files[@]} payload file(s)."
    return 0
}

sanitize_identifier() {
    local raw="$1"
    local identifier
    identifier=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
    identifier=${identifier// /-}
    identifier=${identifier//[^a-z0-9._-]/-}
    echo "$identifier"
}

upload_payloads() {
    local plist_path
    for plist_path in "${converted_files[@]}"; do
        [[ -f "$plist_path" ]] || continue
        local domain_name
        domain_name=$(basename "$plist_path")
        domain_name="${domain_name%.plist}"

        local profile_name
        profile_name="${PROFILE_NAME_PREFIX}${domain_name}${PROFILE_NAME_SUFFIX}"
        local description_value
        if [[ $PROFILE_DESCRIPTION ]]; then
            description_value="$PROFILE_DESCRIPTION"
        else
            description_value="Converted payload ${domain_name} extracted from ${MONOLITHIC_PROFILE_NAME}."
        fi

        local identifier_suffix
        identifier_suffix=$(sanitize_identifier "$domain_name")
        local identifier_value
        identifier_value="${IDENTIFIER_PREFIX}.${identifier_suffix}"

        echo "Uploading payload '$domain_name' as profile '$profile_name'..."
        local autopkg_cmd=(
            "$this_script_dir/autopkg-run.sh"
            --recipe "$upload_recipe_path"
            --instance "$jss_instance"
            --nointeraction
            --key PROFILE_NAME="$profile_name"
            --key PROFILE_CATEGORY="$PROFILE_CATEGORY"
            --key PROFILE_TEMPLATE="$PROFILE_TEMPLATE"
            --key PROFILE_PAYLOAD="$plist_path"
            --key IDENTIFIER="$identifier_value"
            --key ORGANIZATION="$ORGANIZATION"
            --key PROFILE_DESCRIPTION="$description_value"
        )
        if [[ $TARGET_GROUP_NAME ]]; then
            autopkg_cmd+=(--key TARGET_GROUP_NAME="$TARGET_GROUP_NAME")
        fi

        if [[ $verbosity_mode ]]; then
            autopkg_cmd+=("$verbosity_mode")
        fi

        if ! "${autopkg_cmd[@]}"; then
            echo "ERROR: Failed to upload payload '$domain_name' for $jss_instance."
        else
            echo "Uploaded payload '$domain_name' successfully."
        fi
    done
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

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
            exit 0
            ;;
        -p|--profile-name)
            shift
            MONOLITHIC_PROFILE_NAME="$1"
            ;;
        --profile-template)
            shift
            PROFILE_TEMPLATE="$1"
            ;;
        --profile-category)
            shift
            PROFILE_CATEGORY="$1"
            ;;
        --target-group)
            shift
            TARGET_GROUP_NAME="$1"
            ;;
        --organization)
            shift
            ORGANIZATION="$1"
            ;;
        --name-prefix)
            shift
            PROFILE_NAME_PREFIX="$1"
            ;;
        --name-suffix)
            shift
            PROFILE_NAME_SUFFIX="$1"
            ;;
        --identifier-prefix)
            shift
            IDENTIFIER_PREFIX="$1"
            ;;
        --profile-description)
            shift
            PROFILE_DESCRIPTION="$1"
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$MONOLITHIC_PROFILE_NAME" ]]; then
    echo "ERROR: You must supply the name of the profile to dissect with --profile-name."
    exit 1
fi

PROFILE_TEMPLATE="${PROFILE_TEMPLATE:-$default_profile_template}"
if [[ ! -f "$PROFILE_TEMPLATE" ]]; then
    echo "ERROR: Profile template not found at '$PROFILE_TEMPLATE'."
    exit 1
fi
PROFILE_CATEGORY="${PROFILE_CATEGORY:-Global Policy}"
TARGET_GROUP_NAME="${TARGET_GROUP_NAME:-All Managed Clients}"
ORGANIZATION="${ORGANIZATION:-None}"
IDENTIFIER_PREFIX="${IDENTIFIER_PREFIX:-com.example.converted}"
PROFILE_NAME_PREFIX="${PROFILE_NAME_PREFIX:-}"
PROFILE_NAME_SUFFIX="${PROFILE_NAME_SUFFIX:-}"

choose_destination_instances

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    echo "Running on instance: ${chosen_instances[0]}"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi

    if run_conversion; then
        upload_payloads
    else
        echo "Skipping upload for $jss_instance due to previous errors."
    fi
    echo
    echo "Completed processing for $jss_instance"
    echo

done

echo
echo "Finished"
echo
