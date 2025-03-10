#!/bin/bash

: <<'DOC'
Script for setting the LDAP server on all instances.
Requires a template XML file
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh                - set the Keychain credentials

[no arguments]                      - interactive mode
--ldap-server EXAMPLE.COM           - provide the LDAP/AD server
--ldap-account ACCOUNT              - provide an LDAP/AD account that has domain-join privileges
--template /path/to/Template.xml    - template to use (must be a .xml file)
--il FILENAME (without .txt)        - provide an instance list filename
                                        (must exist in the instance-lists folder)
--i JSS_URL                         - perform action on a single instance
                                        (must exist in the relevant instance list)
--all                               - perform action on ALL instances in the instance list
-v                                  - add verbose curl output
USAGE
}

parse_template() {
    parsed_template=$(sed "s|%LDAP_ACCOUNT_PW%|${ldap_account_pw}|g" "$template")
}

upload_data() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"

    # Check this LDAP server actually exists
    # send request
    curl_url="$jss_url/JSSResource/ldapservers"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//ldap_servers/ldap_server[name = '$ldap_server']/id/text()" "$curl_output_file" 2>/dev/null)

    # send request
    curl_args=("--header")
    curl_args+=("Content-Type: application/xml")
    curl_args+=("--data")
    curl_args+=("$parsed_template")
    if [[ $existing_id ]]; then
        echo "   [upload_data] Existing LDAP server (ID $existing_id) found"
        curl_url="$jss_url/JSSResource/ldapservers/id/$existing_id"
        curl_args+=("--request")
        curl_args+=("PUT")
    else
        echo "   [upload_data] No existing LDAP server found"
        curl_url="$jss_url/JSSResource/ldapservers/id/0"
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
        -s|--ldap-server)
            shift
            ldap_server="$1"
        ;;
        -u|--ldap-account)
            shift
            ldap_join_account="$1"
        ;;
        -t|--template)
            shift
            template="$1"
        ;;
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
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

# get template
choose_template_file

# select the instances that will be changed
choose_destination_instances

# set ldap_server
if [[ ! $ldap_server ]]; then
    read -r "Enter LDAP Server Name : " ldap_server
fi

# set read-only password
if [[ ! $ldap_account_pw ]]; then
    printf '%s ' "Enter the password of the account $ldap_join_account : "
    read -r -s ldap_account_pw
    echo
fi
if [[ ! $ldap_account_pw ]]; then
    echo "ERROR: no password supplied"
    exit 1
fi

# parse the template
parse_template

# show output if verbose mode set
if [[ $verbose == 1 ]]; then
    echo "$parsed_template"
fi

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Setting the LDAP server on $jss_instance..."
    upload_data
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Setting the LDAP server on $jss_instance..."
        upload_data
    done
fi

echo 
echo "Finished"
echo
