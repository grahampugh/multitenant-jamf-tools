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
    cat <<'USAGE'
Usage:
./set_credentials.sh          - set the Keychain Credentials
USAGE
}

check_credentials() {
    # grab the Jamf Pro version to check that communication is working.
    jss_url="$instance"
    set_credentials "$jss_url"
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
echo "Enter username or Client ID for ${instance_choice_array[0]}"
read -r -p "User/Client ID : " inputted_username
if [[ ! $inputted_username ]]; then
    echo "   [main] No username/Client ID supplied"
    exit 1
fi

# check for existing service entry in login keychain
instance_base="${instance_choice_array[0]/*:\/\//}"
kc_check=$(security find-internet-password -s "${instance_choice_array[0]}" -l "$instance_base ($inputted_username)" -a "$inputted_username" -g 2>/dev/null)

if [[ $kc_check ]]; then
    echo "   [main] Keychain entry for $inputted_username found on $instance_base"
else
    echo "   [main] Keychain entry for $inputted_username not found on $instance_base"
fi

echo
# check for existing password entry in login keychain
instance_pass=$(security find-internet-password -s "${instance_choice_array[0]}" -l "$instance_base ($inputted_username)" -a "$inputted_username" -w -g 2>&1)

if [[ ${#instance_pass} -gt 0 && $instance_pass != "security: "* ]]; then
    echo "   [main] Password/Client Secret for $inputted_username found on $instance_base"
else
    echo "   [main] Password/Client Secret for $inputted_username not found on $instance_base"
fi

echo "Enter password/Client Secret for $inputted_username on $instance_base"
[[ $instance_pass ]] && echo "(or press ENTER to use existing password/Client Secret from keychain for $inputted_username)"
read -r -s -p "Pass : " inputted_password
if [[ "$inputted_password" ]]; then
    instance_pass="$inputted_password"
elif [[ ! $instance_pass ]]; then
    echo "   [main] No password/Client Secret supplied"
    exit 1
fi

# Loop through each selected instance
echo
echo
for instance in "${instance_choice_array[@]}"; do
    instance_base="${instance/*:\/\//}"
    security add-internet-password -U -s "$instance" -l "$instance_base ($inputted_username)" -a "$inputted_username" -w "$instance_pass"
    echo "   [main] Credentials for $instance_base (user $inputted_username) added to keychain"
done

echo
for instance in "${instance_choice_array[@]}"; do
    instance_base="${instance/*:\/\//}"
    echo "   [main] Checking credentials for $instance_base (user $inputted_username)"
    check_credentials
    # print out version
    version=$( jq -r '.version' < "$curl_output_file" )
    if [[ $version ]]; then
        echo "   [main] Connection successful. Jamf Pro version: $version"
    fi
done

echo
echo "Finished"
echo
