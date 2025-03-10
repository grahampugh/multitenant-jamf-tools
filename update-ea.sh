#!/bin/bash

: <<'DOC'
Script for updating the value of an extension attribute on computers
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
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
--name EA-NAME                - provide extension attribute name
--value EA-VALUE              - provide extension attribute name
--group                       - Predefine devices to those in a specified group
--id                          - Predefine an ID (from Jamf) to search for
--serial                      - Predefine a computer's Serial Number to search for. 
                                Can be a CSV list,
                                e.g. ABCD123456,ABDE234567,XWSA123456
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--all                         - perform action on ALL instances in the instance list
-v                            - add verbose curl output
USAGE
}

are_you_sure() {
    if [[ $confirmed != "yes" ]]; then
        echo
        read -r -p "Are you sure you want to update the EA values on $jss_instance? (Y/N) : " sure
        case "$sure" in
            Y|y)
                return
                ;;
            *)
                echo "   [are_you_sure] Action cancelled, quitting"
                exit
                ;;
        esac
    fi
}

update_ea() {
    # This function will set the desired EA value on the selected devices

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [redeploy_framework] Processing Computer: id: $computer_id  name: $computer_name"
        echo

        # set EA value
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="/api/v1/computers-inventory-detail"
        curl_url="$jss_url/$endpoint/$computer_id"
        curl_args=("--request")
        curl_args+=("PATCH")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
              "extensionAttributes": [
                {
                  "definitionId": "'"$existing_id"'",
                  "values": [
                    "'"$ea_value"'"
                  ]
                }
              ]
            }'
        )
        send_curl_request
        echo
        # cat "$curl_output_file" # TEMP
        echo
        # Send Slack notification
        slack_text="{'username': '$jss_url', 'text': '*update_ea.sh*\nUser: $jss_api_user\nInstance: $jss_url\nComputer: $computer_name\nAction: Update EA \'$ea_name\' to \'$ea_value\''}"
        send_slack_notification "$slack_text"
    done

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
        --ea)
            shift
            ea_name="$1"
        ;;
        --value)
            shift
            ea_value="$1"
            if [[ ! $ea_value ]]; then
                ea_value="BLANK"
            fi
        ;;
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        -id|--id)
            shift
            id="$1"
            ;;
        -s|--serial)
            shift
            serial="$1"
            ;;
        -g|--group)
            shift
            group_name="$1"
            encode_name "$group_name"
            ;;
        --computers)
            device_type="computers"
            ;;
        --devices)
            device_type="devices"
            ;;
        --confirm)
            echo "   [main] CLI: Action: auto-confirm copy or delete, for non-interactive use."
            confirmed="yes"
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

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
else
    jss_instance="${instance_choice_array[0]}"
fi

# set EA name
if [[ ! $ea_name ]]; then
    read -r -p "Enter the Extension Attribute name you wish to set : " ea_name
    echo
fi
if [[ ! $ea_name ]]; then
    echo "ERROR: no EA name supplied"
fi

# verify this EA exists
api_xml_object="computer_extension_attribute"
object_name="$ea_name"
get_object_id_from_name

if [[ ! $existing_id ]]; then
    echo "ERROR: invalid EA supplied"
    exit 1
fi

# set EA value
if [[ ! $ea_value ]]; then
    read -r -p "Enter the value of the '$ea_name' EA you wish to set : " ea_value
    echo
fi
if [[ ! $ea_value || $ea_value = "BLANK" ]]; then
    echo "No value supplied - setting as blank string"
    ea_value=""
fi



# if a group name was supplied at the command line, compile the list of computers/mobile devices from that group
# get specific instance if entered
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"

    if [[ $group_name ]]; then
        echo
        get_computers_in_group
    fi

    # we need to find out the computer/mobile device id, 
    generate_computer_list


    # are we sure to proceed?
    are_you_sure

    echo "Updating EA '$ea_name' on $jss_instance to '$ea_value'..."
    update_ea
done

echo 
echo "Finished"
echo
