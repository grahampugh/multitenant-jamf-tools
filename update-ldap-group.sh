#!/bin/bash

: <<'DOC'
Script for creating or updating an LDAP group on all instances.
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
--ldap-group GROUPNAME              - provide the LDAP/AD group that should be updated
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
    parsed_template=$(sed "s|%LDAP_GROUP_NAME%|${ldap_group_name}|g" "$template")
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

    # Check this LDAP group actually exists
    # send request
    curl_url="$jss_url/JSSResource/accounts"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//groups/group[name = '$ldap_group_name']/id/text()" "$curl_output_file" 2>/dev/null)

    # send request
    curl_args=("--header")
    curl_args+=("Content-Type: application/xml")
    curl_args+=("--data")
    curl_args+=("$parsed_template")
    if [[ $existing_id ]]; then
        echo "   [upload_data] Existing LDAP group '$ldap_group_name' found on '$jss_url' (ID $existing_id). Updating..."
        curl_url="$jss_url/JSSResource/accounts/groupid/$existing_id"
        curl_args+=("--request")
        curl_args+=("PUT")
    else
        echo "   [upload_data] LDAP group '$ldap_group_name' not found on '$jss_url'. Creating..."
        curl_url="$jss_url/JSSResource/accounts/groupid/0"
        curl_args+=("--request")
        curl_args+=("POST")
    fi
    send_curl_request

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*update-ldap-group.sh*\nUser: $jss_api_user\nInstance: $jss_url\nCreate/Update LDAP Groups $ldap_group_name'}"
    send_slack_notification "$slack_text"
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
        -g|--ldap-group)
            shift
            chosen_group="$1"
        ;;
        -t|--template)
            shift
            template="$1"
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
default_instance_list_file="instance-lists/default-instance-list.txt"
[[ -f "$default_instance_list_file" ]] && default_instance_list=$(cat "$default_instance_list_file") || default_instance_list="prd"


# get template
choose_template_file

# select the instances that will be changed
choose_destination_instances

# set ldap_server
if [[ ! $ldap_server ]]; then
    read -r "Enter LDAP Server Name : " ldap_server
fi

# set ldap group
if [[ ! $chosen_group ]]; then
    read -r "Enter LDAP Group : " chosen_group
fi

echo

# get specific instance if entered
item=0
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    echo "   [main] Updating the LDAP group on $jss_instance..."

    # grab the appropriate admin group for this instance
    ldap_group_name="${admingroups_list[$item]}"

    # restrict to the chosen instance if present, otherwise do all instances
    if [[ $chosen_instance ]]; then
        if [[ "$instance" == "$chosen_instance" ]]; then
            # overwrite the chosen group if supplied at the command line
            if [[ "$chosen_group" ]]; then
                ldap_group_name="$chosen_group"
            fi

            # skip if set to "None"
            if [[ ! $ldap_group_name || $ldap_group_name == "None" ]]; then
                echo "   [main] $instance has no LDAP group assigned, skipping..." 
            else
                upload_data
            fi
        fi
    else
        # skip if set to "None"
        if [[ ! $ldap_group_name || $ldap_group_name == "None" ]]; then
            echo "   [main] $instance has no LDAP group assigned, skipping..." 
            else
                upload_data
            fi
    fi
    ((item++))
done

echo 
echo "Finished"
echo
