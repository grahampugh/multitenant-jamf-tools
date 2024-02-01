#!/bin/bash

: <<'DOC'
Script for setting the Fileshare Distribution Point on all instances.
Requires a template XML file
DOC

# source the get-token.sh file
# shellcheck source-path=SCRIPTDIR source=get-token.sh
source "get-token.sh"

usage() {
    cat <<'USAGE'
Usage:
NOTE: LDAP server is obtained automatically from the instance (must be configured already)

./set_credentials.sh                - set the Keychain credentials

[no arguments]                      - interactive mode
--template /path/to/Template.xml    - template to use (must be a .xml file)
--name NAME                         - Display name for the share. If left blank will match the Share Name
--smb_url SMB_URL                   - SMB server + share, excluding smb:// (URL, e.g. myserver.com/MyShare)
--readwrite READWRITE_USER          - SMB server read/write user
--readonly READONLY_USER            - SMB server read-only user
--il FILENAME (without .txt)        - provide an instance list filename
                                        (must exist in the instance-lists folder)
--i JSS_URL                         - perform action on a single instance
                                        (must exist in the relevant instance list)
--all                               - perform action on ALL instances in the instance list
-v                                  - show parsed template prior to uploading
USAGE
}

parse_template() {
    if [[ ! $display_name || ! $dp_server || ! $dp_share || ! $user_rw || ! $user_ro || ! $pass_rw || ! $pass_ro ]]; then
        echo "ERROR: Incomplete credentials, cannot continue"
        exit 1
    fi

    parsed_template=$(/usr/bin/sed "s|%DISPLAY_NAME%|${display_name}|g" "$template_file" | /usr/bin/sed "s|%SERVER%|${dp_server}|g" | /usr/bin/sed "s|%HTTP_URL%|${http_url}|g" | /usr/bin/sed "s|%SHARE_NAME%|${dp_share}|g" | /usr/bin/sed "s|%READ_WRITE_USERNAME%|${user_rw}|g" | /usr/bin/sed "s|%READ_WRITE_PASSWORD%|${pass_rw}|g" | /usr/bin/sed "s|%READ_ONLY_USERNAME%|${user_ro}|g" | /usr/bin/sed "s|%READ_ONLY_PASSWORD%|${pass_ro}|g")
}

upload_data() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"

    # Check this DP actually exists
    # send request
    curl_url="$jss_url/JSSResource/distributionpoints"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//distribution_points/distribution_point[name = '$display_name']/id/text()" "$curl_output_file" 2>/dev/null)

    # send request
    curl_args=("--header")
    curl_args+=("Content-Type: application/xml")
    curl_args+=("--data")
    curl_args+=("$parsed_template")
    if [[ $existing_id ]]; then
        echo "   [upload_data] Existing DP (ID $existing_id) found"
        curl_url="$jss_url/JSSResource/distributionpoints/id/$existing_id"
        curl_args+=("--request")
        curl_args+=("PUT")
    else
        echo "   [upload_data] No existing DP found"
        curl_url="$jss_url/JSSResource/distributionpoints/id/0"
        curl_args+=("--request")
        curl_args+=("POST")
    fi
    send_curl_request
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
        -t|--template)
            shift
            template="$1"
        ;;
        -n|--name)
            shift
            display_name="$1"
        ;;
        -s|--smb-url)
            shift
            smb_url="$1"
        ;;
        -rw|--readwrite)
            shift
            user_rw="$1"
        ;;
        -ro|--readonly)
            shift
            user_ro="$1"
        ;;
        -il|--instance-list)
            shift
            instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        -a|--all)
            all_instances=1
        ;;
        -v|--verbose)
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

# Set default instance list
default_instance_list="prd"

# get template
choose_template_file

# select the instances that will be changed
choose_destination_instances

# set Display Name
if [[ ! $display_name ]]; then
    echo "Enter Fileshare Distribution Point Server Display Name"
    echo "(or press ENTER to use the same value as the SMB Share Name)"
    read -r -p "Display Name : " display_name
fi

# set URL
if [[ ! $smb_url ]]; then
    read -r -p "Enter Fileshare Distribution Point Server Name with share : " smb_url
fi
if [[ ! $smb_url ]]; then
    echo "No DP supplied, cannot continue"
    exit 1
fi
# get server and share name from url
share_url=$(sed 's|smb:\/\/||' <<< "$smb_url")
dp_server=$(cut -d"/" -f1 <<< "$share_url")
dp_share=$(cut -d"/" -f2 <<< "$share_url")

# set display_name if not supplied earlier
if [[ ! $display_name ]]; then
    display_name="$dp_share"
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
kc_check=$(security find-generic-password -s "$display_name" -l "$share_url (readwrite)" -a "$user_rw" -g 2>/dev/null)

if [[ $kc_check ]]; then
    echo "Keychain entry for $user_rw found for $display_name"
else
    echo "Keychain entry for $user_rw not found for $display_name"
fi

echo
# check for existing password entry in login keychain
pass_rw=$(security find-generic-password -s "$display_name" -l "$share_url (readwrite)" -a "$user_rw" -w -g 2>/dev/null)

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
security add-generic-password -U -s "$display_name" -l "$share_url (readwrite)" -a "$user_rw" -w "$pass_rw"

# set read-only username
if [[ ! $user_ro ]]; then
    echo
    read -r -p "Enter Read-Only Username : " user_ro
    if [[ ! $user_ro ]]; then
        echo "ERROR: No Read-Only Username supplied, cannot continue"
        exit 1
    fi
fi

# check for existing service entry in login keychain
kc_check=$(security find-generic-password -s "$display_name" -l "$share_url (readonly)" -a "$user_ro" -g 2>/dev/null)

if [[ $kc_check ]]; then
    echo "Keychain entry for $user_ro found for $display_name"
else
    echo "Keychain entry for $user_ro not found for $display_name"
fi

echo
# check for existing password entry in login keychain
pass_ro=$(security find-generic-password -s "$display_name" -l "$share_url (readonly)" -a "$user_ro" -w -g 2>/dev/null)

if [[ $pass_ro ]]; then
    echo "Password for $user_ro found for $display_name"
else
    echo "Password for $user_ro not found for $display_name"
fi

# set read-only password
echo "Enter password for $user_ro on $display_name"
[[ $pass_rw ]] && echo "(or press ENTER to use existing password from keychain for $user_ro)"
read -r -s -p "Pass : " inputted_pass_ro
echo
if [[ "$inputted_pass_ro" ]]; then
    pass_ro="$inputted_pass_ro"
elif [[ ! $pass_ro ]]; then
    echo "No password supplied"
    exit 1
fi

security add-generic-password -U -s "$display_name" -l "$share_url (readonly)" -a "$user_ro" -w "$pass_rw"

echo "Passwords added to Keychain"

# now update the JSS
echo
read -r -p "WARNING! This will update the File Share Distribution Point on ALL chosen instances! Are you sure? (Y/N) : " are_you_sure
case "$are_you_sure" in
    Y|y)
        echo "Confirmed"
    ;;
    *)
        echo "Cancelled"
        exit
    ;;
esac

http_url="https://$share_url"

# parse the template
parse_template

# show output if verbose mode set
if [[ $verbose == 1 ]]; then
    echo "$parsed_template"
fi

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Setting the FileShare DP on $jss_instance..."
    upload_data
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Setting the FileShare DP on $jss_instance..."
        upload_data
    done
fi

echo 
echo "Finished"
echo
