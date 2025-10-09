#!/bin/bash

: <<DOC
Script to add the required credentials into your login keychain to allow repeated use.

1. Ask for the instance list, show list, ask to apply to one, multiple or all
2. Ask for the username (show any existing value of first instance in list as default)
3. Ask for the password (show the associated user if already existing)
4. Loop through each selected instance, check for an existing keychain entry, create or overwrite
5. Check the credentials are working using the API
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# --------------------------------------------------------------------
# Functions
# --------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage:
./set_platformapi_credentials.sh          - set the Keychain Credentials
USAGE
}

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, get region
# ------------------------------------------------------------------------------------

choose_destination_instances
chosen_instance="${instance_choice_array[0]}"

# set the region based on the chosen instance
get_platform_api_region

# set the URL based on the chosen region
if [[ $chosen_region ]]; then
    get_region_url
else
    echo "ERROR: No region specified. Please provide a region using the --region option."
    exit 1
fi

# ------------------------------------------------------------------------------------
# 2. Ask for the Client ID
# ------------------------------------------------------------------------------------

echo "Enter Client ID for $api_base_url"
read -r -p "Client ID : " inputted_client_id
if [[ ! $inputted_client_id ]]; then
    echo "No Client ID supplied"
    exit 1
fi

# check for existing service entry in login keychain
region_base="${api_base_url/*:\/\//}"
kc_check=$(security find-internet-password -s "$api_base_url" -l "$region_base ($inputted_client_id)" -a "$inputted_client_id" -g 2>/dev/null)

if [[ $kc_check ]]; then
    echo "Keychain entry for $inputted_client_id found on $region_base"
else
    echo "Keychain entry for $inputted_client_id not found on $region_base"
fi

echo
# check for existing password entry in login keychain
client_secret=$(security find-internet-password -s "$api_base_url" -l "$region_base ($inputted_client_id)" -a "$inputted_client_id" -w -g 2>&1)

if [[ ${#client_secret} -gt 0 && $client_secret != "security: "* ]]; then
    echo "Client Secret for $inputted_client_id found on $region_base"
else
    echo "Client Secret for $inputted_client_id not found on $region_base"
fi

echo "Enter Client Secret for $inputted_client_id on $region_base"
[[ $client_secret ]] && echo "(or press ENTER to use existing Client Secret from keychain for $inputted_client_id)"
read -r -s -p "Pass : " inputted_secret
if [[ "$inputted_secret" ]]; then
    client_secret="$inputted_secret"
elif [[ ! $client_secret ]]; then
    echo "No Client Secret supplied"
    exit 1
fi

# ------------------------------------------------------------------------------------
# 3. Apply to selected instance
# ------------------------------------------------------------------------------------
echo
echo
security add-internet-password -U -s "$api_base_url" -l "$region_base ($inputted_client_id)" -a "$inputted_client_id" -w "$client_secret"
echo "Credentials for $api_base_url (user $inputted_client_id) added to keychain"

# ------------------------------------------------------------------------------------
# 4. Verify the credentials
# ------------------------------------------------------------------------------------

echo
echo "Checking credentials for $api_base_url (user $inputted_client_id)"
check_platform_api_token

echo
echo "Script complete"
echo
