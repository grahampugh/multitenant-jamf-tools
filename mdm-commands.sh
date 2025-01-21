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


encode_name() {
    group_name_encoded="$( echo "$1" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"
}


get_group_id_from_name() {
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    if [[ $device_type == "computers" ]]; then
        api_object_type="computergroups"
        api_xml_object="computer_group"
    else
        api_object_type="mobiledevicegroups"
        api_xml_object="mobile_device_group"
    fi

    api_xml_object_plural=$(get_plural_from_api_xml_object "$api_xml_object")

    # send request
    curl_url="$jss_url/JSSResource/${api_object_type}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get id from output
    existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = '$group_name']/id/text()" "$curl_output_file" 2>/dev/null)
}


get_computers_in_group() {
    set_credentials "$jss_instance"
    jss_url="$jss_instance"

    # send request to get each version
    curl_url="$jss_url/JSSResource/computergroups/name/${group_name_encoded}"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $http_response -eq 404 ]]; then
        echo "   [get_computers_in_group] Smart group '$group_name' does not exist on this server"
        computers_count=0
    else
        # now get all the computer IDs
        computers_count=$(/usr/bin/plutil -extract computer_group.computers raw "$curl_output_file" 2>/dev/null)
        if [[ $computers_count -gt 0 ]]; then
            echo "   [get_computers_in_group] Restricting list to members of the group '$group_name'"
            computer_names_in_group=()
            computer_ids_in_group=()
            i=0
            while [[ $i -lt $computers_count ]]; do
                computer_id_in_group=$(/usr/bin/plutil -extract computer_group.computers.$i.id raw "$curl_output_file" 2>/dev/null)
                computer_name_in_group=$(/usr/bin/plutil -extract computer_group.computers.$i.name raw "$curl_output_file" 2>/dev/null)
                # echo "$computer_name_in_group ($computer_id_in_group)"
                computer_names_in_group+=("$computer_name_in_group")
                computer_ids_in_group+=("$computer_id_in_group")
                ((i++))
            done
        else
            echo "   [get_computers_in_group] Group '$group_name' contains no computers, so showing all computers"
        fi

    fi
}


get_mobile_devices_in_group() {
    set_credentials "$jss_instance"
    jss_url="$jss_instance"

    # send request to get each version
    curl_url="$jss_url/JSSResource/mobiledevicegroups/name/${group_name_encoded}"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $http_response -eq 404 ]]; then
        echo "   [get_mobile_devices_in_group] Smart group '$group_name' does not exist on this server"
        mobile_device_count=0
    else
        # now get all the device IDs
        mobile_device_count=$(/usr/bin/plutil -extract mobile_device_group.mobile_devices raw "$curl_output_file" 2>/dev/null)
        if [[ $mobile_device_count -gt 0 ]]; then
            echo "   [get_mobile_devices_in_group] Restricting list to members of the group '$group_name'"
            mobile_device_names_in_group=()
            mobile_device_ids_in_group=()
            i=0
            while [[ $i -lt $mobile_device_count ]]; do
                mobile_device_id_in_group=$(/usr/bin/plutil -extract mobile_device_group.mobile_devices.$i.id raw "$curl_output_file" 2>/dev/null)
                mobile_device_name_in_group=$(/usr/bin/plutil -extract mobile_device_group.mobile_devices.$i.name raw "$curl_output_file" 2>/dev/null)
                # echo "$computer_name_in_group ($mobile_device_id_in_group)"
                mobile_device_names_in_group+=("$mobile_device_name_in_group")
                mobile_device_ids_in_group+=("$mobile_device_id_in_group")
                ((i++))
            done
        else
            echo "   [get_mobile_devices_in_group] Group '$group_name' contains no mobile_devices, so showing all mobile_devices"
        fi

    fi
}


generate_computer_list() {
    # The Jamf Pro API returns a list of all computers.
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/preview/computers"
    url_filter="?page=0&page-size=1000&sort=id"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how big should the loop be?
    loopsize=$(/usr/bin/plutil -extract results raw "$curl_output_file")

    # now loop through
    i=0
    computer_ids=()
    computer_names=()
    management_ids=()
    serials=()
    computer_choice=()
    echo
    while [[ $i -lt $loopsize ]]; do
        id_in_list=$(/usr/bin/plutil -extract results.$i.id raw "$curl_output_file")
        computer_name_in_list=$(/usr/bin/plutil -extract results.$i.name raw "$curl_output_file")
        management_id_in_list=$(/usr/bin/plutil -extract results.$i.managementId raw "$curl_output_file")
        serial_in_list=$(/usr/bin/plutil -extract results.$i.serialNumber raw "$curl_output_file")

        computer_ids+=("$id_in_list")
        computer_names+=("$computer_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            computer_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<< "$serial" | wc -l)
                serial_count=$(( count + 1 ))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$( cut -d, -f$j <<< "$serial" )
                    if [[ "$serial_in_list" == "$serial_in_csv" ]]; then
                        computer_choice+=("$i")
                    fi
                    ((j++))
                done
            else
                if [[ "$serial_in_list" == "$serial" ]]; then
                    computer_choice+=("$i")
                fi
            fi
        elif [[ ${#computer_ids_in_group[@]} -gt 0 ]]; then
            for idx in "${computer_ids_in_group[@]}"; do
                if [[ $idx == "$id_in_list" ]]; then
                    computer_choice+=("$i")
                    break
                fi
            done
        else
            printf '%-5s %-9s %-16s %s\n' "($i)" "[id=$id_in_list]" "$serial_in_list" "$computer_name_in_list"
        fi
        ((i++))
    done

    if [ ${#computer_choice[@]} -eq 0 ]; then
        echo
        read -r -p "Enter the ID(s) of the computer(s) above : " computer_input
        # computers chosen
        for computer in $computer_input; do
            computer_choice+=("$computer")
        done
    fi

    if [ ${#computer_choice[@]} -eq 0 ]; then
        echo "No ID or serial supplied"
        exit 1
    fi

    # show list of chosen computers
    echo 
    echo "Computers chosen:"
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        computer_serial="${serials[$computer]}"
        printf '%-7s %-16s %s\n' "[id=$computer_id]" "$computer_serial" "$computer_name"
    done
}

generate_mobile_device_list() {
    # The Jamf Pro API returns a list of all computers.
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/v2/mobile-devices"
    url_filter="?page=0&page-size=1000&sort=id"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how big should the loop be?
    loopsize=$(/usr/bin/plutil -extract results raw "$curl_output_file")

    # now loop through
    i=0
    mobile_device_ids=()
    mobile_device_names=()
    management_ids=()
    serials=()
    mobile_device_choice=()
    echo
    while [[ $i -lt $loopsize ]]; do
        id_in_list=$(/usr/bin/plutil -extract results.$i.id raw "$curl_output_file")
        mobile_device_name_in_list=$(/usr/bin/plutil -extract results.$i.name raw "$curl_output_file")
        management_id_in_list=$(/usr/bin/plutil -extract results.$i.managementId raw "$curl_output_file")
        serial_in_list=$(/usr/bin/plutil -extract results.$i.serialNumber raw "$curl_output_file")

        mobile_device_ids+=("$id_in_list")
        mobile_device_names+=("$mobile_device_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            mobile_device_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<< "$serial" | wc -l)
                serial_count=$(( count + 1 ))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$( cut -d, -f$j <<< "$serial" )
                    if [[ "$serial_in_list" == "$serial_in_csv" ]]; then
                        mobile_device_choice+=("$i")
                    fi
                    ((j++))
                done
            else
                if [[ "$serial_in_list" == "$serial" ]]; then
                    mobile_device_choice+=("$i")
                fi
            fi
        elif [[ ${#mobile_device_ids_in_group[@]} -gt 0 ]]; then
            for idx in "${mobile_device_ids_in_group[@]}"; do
                if [[ $idx == "$id_in_list" ]]; then
                    mobile_device_choice+=("$i")
                    break
                fi
            done
        else
            printf '%-5s %-9s %-16s %s\n' "($i)" "[id=$id_in_list]" "$serial_in_list" "$mobile_device_name_in_list"
        fi
        ((i++))
    done

    if [ ${#mobile_device_choice[@]} -eq 0 ]; then
        echo
        read -r -p "Enter the ID(s) of the mobile_device(s) above : " mobile_device_input
        # mobile_devices chosen
        for mobile_device in $mobile_device_input; do
            mobile_device_choice+=("$mobile_device")
        done
    fi

    if [ ${#mobile_device_choice[@]} -eq 0 ]; then
        echo "No ID or serial supplied"
        exit 1
    fi

    # show list of chosen mobile_devices
    echo 
    echo "mobile_devices chosen:"
    for mobile_device in "${mobile_device_choice[@]}"; do
        mobile_device_id="${mobile_device_ids[$mobile_device]}"
        mobile_device_name="${mobile_device_names[$mobile_device]}"
        mobile_device_serial="${serials[$mobile_device]}"
        printf '%-7s %-16s %s\n' "[id=$mobile_device_id]" "$mobile_device_serial" "$mobile_device_name"
    done
}

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
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Reploy Framework'}"
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
        get_group_id_from_name

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
        *)
            echo
            echo "No valid action chosen!"
            exit 1
            ;;
    esac
fi

# if a group name was supplied at the command line, compile the list of computers/mobile devices from that group
if [[ $group_name && $mdm_command != "flushmdm" ]]; then
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
    else
        generate_computer_list
    fi
else
    echo "Using group: $group_name"
fi


# are we sure to proceed?
are_you_sure


# the following section depends on the chosen MDM command
case "$mdm_command" in
    eacas)
        echo "   [main] Sending MDM erase command"
        eacas
        ;;
    redeploy)
        echo "   [main] Redeploying Management Framework"
        redeploy_framework
        ;;
    recovery)
        echo "   [main] Setting recovery lock"
        set_recovery_lock
        ;;
    removemdm)
        echo "   [main] Removing MDM Enrollment Profile"
        remove_mdm
        ;;
    deleteusers)
        echo "   [main] Deleting All Users"
        delete_users
        ;;
    restart)
        echo "   [main] Restarting Device(s)"
        restart
        ;;
    logout)
        echo "   [main] Logging Out User on Device(s)"
        logout_users
        ;;
    flushmdm)
        echo "   [main] Flushing MDM Commands"
        flush_mdm
        ;;
    bluetooth-off)
        echo "   [main] Disabling Bluetooth on Device"
        send_settings_command "bluetooth" "false"
        ;;
    bluetooth-on)
        echo "   [main] Enabling Bluetooth on Device"
        send_settings_command "bluetooth" "true"
        ;;
esac
