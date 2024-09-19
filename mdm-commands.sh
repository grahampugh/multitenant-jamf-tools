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
        computers=0
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

redeploy_mdm() {
    # This function will redeploy the Management Framework to the selected devices

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [redeploy_mdm] Processing Computer: id: $computer_id  name: $computer_name"
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
}

eacas() {
    # This function will erase the selected devices

    # passcode
    passcode="000000"

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

        # we need to set the recovery loack password if not already set
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
}

removemdm() {
    # This function will remove the MDM profile from the selected devices

    # now loop through the list and perform the action
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        echo
        echo "   [unmanage] Processing Computer: id: $computer_id  name: $computer_name"
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

MDM command type:

--erase                         - Erase the device
--redeploy                      - Redeploy the Management Framework
--recovery                      - Set the recovery lock password
                                  Recovery lock password will be random unless set
                                  with --recovery-lock-password.
--removemdm                     - Remove the MDM Enrollment Profile (Unmanage)

Options for the --recovery type:

--random-lock-password          - Create a random recovery lock password (this is the default)
--recovery-lock-password        - Define a recovery lock password
--clear-recovery-lock-password  - Clear the recovery lock password

Define the target clients:

--id                            - Predefine an ID (from Jamf) to search for
--serial                        - Predefine a computer's Serial Number to search for. 
                                  Can be a CSV list,
                                  e.g. ABCD123456,ABDE234567,XWSA123456
--group                         - Predefine computers to those in a specified group

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
        --redeploy|--redeploy-framework)
            mdm_command="redeploy"
            ;;
        --recovery|--recovery-lock)
            mdm_command="recovery"
            ;;
        --removemdm|--remove-mdm-profile)
            mdm_command="removemdm"
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

if [[ ! $mdm_command ]]; then
    echo
    printf 'Select from [E] Erase, [M] Redeploy Management Framework, [R] Set Recovery Lock, [P] Remove MDM Enrollment Profile : '
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
        *)
            echo
            echo "No valid action chosen!"
            exit 1
            ;;
    esac
fi

# if a group name was supplied at the command line, compile the list of computers from that group
if [[ $group_name ]]; then
    echo
    get_computers_in_group
fi

# to send MDM commands, we need to find out the computer id
generate_computer_list

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
        redeploy_mdm
        ;;
    recovery)
        echo "   [main] Setting recovery lock"
        set_recovery_lock
        ;;
    removemdm)
        echo "   [main] Removing MDM Enrollment Profile"
        removemdm
        ;;
esac

exit 0
