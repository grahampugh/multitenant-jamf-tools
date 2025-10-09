#!/bin/bash

# --------------------------------------------------------------------------------
# Script for creating or updating an LDAP group on all instances.
# Requires a template XML file
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="ios"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
NOTE: LDAP server is obtained automatically from the instance (must be configured already)

./set_credentials.sh                - set the Keychain credentials

[no arguments]                      - interactive mode
--template /path/to/Template.xml    - template to use (must be a .xml file)
--ldap-server EXAMPLE.COM           - provide the LDAP server
--user LDAP_USER                    - set username
--il FILENAME (without .txt)        - provide an instance list filename
                                        (must exist in the instance-lists folder)
--i JSS_URL                         - perform action on a single instance
                                        (must exist in the relevant instance list)
--all                               - perform action on ALL instances in the instance list
-v                                  - add verbose curl output
USAGE
}

parse_template() {
    parsed_template=$(sed "s|%LDAP_USER_NAME%|${chosen_user}|g" "$template_file")
    parsed_template="${parsed_template/\%LDAP_SERVER\%/$ldap_server}"
    parsed_template="${parsed_template/\%LDAP_SERVER_ID\%/$ldap_server_id}"
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
    ldap_server_id=$(xmllint --xpath "//ldap_servers/ldap_server[name = '$ldap_server']/id/text()" "$curl_output_file" 2>/dev/null)

    if [[ ! $ldap_server_id ]]; then
        echo "   [upload_data] No existing LDAP server found. Please run set-ldap-server.sh before using this script on this instance"
        return
    fi

    # if we got this far it is ok to write the account

    # parse the template
    parse_template

    # show output if verbose mode set
    if [[ $verbose == 1 ]]; then
        echo "$parsed_template"
    fi

    # Check this LDAP user actually exists
    # send request
    curl_url="$jss_url/JSSResource/accounts"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//users/user[name = '$chosen_user']/id/text()" "$curl_output_file" 2>/dev/null)

    # send request
    curl_args=("--header")
    curl_args+=("Content-Type: application/xml")
    curl_args+=("--data")
    curl_args+=("$parsed_template")
    if [[ $existing_id ]]; then
        echo "   [upload_data] Existing LDAP user '$chosen_user' found on '$jss_url' (ID $existing_id). Updating..."
        curl_url="$jss_url/JSSResource/accounts/userid/$existing_id"
        curl_args+=("--request")
        curl_args+=("PUT")
    else
        echo "   [upload_data] LDAP user '$chosen_user' not found on '$jss_url'. Creating..."
        curl_url="$jss_url/JSSResource/accounts/userid/0"
        curl_args+=("--request")
        curl_args+=("POST")
    fi
    send_curl_request

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*create-ldap-user.sh*\nUser: $jss_api_user\nInstance: $jss_url\nCreate/Update User $chosen_user'}"
    send_slack_notification "$slack_text"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
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
        -x|--nointeraction)
            no_interaction=1
            ;;
        -u|--user)
            shift
            chosen_user="$1"
        ;;
        -s|--ldap-server)
            shift
            ldap_server="$1"
        ;;
        -t|--template)
            shift
            template="$1"
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

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# set ldap_server
if [[ ! $ldap_server ]]; then
    read -r "Enter LDAP Server Name : " ldap_server
fi

# set ldap user
if [[ ! $chosen_user ]]; then
    read -r "Enter LDAP User : " chosen_user
fi

# get specific instance if entered
item=0
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    echo "   [main] Updating the LDAP user(s) on $jss_instance..."

    # restrict to the chosen instance if present, otherwise do all instances
    if [[ $chosen_instance ]]; then
        if [[ "$instance" == "$chosen_instance" ]]; then
            # skip if set to "None"
            if [[ ! $chosen_user || $chosen_user == "None" ]]; then
                echo "   [main] $instance has no LDAP user assigned, skipping..." 
            else
                upload_data
            fi
        fi
    else
        # skip if set to "None"
        if [[ ! $chosen_user || $chosen_user == "None" ]]; then
            echo "   [main] $instance has no LDAP user assigned, skipping..." 
            else
                upload_data
            fi
    fi
    ((item++))
done

echo 
echo "Finished"
echo
