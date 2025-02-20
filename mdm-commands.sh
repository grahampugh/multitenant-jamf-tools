#!/bin/bash

: <<DOC
Script for running various MDM commands

Actions:
- Checks if we already have a token
- Grabs a new token if required using basic auth
- Works out the Jamf Pro version, quits if less than 10.36
- Posts the MDM command request
DOC

# source the _common-framework.sh file
# shellcheck source-path=SCRIPTDIR source=_common-framework.sh
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# --------------------------------------------------------------------
# Functions
# --------------------------------------------------------------------

redeploy_framework() {
    # This function will redeploy the Management Framework to the selected devices

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [redeploy_framework] Processing Computer: id: $computer_id  name: $computer_name"
        echo

        # redeploy Management Framework
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="api/v1/jamf-management-framework/redeploy"
        curl_url="$jss_url/$endpoint/$computer_id"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Redeploy Framework'}"
    send_slack_notification "$slack_text"
}

get_software_update_feature_status() {
    # grab current value
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/v1/managed-software-updates/plans/feature-toggle"
    curl_url="$jss_url/$endpoint"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    toggle_value=$(/usr/bin/plutil -extract toggle raw "$curl_output_file" 2>/dev/null)
    toggle_set_value="true"
    if [[ $toggle_value == "true" ]]; then 
        toggle_set_value="false"
    fi

    echo "   [toggle_software_update_feature] Current toggle value is '$toggle_value'. "

    # grab current background status
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/v1/managed-software-updates/plans/feature-toggle/status"
    curl_url="$jss_url/$endpoint"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    toggle_on_value=$(/usr/bin/plutil -extract toggleOn.formattedPercentComplete raw "$curl_output_file" 2>/dev/null)
    toggle_off_value=$(/usr/bin/plutil -extract toggleOff.formattedPercentComplete raw "$curl_output_file" 2>/dev/null)

    echo "   [toggle_software_update_feature] Toggle on status: '$toggle_on_value'..."
    echo "   [toggle_software_update_feature] Toggle off status: '$toggle_off_value'..."
    echo "   [toggle_software_update_feature] WARNING: Do not proceed if either of the above values is less than 100%"
    echo "   [toggle_software_update_feature] Proceed to toggle to '$toggle_set_value'..."
}

toggle_software_update_feature() {
    # This function will toggle the "new" software update feature allowing to clear any plans

    echo
    echo "   [toggle_software_update_feature] Toggling software update command on $jss_instance"
    echo "   [toggle_software_update_feature] This endpoint is asynchronous, the provided value will not be immediately updated."
    echo

    # toggle software update feature
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/v1/managed-software-updates/plans/feature-toggle"
    curl_url="$jss_url/$endpoint"
    curl_args=("--request")
    curl_args+=("PUT")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--data-raw")
    curl_args+=("{\"toggle\": $toggle_set_value}")
    send_curl_request

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Toggle Software Update Plan Feature to $toggle_set_value'}"
    send_slack_notification "$slack_text"
}

delete_users() {
    # This function will delete all users from a device
    # ask if users should be forced
    if [[ ! "$force_deletion" ]]; then
        echo "The following applies to all selected devices:"
        read -r -p "Select [F] to force user deletion, or anything else to not force deletion : " action_question
        case "$action_question" in
            F|f)
                force_deletion="true"
                ;;
            *)
                force_deletion="false"
                ;;
        esac
        echo
    fi

    # now loop through the list and perform the action
    for mobile_device in "${mobile_device_choice[@]}"; do
        management_id="${management_ids[$mobile_device]}"
        mobile_device_id="${mobile_device_ids[$mobile_device]}"
        mobile_device_name="${mobile_device_names[$mobile_device]}"
        echo
        echo "   [redeploy_framework] Processing Device: id: $mobile_device_id  name: $mobile_device_name"
        echo

        # redeploy Management Framework
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="api/v2/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'"
                    }
                ],
                "commandData": {
                    "commandType": "DELETE_USER",
                    "deleteAllUsers": true,
                    "forceDeletion": '"$force_deletion"'
              }
            }'
        )
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Delete Users'}"
    send_slack_notification "$slack_text"
}

logout_users() {
    # This function will logout the user from a device

    # now loop through the list and perform the action
    for mobile_device in "${mobile_device_choice[@]}"; do
        management_id="${management_ids[$mobile_device]}"
        mobile_device_id="${mobile_device_ids[$mobile_device]}"
        mobile_device_name="${mobile_device_names[$mobile_device]}"
        echo
        echo "   [redeploy_framework] Processing Device: id: $mobile_device_id  name: $mobile_device_name"
        echo

        # redeploy Management Framework
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="api/v2/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'"
                    }
                ],
                "commandData": {
                    "commandType": "LOG_OUT_USER"
              }
            }'
        )
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Logout Users'}"
    send_slack_notification "$slack_text"
}

send_settings_command() {
    # This function will send a settings command
    # currently limited to `bluetooth`
    setting="$1"
    value="$2"

    # now loop through the list and perform the action
    for mobile_device in "${mobile_device_choice[@]}"; do
        management_id="${management_ids[$mobile_device]}"
        mobile_device_id="${mobile_device_ids[$mobile_device]}"
        mobile_device_name="${mobile_device_names[$mobile_device]}"
        echo
        echo "   [redeploy_framework] Processing Device: id: $mobile_device_id  name: $mobile_device_name"
        echo

        # redeploy Management Framework
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="api/v2/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'"
                    }
                ],
                "commandData": {
                    "commandType": "SETTINGS",
                    "'"$setting"'": '"$value"'
              }
            }'
        )
        echo "${curl_args[*]}" # TEMP
        send_curl_request
        cat "$curl_output_file" # TEMP
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Send Setting: $setting: $value'}"
    send_slack_notification "$slack_text"
}


restart() {
    # This function will restart a device

    # now loop through the list and perform the action
    for mobile_device in "${mobile_device_choice[@]}"; do
        management_id="${management_ids[$mobile_device]}"
        mobile_device_id="${mobile_device_ids[$mobile_device]}"
        mobile_device_name="${mobile_device_names[$mobile_device]}"
        echo
        echo "   [redeploy_framework] Processing Device: id: $mobile_device_id  name: $mobile_device_name"
        echo

        # redeploy Management Framework
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="api/v2/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'"
                    }
                ],
                "commandData": {
                    "commandType": "RESTART_DEVICE",
                    "notifyUser": false
              }
            }'
        )
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Restart Devices'}"
    send_slack_notification "$slack_text"
}

eacas() {
    # This function will erase the selected devices

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        management_id="${management_ids[$computer]}"
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [eacas] Processing Computer: id: $computer_id  name: $computer_name  management id: $management_id"
        echo

        # send MDM command
        endpoint="api/v2/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'"
                    }
                ],
                "commandData": {
                    "commandType": "ERASE_DEVICE",
                    "pin": "000000",
                    "obliterationBehavior": "DoNotObliterate"
                }
            }'
        )
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Remote Wipe'}"
    send_slack_notification "$slack_text"
}

set_recovery_lock() {
    # This function will set or clear the recovery lock to the selected devices

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        management_id="${management_ids[$computer]}"
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [set_recovery_lock] Computer chosen: id: $computer_id  name: $computer_name  management id: $management_id"

        echo
        # get a random password ready
        uuid_string=$(/usr/bin/uuidgen)
        uuid_no_dashes="${uuid_string//-/}"
        random_b64=$(/usr/bin/base64 <<< "$uuid_no_dashes")
        random_alpha_only="${random_b64//[^[:alnum:]]}"
        random_20="${random_alpha_only:0:20}"

        # we need to set the recovery lock password if not already set
        if [[ "$cli_recovery_lock_password" == "RANDOM" ]]; then
            recovery_lock_password="$random_20"
        elif [[ "$cli_recovery_lock_password" == "NA" ]]; then
            recovery_lock_password="NA"
        elif [[ $cli_recovery_lock_password ]]; then
            recovery_lock_password="$cli_recovery_lock_password"
        else
            # random or set a specific password?
            echo "The following applies to all selected devices:"
            read -r -p "Select [R] for random password, [C] to clear the current password, or enter a specific password : " action_question
            case "$action_question" in
                C|c)
                    cli_recovery_lock_password="NA"
                    recovery_lock_password=""
                    ;;
                R|r)
                    cli_recovery_lock_password="RANDOM"
                    recovery_lock_password="$random_20"
                    ;;
                *)
                    cli_recovery_lock_password="$action_question"
                    recovery_lock_password="$action_question"
                    ;;
            esac
            echo
        fi

        if [[ ! $recovery_lock_password || "$recovery_lock_password" == "NA" ]]; then
            echo "   [set_recovery_lock] Recovery lock will be removed..."
        else
            echo "   [set_recovery_lock] Recovery password: $recovery_lock_password"
        fi

        # now issue the recovery lock
        endpoint="api/v2/mdm/commands"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("POST")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--data-raw")
        curl_args+=(
            '{
                "clientData": [
                    {
                        "managementId": "'"$management_id"'",
                        "clientType": "COMPUTER"
                    }
                ],
                "commandData": {
                    "commandType": "SET_RECOVERY_LOCK",
                    "newPassword": "'"$recovery_lock_password"'"
                }
            }'
        )
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Set Recovery Lock'}"
    send_slack_notification "$slack_text"
}

remove_mdm() {
    # This function will remove the MDM profile from the selected devices

    # now loop through the list and perform the action
    for mobile_device in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [remove_mdm] Processing Computer: id: $computer_id  name: $computer_name"
        echo

        # Unmanage device
        set_credentials "$jss_instance"
        jss_url="$jss_instance"
        endpoint="JSSResource/computercommands/command/UnmanageDevice/id"
        curl_url="$jss_url/$endpoint/$computer_id"
        curl_args=("--request")
        curl_args+=("POST")
        send_curl_request
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Remove MDM Profile'}"
    send_slack_notification "$slack_text"
}

flush_mdm() {
    # This function will flush the MDM commands from the selected devices

    # specify device type
    if [[ $device_type != "devices" ]]; then
        device_type="computers"
    fi

    # specify flush option
    if [[ ! $status_option ]]; then
        status_option="Pending%2BFailed"
    fi

    if [[ $group_name ]]; then
        # get the ID of the group
        object_name="$group_name"
        if [[ $device_type == "computers" ]]; then
            api_xml_object="computer_group"
        else
            api_xml_object="mobile_device_group"
        fi
        get_object_id_from_name

        if [[ $existing_id ]]; then
            echo
            echo "   [remove_mdm] Processing Group: $group_name"
            echo

            # perform MDM flush command - endpoint uses api object type (computergroups/mobiledevicegroups)
            set_credentials "$jss_instance"
            jss_url="$jss_instance"
            endpoint="JSSResource/commandflush"
            curl_url="$jss_url/$endpoint/$api_object_type/id/$existing_id/status/$status_option"
            curl_args=("--request")
            curl_args+=("DELETE")
            send_curl_request
        else
            echo "No group with name '$group_name' found."
            exit
        fi
    else
        if [[ $device_type == "computers" ]]; then
            # now loop through the list and perform the action
            for computer in "${computer_choice[@]}"; do
                computer_id="${computer_ids[$computer]}"
                computer_name="${computer_names[$computer]}"
                echo
                echo "   [remove_mdm] Processing Computer: id: $computer_id  name: $computer_name"
                echo

                # perform MDM flush command
                set_credentials "$jss_instance"
                jss_url="$jss_instance"
                endpoint="JSSResource/commandflush"
                curl_url="$jss_url/$endpoint/$device_type/id/$computer_id/status/$status_option"
                curl_args=("--request")
                curl_args+=("DELETE")
                send_curl_request
            done
        else
            # now loop through the list and perform the action
            for mobile_device in "${mobile_device_choice[@]}"; do
                mobile_device_id="${mobile_device_ids[$mobile_device]}"
                mobile_device_name="${mobile_device_names[$mobile_device]}"
                echo
                echo "   [remove_mdm] Processing Mobile Device: id: $mobile_device_id  name: $mobile_device_name"
                echo

                # perform MDM flush command
                set_credentials "$jss_instance"
                jss_url="$jss_instance"
                endpoint="JSSResource/commandflush"
                curl_url="$jss_url/$endpoint/$device_type/id/$mobile_device_id/status/$status_option"
                curl_args=("--request")
                curl_args+=("DELETE")
                send_curl_request
            done
        fi
    fi

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Flush MDM Commands'}"
    send_slack_notification "$slack_text"
}

usage() {
    echo "
./mdm-commands.sh options

./set_credentials.sh            - set the Keychain credentials

[no arguments]                  - interactive mode
-il FILENAME (without .txt)     - provide an instance list filename
                                  (must exist in the instance-lists folder)
-i JSS_URL                      - perform action on a single instance
                                  (must exist in the relevant instance list)
-v                              - add verbose curl output

MDM command type:

--erase                         - Erase the device
--redeploy                      - Redeploy the Management Framework
--recovery                      - Set the recovery lock password
                                  Recovery lock password will be random unless set
                                  with --recovery-lock-password
--removemdm                     - Remove the MDM Enrollment Profile (Unmanage)
--deleteusers                   - Delete all users from a device (Shared iPad)
--restart                       - Restart device (mobile devices only)
--logout                        - Log out user from a device (mobile devices only)
--flushmdm                     - Flush MDM commands
--bluetooth-off                 - Disable Bluetooth (mobile devices only)
--bluetooth-on                  - Enable Bluetooth (mobile devices only)

Options for the --recovery type:

--random-lock-password          - Create a random recovery lock password (this is the default)
--recovery-lock-password        - Define a recovery lock password
--clear-recovery-lock-password  - Clear the recovery lock password

Options for the --deleteusers type:
--force                         - Force user deletion
--noforce                       - Do not force deletion
--group                         - Predefine devices to those in a specified group

Options for the --restart and --logout types:
--group                         - Predefine devices to those in a specified group

Options for the --flushmdm type:
--pending                       - Flush pending commands only (default is pending+failed)
--failed                        - Flush failed commands only (default is pending+failed)
--computers                     - Device type is computers (default)
--devices                       - Devices type is devices (default is computers)
--group                         - Flush commands based on a group rather than individual computers or devices

Define the target clients:

--id                            - Predefine an ID (from Jamf) to search for
--serial                        - Predefine a computer's Serial Number to search for. 
                                  Can be a CSV list,
                                  e.g. ABCD123456,ABDE234567,XWSA123456

You can clear the recovery lock password with --clear-recovery-lock-password
"
}

are_you_sure() {
    echo
    read -r -p "Are you sure you want to perform the action? (Y/N) : " sure
    case "$sure" in
        Y|y)
            return
            ;;
        *)
            echo "   [are_you_sure] Action cancelled, quitting"
            exit 
            ;;
    esac
}


# --------------------------------------------------------------------
# Main Body
# --------------------------------------------------------------------

mdm_command=""
recovery_lock_password=""

# read inputs
while test $# -gt 0 ; do
    case "$1" in
        -sl|--server-list)
            shift
            server_list="$1"
        ;;
        -si|--instance)
            shift
            chosen_instance="$1"
        ;;
        -i|--id)
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
        --erase|--eacas)
            mdm_command="eacas"
            ;;
        --logout|--logout-user)
            mdm_command="logout"
            ;;
        --deleteusers|--delete-users)
            mdm_command="deleteusers"
            ;;
        --restart)
            mdm_command="restart"
            ;;
        --bluetooth-off)
            mdm_command="bluetooth-off"
            ;;
        --bluetooth-on)
            mdm_command="bluetooth-on"
            ;;
        --redeploy|--redeploy-framework)
            mdm_command="redeploy"
            ;;
        --recovery|--recovery-lock)
            mdm_command="recovery"
            ;;
        --removemdm|--remove-mdm-profile)
            mdm_command="remove_mdm"
            ;;
        --flushmdm|--flush-mdm)
            mdm_command="flushmdm"
            ;;
        --toggle)
            mdm_command="toggle"
            ;;
        --recovery-lock-password)
            shift
            cli_recovery_lock_password="$1"
            ;;
        --random|--random-lock-password)
            cli_recovery_lock_password="RANDOM"
            ;;
        --clear-recovery-lock-password)
            cli_recovery_lock_password="NA"
            ;;
        --force)
            force_deletion="true"
            ;;
        --noforce)
            force_deletion="false"
            ;;
        --computers)
            device_type="computers"
            ;;
        --devices)
            device_type="devices"
            ;;
        --pending)
            status_option="Pending"
            ;;
        --failed)
            status_option="Failed"
            ;;
        -v|--verbose)
            verbose=1
        ;;
        *)
            usage
            exit
            ;;
    esac
    shift
done

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# Set default instance list
default_instance_list="prd"

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
else
    jss_instance="${instance_choice_array[0]}"
fi

if [[ $mdm_command ]]; then
    echo "MDM command preselected: $mdm_command"
else
    echo
    echo "Select from the following suported MDM commands:"
    echo "   [E] Erase All Content And Settings"
    echo "   [M] Redeploy Management Framework"
    echo "   [R] Set Recovery Lock"
    echo "   [P] Remove MDM Enrollment Profile"
    echo "   [D] Delete all users (Shared iPads)"
    echo "   [S] Restart device (mobile devices)"
    echo "   [L] Logout user (mobile devices)"
    echo "   [B0] [B1] Disable/Enable Bluetooth (mobile devices)"
    echo "   [F] Flush MDM commands"
    echo "   [T] Toggle Software Update Plan Feature"
    printf 'Choose one : '
    read -r action_question

    case "$action_question" in
        E|e)
            mdm_command="eacas"
            ;;
        R|r)
            mdm_command="recovery"
            ;;
        M|m)
            mdm_command="redeploy"
            ;;
        P|p)
            mdm_command="removemdm"
            ;;
        D|d)
            mdm_command="deleteusers"
            ;;
        B0|b0)
            mdm_command="bluetooth-off"
            ;;
        B1|b1)
            mdm_command="bluetooth-on"
            ;;
        S|s)
            mdm_command="restart"
            ;;
        L|l)
            mdm_command="logout"
            ;;
        F|f)
            mdm_command="flushmdm"
            ;;
        T|t)
            mdm_command="toggle"
            ;;
        *)
            echo
            echo "No valid action chosen!"
            exit 1
            ;;
    esac
fi

# if a group name was supplied at the command line, compile the list of computers/mobile devices from that group
if [[ $group_name && $mdm_command != "flushmdm" && $mdm_command != "toggle" ]]; then
    echo
    if [[ $mdm_command == "deleteusers" || $mdm_command == "restart" || $mdm_command == "logout" ]]; then
        get_mobile_devices_in_group
    else
        get_computers_in_group
    fi
fi

# to send MDM commands, we need to find out the computer/mobile device id, 
# but not for the flush_dns command if we're giving a group name
if [[ ($mdm_command == "flushmdm" && ! $group_name) || $mdm_command != "flushmdm" ]]; then
    if [[ $mdm_command == "deleteusers" || $mdm_command == "restart" || $mdm_command == "logout" || $mdm_command == "bluetooth"* || ($mdm_command == "flushmdm" && $device_type == "devices") ]]; then
        generate_mobile_device_list
    elif [[ $mdm_command != "toggle" ]]; then
        generate_computer_list
    fi
elif [[ $mdm_command != "toggle" ]]; then
    echo "Using group: $group_name"
fi

# for toggling software update feature status we want to display the current value
if [[ $mdm_command == "toggle" ]]; then
    get_software_update_feature_status
fi

# are we sure to proceed?
are_you_sure


# the following section depends on the chosen MDM command
case "$mdm_command" in
    bluetooth-off)
        echo "   [main] Disabling Bluetooth on Device"
        send_settings_command "bluetooth" "false"
        ;;
    bluetooth-on)
        echo "   [main] Enabling Bluetooth on Device"
        send_settings_command "bluetooth" "true"
        ;;
    deleteusers)
        echo "   [main] Deleting All Users"
        delete_users
        ;;
    eacas)
        echo "   [main] Sending MDM erase command"
        eacas
        ;;
    flushmdm)
        echo "   [main] Flushing MDM Commands"
        flush_mdm
        ;;
    logout)
        echo "   [main] Logging Out User on Device(s)"
        logout_users
        ;;
    recovery)
        echo "   [main] Setting recovery lock"
        set_recovery_lock
        ;;
    redeploy)
        echo "   [main] Redeploying Management Framework"
        redeploy_framework
        ;;
    removemdm)
        echo "   [main] Removing MDM Enrollment Profile"
        remove_mdm
        ;;
    restart)
        echo "   [main] Restarting Device(s)"
        restart
        ;;
    toggle)
        echo "   [main] Toggling Software Update Plan Feature"
        toggle_software_update_feature
        ;;
esac
