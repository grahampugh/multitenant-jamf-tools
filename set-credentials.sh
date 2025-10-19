#!/bin/bash

# --------------------------------------------------------------------------------
# Script to add the required credentials into your login keychain to allow repeated use.
# 
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# 2. Ask for the username (show any existing value of first instance in list as default)
# 3. Ask for the password (show the associated user if already existing)
# 4. Loop through each selected instance, check for an existing keychain entry, create or overwrite
# 5. Check the credentials are working using the API
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
    echo "
set-credentials.sh usage:
[no arguments]                   - interactive mode
-il FILENAME (without .txt)      - provide an instance list filename
                                (must exist in the instance-lists folder)
-i JSS_URL                       - perform action on a single instance
                                   (must exist in the relevant instance list)
-a | --all | --all-instances     - perform action on ALL instances in the instance list
-x | --nointeraction             - run without checking instance is in an instance list 
                                   (prevents interactive choosing of instances)
-v[vvv]                          - Set value of verbosity (default is -v)

"
}

check_credentials() {
    # grab the Jamf Pro version to check that communication is working.
    jss_url="$instance"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_url" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_url ($jss_api_user)"
    else
        set_credentials "$jss_url"
        echo "   [request] Using stored credentials for $jss_url ($jss_api_user)"
    fi
    # send request
    curl_url="$jss_url/api/v1/jamf-pro-version"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request
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
        --user|--id|--client-id)
            shift
            chosen_id="$1"
            ;;
        --pass|--secret|--client-secret)
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

# Ask for the instance list, show list, ask to apply to one, multiple or all
if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "   [main] Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "   [main] Running on instances: ${chosen_instances[*]}"
fi


# Ask for the instance list, show list, ask to apply to one, multiple or all
choose_destination_instances

# Ask for the username (show any existing value of first instance in list as default)
if [[ ! $chosen_id ]]; then
    echo "Enter username or Client ID for ${instance_choice_array[0]}"
    read -r -p "User/Client ID : " chosen_id
    if [[ ! $chosen_id ]]; then
        echo "No username/Client ID supplied"
        exit 1
    fi
fi

# check for existing service entry in login keychain
instance_base="${instance_choice_array[0]/*:\/\//}"

# first check if there is an entry for the server
server_check=$(security find-internet-password -s "${instance_choice_array[0]}" 2>/dev/null)
if [[ $server_check ]]; then
    echo "Keychain entry/ies for $instance_base found"
    # next check if there is an entry for the user on that server
    kc_check=$(security find-internet-password -s "${instance_choice_array[0]}" -l "$instance_base ($chosen_id)" -a "$chosen_id" -g 2>/dev/null)

    if [[ $kc_check ]]; then
        echo "Keychain entry for $chosen_id found on $instance_base"
        # check for existing password entry in login keychain
        instance_pass=$(security find-internet-password -s "${instance_choice_array[0]}" -l "$instance_base ($chosen_id)" -a "$chosen_id" -w -g 2>&1)
        if [[ ${#instance_pass} -gt 0 && $instance_pass != "security: "* ]]; then
            echo "Password/Client Secret for $chosen_id found on $instance_base"
        else
            echo "Password/Client Secret for $chosen_id not found on $instance_base"
            instance_pass=""
        fi
    else
        echo "Keychain entry for $chosen_id not found on $instance_base"
    fi
else
    echo "Keychain entry for $instance_base not found"
fi

# now delete all existing entries from the list of selected instances for any username
echo
for instance in "${instance_choice_array[@]}"; do
    instance_base="${instance/*:\/\//}"
    # Find and delete all keychain entries for this instance_base, repeatedly until none remain
    deleted_count=0
    while true; do
        # Find the first entry for this instance
        entry=$(security find-internet-password -s "$instance" 2>/dev/null)
        if [[ -z "$entry" ]]; then
            echo "No more entries found, done with $instance"
            break
        fi
        
        # Extract the label from the entry (stored in 0x00000007 attribute)
        label=$(echo "$entry" | grep "0x00000007" | awk -F'"' '{print $2}')
        if [[ $label == "$instance_base ("*")" ]]; then
            # Delete this specific entry
            echo "Deleting password for $label"
            if security delete-internet-password -s "$instance" -l "$label"; then
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
        echo "Deleted $deleted_count existing keychain entries for $instance_base"
    else
        echo "No existing keychain entries found for $instance_base"
    fi
done

echo

if [[ "$chosen_secret" ]]; then
    instance_pass="$chosen_secret"
else
    echo "Enter password/Client Secret for $chosen_id on $instance_base"
    [[ $instance_pass ]] && echo "(or press ENTER to use existing password/Client Secret from keychain for $chosen_id)"
    read -r -s -p "Pass : " chosen_secret
    if [[ "$chosen_secret" ]]; then
        instance_pass="$chosen_secret"
    elif [[ ! $instance_pass ]]; then
        echo "No password/Client Secret supplied"
        exit 1
    fi
fi

# Loop through each selected instance
echo
echo
for instance in "${instance_choice_array[@]}"; do
    instance_base="${instance/*:\/\//}"
    security add-internet-password -U -s "$instance" -l "$instance_base ($chosen_id)" -a "$chosen_id" -w "$instance_pass"
    echo "   [main] Credentials for $instance_base (user $chosen_id) added to keychain"
done

echo
for instance in "${instance_choice_array[@]}"; do
    instance_base="${instance/*:\/\//}"
    echo "   [main] Checking credentials for $instance_base (user $chosen_id)"
    check_credentials
    # print out version
    version=$( jq -r '.version' < "$curl_output_file" 2>/dev/null)
    if [[ $version ]]; then
        echo "   [main] Connection to $instance_base successful. Jamf Pro version: $version"
    else
        echo "   [main] Connection to $instance_base failed. Please check the credentials are correct."
    fi
done

echo
echo "Finished"
echo
