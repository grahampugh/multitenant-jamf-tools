#!/bin/bash

# --------------------------------------------------------------------------------
# Script to add the required credentials into your login keychain to allow repeated use.
# This script can only operate on one instance at a time, since each API client is unique.
# 1. Ask for the instance list, show list, ask to apply to one
# 2. Ask for the API client ID 
# 3. Ask for the API client password
# 4. Check the credentials are working using the API
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "   [main] ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_platformapi_credentials.sh          - set the Keychain Credentials
USAGE
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while test $# -gt 0 ; do
    case "$1" in
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
            ;;
        -i|--instance)
            shift
            chosen_instance="$1"
            ;;
        -a|-ai|--all|--all-instances)
            all_instances=1
            ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        --id|--client-id)
            shift
            chosen_id="$1"
            ;;
        --secret|--client-secret)
            shift
            chosen_secret="$1"
            ;;
        -v*)
            verbose=1
            ;;
        *)
            echo
            usage
            exit 0
            ;;
    esac
    shift
done
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "   [main] Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "   [main] Running on first chosen instance: ${chosen_instances[0]}"
fi

# select the instances that will be changed
choose_destination_instances
chosen_instance="${instance_choice_array[0]}"

# set the region based on the chosen instance
get_platform_api_region "$chosen_instance"

# set the URL based on the chosen region
if [[ $chosen_region ]]; then
    get_region_url
else
    # ask for the region
    echo "Enter region (eu, us, apac) for the tenant hosted on $chosen_instance"
    read -r -p "Region : " chosen_region
    if [[ ! $chosen_region ]]; then
        echo "   [main] No region supplied"
        exit 1
    fi
    get_region_url
    if [[ ! $api_base_url ]]; then
        echo "   [main] ERROR: Could not determine API URL for region $chosen_region"
        exit
    fi
fi

# Ask for the username (show any existing value of first instance in list as default)
if [[ ! $chosen_id ]]; then
    echo "Enter Client ID for $api_base_url"
    read -r -p "Client ID : " chosen_id
    if [[ ! $chosen_id ]]; then
        echo "   [main] No Client ID supplied"
        exit 1
    fi
fi

# check for existing service entry in login keychain
region_base="${api_base_url/*:\/\//}"

# first check if there is an entry for the server
server_check=$(security find-internet-password -s "$api_base_url" 2>/dev/null)
if [[ $server_check ]]; then
    echo "Keychain entry/ies for $region_base found"
    # next check if there is an entry for the user on that server
    kc_check=$(security find-internet-password -s "$api_base_url" -l "$region_base ($chosen_id)" -a "$chosen_id" -g 2>/dev/null)

    if [[ $kc_check ]]; then
        echo "Keychain entry for $chosen_id found on $region_base"
        # check for existing password entry in login keychain
        client_secret=$(security find-internet-password -s "$api_base_url" -l "$region_base ($chosen_id)" -a "$chosen_id" -w -g 2>&1)
        if [[ ${#client_secret} -gt 0 && $client_secret != "security: "* ]]; then
            echo "Password/Client Secret for $chosen_id found on $region_base"
        else
            echo "Password/Client Secret for $chosen_id not found on $region_base"
            client_secret=""
        fi
    else
        echo "Keychain entry for $chosen_id not found on $region_base"
    fi
else
    echo "Keychain entry for $region_base not found"
fi

# now delete all existing entries from the selected instance for any username
# Find and delete all keychain entries for this region, repeatedly until none remain
deleted_count=0
while true; do
    # Find the first entry for this region
    entry=$(security find-internet-password -s "$api_base_url" 2>/dev/null)
    if [[ -z "$entry" ]]; then
        echo "No more entries found, done with $api_base_url"
        break
    fi
    
    # Extract the label from the entry (stored in 0x00000007 attribute)
    label=$(echo "$entry" | grep "0x00000007" | awk -F'"' '{print $2}')
    if [[ $label == "$region_base ("*")" ]]; then
        # Delete this specific entry
        echo "Deleting password for $label"
        if security delete-internet-password -s "$api_base_url" -l "$label"; then
            ((deleted_count++))
        else
            # If deletion failed, break to avoid infinite loop
            break
        fi
    else
        # No matching label pattern found, break the loop
        break
    fi
done

if [[ $deleted_count -gt 0 ]]; then
    echo "Deleted $deleted_count existing keychain entries for $region_base"
else
    echo "No existing keychain entries found for $region_base"
fi

echo

if [[ ! "$chosen_secret" ]]; then
    echo "Enter Client Secret for $chosen_id on $region_base"
    [[ $instance_pass ]] && echo "(or press ENTER to use existing Client Secret from keychain for $chosen_id)"
    read -r -s -p "Pass : " chosen_secret
    if [[ $instance_pass && ! "$chosen_secret" ]]; then
        chosen_secret="$instance_pass"
    elif [[ ! $chosen_secret ]]; then
        echo "No Client Secret supplied"
        exit 1
    fi
fi

# Apply to selected instance
echo
echo
security add-internet-password -U -s "$api_base_url" -l "$region_base ($chosen_id)" -a "$chosen_id" -w "$chosen_secret"
echo "   [main] Credentials for $api_base_url (user $chosen_id) added to keychain"

# Verify the credentials
echo
echo "   [main] Checking credentials for $api_base_url (user $chosen_id)"
platform_api_client_id="$chosen_id"
platform_api_client_secret="$chosen_secret"
if check_platform_api_token; then
    echo "   [main] Credentials for $api_base_url (user $chosen_id) verified"
else
    echo "   [main] ERROR: Credentials for $api_base_url (user $chosen_id) could not be verified"
fi

echo
echo "Finished"
echo
