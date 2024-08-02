#!/bin/bash

: <<'DOC'
Script for addin Fileshare Distribution Point credentials on multiple instances.
DOC

# source the _common-framework.sh file
# shellcheck source-path=SCRIPTDIR source=_common-framework.sh
source "_common-framework.sh"

usage() {
    cat <<'USAGE'
Usage:
NOTE: LDAP server is obtained automatically from the instance (must be configured already)

./set_credentials.sh                - set the Keychain credentials

[no arguments]                      - interactive mode
--name NAME                         - Display name for the share. If left blank will match the Share Name
--readwrite READWRITE_USER          - SMB server read/write user
-v                                  - show parsed template prior to uploading
USAGE
}

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

## MAIN BODY

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -n|--name)
            shift
            display_name="$1"
        ;;
        -rw|--readwrite)
            shift
            user_rw="$1"
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

# set keychain entry name
keychain_name="com.github.grahampugh.multitenant-jamf-tools.fsdp"

# set Display Name
if [[ ! $display_name ]]; then
    echo "Enter Fileshare Distribution Point Server Display Name"
    echo "(or press ENTER to use the same value as the SMB Share Name)"
    read -r -p "Display Name : " display_name
fi

# set display_name if not supplied earlier
if [[ ! $display_name ]]; then
    echo "ERROR: Must supply display name"
    exit 1
fi

# set read-write username
if [[ ! $user_rw ]]; then
    read -r -p "Enter Read/Write Username : " user_rw
    if [[ ! $user_rw ]]; then
        echo "ERROR: No Read/Write Username supplied, cannot continue"
        exit 1
    fi
fi

# check for existing service entry in login keychain
kc_check=$(security find-generic-password -s "$display_name" -l "$keychain_name (readwrite)" -a "$user_rw" -g 2>/dev/null)

if [[ $kc_check ]]; then
    echo "Keychain entry for $user_rw found for $display_name"
else
    echo "Keychain entry for $user_rw not found for $display_name"
fi

echo
# check for existing password entry in login keychain
pass_rw=$(security find-generic-password -s "$display_name" -l "$keychain_name (readwrite)" -a "$user_rw" -w -g 2>/dev/null)

if [[ $pass_rw ]]; then
    echo "Password for $user_rw found for $display_name"
else
    echo "Password for $user_rw not found for $display_name"
fi

# set read-write password
echo "Enter password for $user_rw on $display_name"
[[ $pass_rw ]] && echo "(or press ENTER to use existing password from keychain for $user_rw)"
read -r -s -p "Pass : " inputted_pass_rw
if [[ "$inputted_pass_rw" ]]; then
    pass_rw="$inputted_pass_rw"
elif [[ ! $pass_rw ]]; then
    echo "No password supplied"
    exit 1
fi

echo
if security add-generic-password -U -s "$display_name" -l "$keychain_name (readwrite)" -a "$user_rw" -w "$pass_rw"; then
    echo "Keychain entry '$keychain_name (readwrite)' added"
else
    echo "Could not create/update keychain entry '$keychain_name (readwrite)'"
fi

echo 
echo "Finished"
echo
