#!/bin/bash

# --------------------------------------------------------------------------------
# Script for running various MDM commands

# Actions:
# - Checks if we already have a token
# - Grabs a new token if required using basic auth
# - Works out the Jamf Pro version, quits if less than 10.36
# - Posts the MDM command request
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    echo "
./mdm-commands.sh options

./set_credentials.sh               - set the Keychain credentials

[no arguments]                     - interactive mode
-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - perform action on a specific instance
                                     (must exist in the relevant instance list)
                                     (multiple values can be provided)
-x | --nointeraction               - run without checking instance is in an instance list
                                     (prevents interactive choosing of instances)
--user | --client-id CLIENT_ID     - use the specified client ID or username
-v | --verbose                     - add verbose curl output

MDM command type:

--erase                            - Erase the device
--redeploy                         - Redeploy the Management Framework
--recovery                         - Set the recovery lock password
                                     Recovery lock password will be random unless set
                                     with --recovery-lock-password
--removemdm                        - Remove the MDM Enrollment Profile (Unmanage)
--deleteusers                      - Delete all users from a device (Shared iPad)
--restart                          - Restart device (mobile devices only)
--logout                           - Log out user from a device (mobile devices only)
--flushmdm                         - Flush MDM commands
--bluetooth-off                    - Disable Bluetooth (mobile devices only)
--bluetooth-on                     - Enable Bluetooth (mobile devices only)
--toggle                           - Toggle Software Update Plan Feature
                                     This will toggle the feature on or off, clearing any plans
                                     that may be set.
--msuplanstatus                    - Get MSU Software Update plan status for individual devices
--msuupdatestatus                  - Get MSU Software Update update status for individual devices
--msucreateplan                    - Create an MSU Software Update plan for a group of devices
                                     Requires --group and --version-type options
                                     (see below for more details)

Options for the --recovery type:

--random-lock-password             - Create a random recovery lock password (this is the default)
--recovery-lock-password           - Define a recovery lock password
--clear-recovery-lock-password     - Clear the recovery lock password

Options for the --deleteusers type:
--force                            - Force user deletion
--noforce                          - Do not force deletion
--group                            - Predefine devices to those in a specified group

Options for the --restart and --logout types:
--group                            - Predefine devices to those in a specified group

Options for the --msucreateplan type:
--computers                        - Device type is computers
--devices                          - Device type is mobile devices
--appletv                          - Device type is Apple TV
--group                            - Predefine devices to those in a specified group (required)
--version-type                     - Specify the version type to use for the plan
                                     (one of 'LATEST_ANY', 'LATEST_MINOR', 'LATEST_MAJOR', 'SPECIFIC_VERSION')
--version                          - Specify a specific version to use for the plan, if version-type is missing
                                     or set to 'SPECIFIC_VERSION'
                                     (e.g. 14.6, 15.0.1)
--days-until-force-install         - Specify the number of days until the plan will force install
                                     (default is 7)

Options for the --msuplanstatus type:
--events                           - Include event details in the output (default is false)
--open                             - Open the output CSV file in the default application (default is false)

Options for the --msuupdatestatus type:
--open                             - Open the output CSV file in the default application (default is false)

Options for the --flushmdm type:
--pending                          - Flush pending commands only (default is pending+failed)
--failed                           - Flush failed commands only (default is pending+failed)
--computers                        - Device type is computers (default)
--devices                          - Devices type is devices (default is computers)
--group                            - Flush commands based on a group rather than individual computers or devices

Define the target clients:

--id                            - Predefine an ID (from Jamf) to search for
--serial                        - Predefine a computer's Serial Number to search for. 
                                  Can be a CSV list,
                                  e.g. ABCD123456,ABDE234567,XWSA123456

You can clear the recovery lock password with --clear-recovery-lock-password
"
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
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
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
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
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
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
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
}

toggle_software_update_feature() {
    # This function will toggle the "new" software update feature allowing to clear any plans

    echo
    echo "   [toggle_software_update_feature] Toggling software update command on $jss_instance"
    echo "   [toggle_software_update_feature] This endpoint is asynchronous, the provided value will not be immediately updated."
    echo

    # toggle software update feature
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
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

msu_create_plan() {
    # create a plan for the MSU updates
    # The required inputs are the group ID, the version type, the specific version if version type is "SPECIFIC_VERSION", and the Force Install Local DateTime.
    echo "Creating MSU plan..."

    # validate device type
    if [[ "$device_type" == "computer" ]]; then
        device_type="COMPUTER"
    elif [[ "$device_type" == "device" ]]; then
        device_type="MOBILE_DEVICE"
    elif [[ "$device_type" == "apple"* ]]; then
        device_type="APPLE_TV"
    else
        # if device_type is not set, ask for it
        if [[ $no_interaction -ne 1 ]]; then
            echo "Please select a device type for the plan:"
            read -r -p "Select [C] for computer, [D] for mobile device, or [A] for Apple TV: " action_question
            case "$action_question" in
                C|c)
                    device_type="COMPUTER"
                    ;;
                D|d)
                    device_type="MOBILE_DEVICE"
                    ;;
                A|a)
                    device_type="APPLE_TV"
                    ;;
                *)
                    echo "Invalid device type specified. Please use --computer, --device, or --appletv."
                    exit 1
                    ;;
            esac
        fi
        # convert to uppercase
        device_type=$(tr '[:lower:]' '[:upper:]' <<< "$device_type")
    fi

    if [[ "$device_type" != "COMPUTER" && "$device_type" != "MOBILE_DEVICE" && "$device_type" != "APPLE_TV" ]]; then
        echo "Invalid device type specified. Please use --computer, --device, or --appletv."
        exit 1
    fi

    if [[ -z "$group_name" ]]; then
        echo "Group is required to create a plan."
        if [[ $no_interaction == 1 ]]; then
            echo "No group specified, exiting."
            exit 1
        fi
        # enter a group name
        echo ""
        read -r -p "Please enter a group name for device type '$device_type': " group_name
    fi

    # check again that a group name was entered
    if [[ -z "$group_name" ]]; then
        echo "No group name specified, exiting."
        exit 1
    fi

    # check if a version_type was specified, if not, ask for it
    if [[ -z "$version_type" && $no_interaction -ne 1 ]]; then
        echo "Please select a version type for the plan:"
        read -r -p "Select [L] for latest any version, [M] for latest major version, [m] for latest minor version, or leave blank to enter a specific version: " action_question
        case "$action_question" in
            L|l)
                version_type="LATEST_ANY"
                ;;
            M)
                version_type="LATEST_MAJOR"
                ;;
            m)
                version_type="LATEST_MINOR"
                ;;
        esac
        echo
    fi

    version_type=$(tr '[:lower:]' '[:upper:]' <<< "$version_type")

    if [[ "$version_type" != "LATEST_ANY" && "$version_type" != "LATEST_MAJOR" && "$version_type" != "LATEST_MINOR" ]]; then
        if [[ "$specific_version" ]]; then
            version_type="SPECIFIC_VERSION"
        elif [[ "$no_interaction" -ne 1 ]]; then
            # ask for a specific version
            read -r -p "Please enter a specific version (e.g. 14.6): " specific_version
            if [[ -z "$specific_version" ]]; then
                echo "No specific version specified, exiting."
                exit 1
            fi
            # validate that the specific version is in the correct format
            if ! [[ "$specific_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                echo "Invalid specific version format. Please use 'major.minor' or 'major.minor.patch' format."
                exit 1
            else
                version_type="SPECIFIC_VERSION"
            fi
        else
            echo "Invalid version type specified. Please use 'LATEST_ANY', 'LATEST_MAJOR', 'LATEST_MINOR', or 'SPECIFIC_VERSION', or set a value to --specific-version."
            exit 1
        fi
    else
        specific_version="NO_SPECIFIC_VERSION"
    fi
    
    # set force install local datetime (default is 7 days from now)
    if [[ -z "$days_until_force_install" ]]; then
        if [[ $no_interaction -ne 1 ]]; then
            echo "Please enter the number of days until the Force Install Local DateTime"
            echo "(or leave blank for 7 days):"
            read -r -p "Number of days: " days_until_force_install
            # validate that the input is a number if not blank
            if [[ -n "$days_until_force_install" ]] && ! [[ "$days_until_force_install" =~ ^[0-9]+$ ]]; then
                echo "Invalid input. Please enter a number."
                exit 1
            fi
        fi
    fi
    # set default value if not set
    if [[ -z "$days_until_force_install" ]]; then
        echo "No days until force install specified, using default of 7 days."
        days_until_force_install=7
    fi

    # convert to ISO 8601 format
    force_install_local_datetime=$(date "-v+${days_until_force_install}d" +"%Y-%m-%dT%H:%M:%S")

    # get group ID from name
    object_name="$group_name"
    if [[ "$device_type" == "COMPUTER" ]]; then
        api_xml_object="computer_group"
    else
        api_xml_object="mobile_device_group"
    fi
    get_object_id_from_name
    # check if we have an existing ID
    if [[ -z "$existing_id" ]]; then
        echo "No group with name '$group_name' found."
        exit 1
    fi

    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"
    endpoint="api/v1/managed-software-updates/plans/group"
    curl_url="$jss_url/$endpoint"
    curl_args=("--request")
    curl_args+=("POST")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--data-raw")
    curl_args+=('{
        "group": {
            "objectType": "'"$device_type"'_GROUP",
            "groupId": "'"$existing_id"'"
        },
        "config": {
            "updateAction": "DOWNLOAD_INSTALL_SCHEDULE",
            "versionType": "'"$version_type"'",
            "specificVersion": "'"$specific_version"'",
            "forceInstallLocalDateTime": "'"$force_install_local_datetime"'"
        }
    }'
    )
    # show args
    echo "Creating plan with the following parameters:" # TEMP
    echo "${curl_args[*]}" # TEMP

    send_curl_request

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*mdm-commands.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Create MSU Plan for Device Type: $device_type\nGroup: $group_name\nVersion Type: $version_type\nSpecific Version: $specific_version\nForce Install Local DateTime: $force_install_local_datetime'}"
    send_slack_notification "$slack_text"
}

get_computer_list() {
    # get a list of computers from the JSS
    echo "   [get_computer_list] Getting computer list from JSS instance: $jss_instance"
    jss_url="$jss_instance"
    endpoint="/api/preview/computers"
    handle_jpapi_get_request "$endpoint" sort
    # create a variable containing the json output from $curl_output_file
    computer_results=$(echo "$combined_output" | jq -s '[.[].results[]]')
    echo "$computer_results" > /tmp/computer_results.json # TEMP
}

get_mobile_device_list() {
    # get a list of mobile devices from the JSS
    # first get the device count so we can find out how many loops we need
    echo "   [get_mobile_device_list] Getting mobile device list from JSS instance: $jss_instance"
    jss_url="$jss_instance"
    endpoint="/api/v2/mobile-devices"
    handle_jpapi_get_request "$endpoint" sort

    # create a variable containing the json output from $curl_output_file
    mobile_device_results=$(echo "$combined_output" | jq -s '[.[].results[]]')
    echo "$mobile_device_results" > /tmp/device_results.json # TEMP
}

msu_plan_status() {
    # This function will get the MSU Software Update plan statuses for individual devices

    # we get the device names from the JSS for use in the output
    get_computer_list
    get_mobile_device_list
    # exit # TEMP
    # cat "$computer_output" # TEMP

    # get MSU Software Update plan status
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"
    endpoint="/api/v1/managed-software-updates/plans"
    sort_filter="planUuid"
    handle_jpapi_get_request "$endpoint" sort "$sort_filter"

    plan_output="$combined_output"
    echo "   [msu_plan_status] MSU Software Update plan statuses:"
    # cat "$plan_output" # TEMP

    # now loop through the output using jq, output the computer ID, the updateAction value, the versionType value, the forceInstallLocalDateTime value, and the status state and errorReasons. The following is an example of the output for one device in the list:

    echo
    echo "   [msu_plan_status] MSU Software Update plan status for individual devices:"
    echo
    # create a CSV file to store the output. The name of the file includes the date, time, and subdomain of the JSS instance
    jss_subdomain=$(echo "$jss_instance" | awk -F/ '{print $3}' | awk -F. '{print $1}')
    current_datetime=$(date +"%Y-%m-%d_%H-%M-%S")
    # create a CSV file with the name msu_plan_status_<subdomain>_<date>_<time>.csv
    csv_dir="/Users/Shared/Jamf/MDM-Commands/msu_plan_status"
    mkdir -p "$csv_dir"
    csv_file_name="msu_plan_status_${jss_subdomain}_${current_datetime}.csv"

    # add the column headings to the csv file
    if [[ "$events" == "true" ]]; then
        echo "Device ID,Device Name,Device Type,Device Model,Plan UUID,Update Action,Version Type,Specific Version,Max Deferrals,Force Install Local DateTime,State,Error Reasons,Plan Created,Plan Accepted,Plan Started,Declarative Command Queued,DDM Plan Scheduled,Plan Rejected" > "$csv_dir/$csv_file_name"
    else
        echo "Device ID,Device Name,Device Type,Device Model,Plan UUID,Update Action,Version Type,Specific Version,Max Deferrals,Force Install Local DateTime,State,Error Reasons" > "$csv_dir/$csv_file_name"
    fi

    /usr/bin/jq -c '.results[]' <<< "$plan_output" | while IFS= read -r item; do
        device_id=$(echo "$item" | /usr/bin/jq -r '.device.deviceId')
        object_type=$(echo "$item" | /usr/bin/jq -r '.device.objectType')
        plan_uuid=$(echo "$item" | /usr/bin/jq -r '.planUuid')
        update_action=$(echo "$item" | /usr/bin/jq -r '.updateAction')
        version_type=$(echo "$item" | /usr/bin/jq -r '.versionType')
        specific_version=$(echo "$item" | /usr/bin/jq -r '.specificVersion')
        max_deferrals=$(echo "$item" | /usr/bin/jq -r '.maxDeferrals')
        force_install_local_datetime=$(echo "$item" | /usr/bin/jq -r '.forceInstallLocalDateTime')
        state=$(echo "$item" | /usr/bin/jq -r '.status.state')
        error_reasons=$(echo "$item" | /usr/bin/jq -r '.status.errorReasons | join("|")')

        # echo "Object Type: $object_type"
        if [[ "$object_type" == "COMPUTER" ]]; then
            echo "Computer ID: $device_id"
            device_name=$(jq -r --arg id "$device_id" '.[] | select(.id == $id) | .name' <<< "$computer_results")
            echo "Computer Name: $device_name"
        elif [[ "$object_type" == "MOBILE_DEVICE" ]]; then
            echo "Device ID: $device_id"
            device_name=$(jq -r --arg id "$device_id" '.[] | select(.id == $id) | .name' <<< "$mobile_device_results")
            device_model=$(jq -r --arg id "$device_id" '.[] | select(.id == $id) | .model' <<< "$mobile_device_results")
            echo "Device Name: $device_name"
            echo "Device Model: $device_model"
        else
            echo "Unknown Object Type: $object_type"
            continue
        fi

        echo "Plan UUID: $plan_uuid"
        echo "Update Action: $update_action"
        echo "Version Type: $version_type"
        if [[ "$specific_version" != "null" ]]; then
            echo "Specific Version: $specific_version"
        fi
        echo "Max Deferrals: $max_deferrals"
        echo "Force Install Local DateTime: $force_install_local_datetime"
        echo "State: $state"
        if [[ "$state" == "PlanFailed" ]]; then
            echo "Error Reasons: $error_reasons"
        fi
        echo
        # append the output to a csv file
        if [[ "$events" == "true" ]]; then
            # get the event details if events are enabled
            get_event "$plan_uuid"
            echo "$device_id,$device_name,$(tr '[:upper:]' '[:lower:]' <<< "$object_type"),$device_model,$plan_uuid,$update_action,$version_type,$specific_version,$max_deferrals,$force_install_local_datetime,$state,$error_reasons,$plan_created_event,$plan_accepted_event,$start_plan_event,$queue_declarative_command,$ddm_plan_scheduled_event,$plan_rejected_event" >> "$csv_dir/$csv_file_name"
        else
            echo "$device_id,$device_name,$(tr '[:upper:]' '[:lower:]' <<< "$object_type"),$device_model,$plan_uuid,$update_action,$version_type,$specific_version,$max_deferrals,$force_install_local_datetime,$state,$error_reasons" >> "$csv_dir/$csv_file_name"
        fi
    done

    echo "   [msu_plan_status] CSV file outputted to: $csv_dir/$csv_file_name"
    if [[ "$open_csv" == "true" ]]; then
        echo "   [msu_plan_status] Opening CSV file..."
        open "$csv_dir/$csv_file_name"
    fi
}

get_event() {
    # if an event UUID is provided, search for the event in the temp_file and use the api/v1/managed-software-updates/plans/$plan_uuid/events endpoint to get the event details (currently commented out because jamfapi is not successfully returning events)
    local event="$1"
    if [[ "$events" == "true" ]]; then
        echo "Searching for event UUID: $event"
        # now run the command and output the results to a file

        # grab current background status
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
        jss_url="$jss_instance"
        endpoint="api/v1/managed-software-updates/plans/$event/events"
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request

        if [[ $http_response -gt 299 ]]; then
            echo "Error getting event details for UUID: $event"
            echo "HTTP Response Code: $http_response"
            echo "Response: $(cat "$curl_output_file")"
            return 1
        fi
    fi
    if [[ "$curl_output_file" ]]; then
        # parse the event details from the temp_file
        event_details=$(jq -r .events "$curl_output_file")
        if [[ -n "$event_details" ]]; then
            # echo "Event Store: $event_details" # TEMP
            # using jq, parse the event details to get the types and their associated eventReceivedEpoch
            # convert the eventReceivedEpoch to a human-readable format
            plan_created_event=""
            plan_accepted_event=""
            start_plan_event=""
            queue_declarative_command=""
            ddm_plan_scheduled_event=""
            plan_rejected_event=""
            echo "Event Details:"
            # using jq to format the output
            while read -r line; do
                event_type=$(echo "$line" | cut -d':' -f1)
                event_received_epoch=$(echo "$line" | cut -d':' -f2) 
                event_sent_epoch=$(echo "$line" | cut -d':' -f3) 
                # events have a received epoch
                if [[ "$event_received_epoch" == "null" ]]; then
                    event_received_date=""
                else
                    event_received_date=$(date -r $((event_received_epoch/1000)) +"%Y-%m-%d %H:%M:%S")
                fi
                # commands have a sent epoch
                if [[ "$event_sent_epoch" == "null" ]]; then
                    event_sent_date=""
                else
                    event_sent_date=$(date -r $((event_sent_epoch/1000)) +"%Y-%m-%d %H:%M:%S")
                fi
                case "$event_type" in
                    ".PlanCreatedEvent")
                        echo "Plan Created: $event_received_date"
                        plan_created_event="$event_received_date"
                        ;;
                    ".PlanAcceptedEvent")
                        echo "Plan Accepted: $event_received_date"
                        plan_accepted_event="$event_received_date"
                        ;;
                    ".StartPlanEvent")
                        echo "Plan Started: $event_received_date"
                        start_plan_event="$event_received_date"
                        ;;
                    ".QueueDeclarativeCommand")
                        echo "Declarative Command Queued: $event_sent_date"
                        queue_declarative_command="$event_sent_date"
                        ;;
                    ".DDMPlanScheduledEvent")
                        echo "DDM Plan Scheduled: $event_received_date"
                        ddm_plan_scheduled_event="$event_received_date"
                        ;;
                    ".PlanRejectedEvent")
                        echo "Plan Rejected: $event_received_date"
                        plan_rejected_event="$event_received_date"
                        ;;
                    *"Event")
                        echo "Event Type $event_type: $event_received_date"
                        ;;
                    *"Command")
                        echo "Command Type $event_type: $event_sent_date"
                        ;;
                    *)
                        echo "Unknown Event Type: $event_type"
                        ;;
                esac
            done < <(jq -r '.events[] | "\(.type):\(.eventReceivedEpoch):\(.eventSentEpoch)"' <<< "$event_details")
        fi
    else
        echo "No event found with UUID: $event"
    fi
}


msu_update_status() {
    # This function will get the MSU Software Update update statuses for individual devices

    # we get the device names from the JSS for use in the output
    get_computer_list
    get_mobile_device_list
    # exit # TEMP
    # cat "$computer_output" # TEMP

    # get MSU Software Update plan status
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"
    endpoint="/api/v1/managed-software-updates/update-statuses"
    sort_filter="osUpdatesStatusId"
    handle_jpapi_get_request "$endpoint" sort "$sort_filter"

    status_output="$combined_output"
    echo "   [msu_update_status] MSU Software Update update statuses:"

    # now loop through the output using jq, output the computer ID, the updateAction value, the versionType value, the forceInstallLocalDateTime value, and the status state and errorReasons. The following is an example of the output for one device in the list:

    echo
    echo "   [msu_update_status] MSU Software Update plan status for individual devices:"
    echo
    # create a CSV file to store the output. The name of the file includes the date, time, and subdomain of the JSS instance
    jss_subdomain=$(echo "$jss_instance" | awk -F/ '{print $3}' | awk -F. '{print $1}')
    current_datetime=$(date +"%Y-%m-%d_%H-%M-%S")
    # create a CSV file with the name msu_plan_status_<subdomain>_<date>_<time>.csv
    csv_dir="/Users/Shared/Jamf/MDM-Commands/msu_update_status"
    mkdir -p "$csv_dir"
    csv_file_name="msu_update_status_${jss_subdomain}_${current_datetime}.csv"
    echo "Device ID,Device Name,Device Type,Device Model,Downloaded,Percent Complete,Product Key,Status,Max Deferrals,Next Scheduled Install" > "$csv_dir/$csv_file_name"
    /usr/bin/jq -c '.results[]' <<< "$status_output" | while IFS= read -r item; do
        device_id=$(echo "$item" | /usr/bin/jq -r '.device.deviceId')
        object_type=$(echo "$item" | /usr/bin/jq -r '.device.objectType')
        max_deferrals=$(echo "$item" | /usr/bin/jq -r '.maxDeferrals')
        next_scheduled_install=$(echo "$item" | /usr/bin/jq -r '.nextScheduledInstall')
        downloaded=$(echo "$item" | /usr/bin/jq -r '.downloaded')
        percent_complete=$(echo "$item" | /usr/bin/jq -r '.downloadPercentComplete')
        product_key=$(echo "$item" | /usr/bin/jq -r '.productKey')
        status=$(echo "$item" | /usr/bin/jq -r '.status')
    
        if [[ "$object_type" == "COMPUTER" ]]; then
            echo "Computer ID: $device_id"
            device_name=$(jq -r --arg id "$device_id" '.[] | select(.id == $id) | .name' <<< "$computer_results")
            echo "Computer Name: $device_name"
        elif [[ "$object_type" == "MOBILE_DEVICE" ]]; then
            echo "Device ID: $device_id"
            device_name=$(jq -r --arg id "$device_id" '.[] | select(.id == $id) | .name' <<< "$mobile_device_results")
            device_model=$(jq -r --arg id "$device_id" '.[] | select(.id == $id) | .model' <<< "$mobile_device_results")
            echo "Device Name: $device_name"
            echo "Device Model: $device_model"
        else
            echo "Unknown Object Type: $object_type"
            continue
        fi

        echo "Downloaded: $downloaded"
        echo "Percent Complete: $percent_complete"
        echo "Product Key: $product_key"
        echo "Status: $status"
        echo "Max Deferrals: $max_deferrals"
        echo "Next Scheduled Install: $next_scheduled_install"
        echo
        # append the output to a csv file
        echo "$device_id,$device_name,$(tr '[:upper:]' '[:lower:]' <<< "$object_type"),$device_model,$downloaded,$percent_complete,$product_key,$status,$max_deferrals,$next_scheduled_install" >> "$csv_dir/$csv_file_name"
    done

    echo "   [msu_update_status] CSV file outputted to: $csv_dir/$csv_file_name"
    if [[ "$open_csv" == "true" ]]; then
        echo "   [msu_update_status] Opening CSV file..."
        open "$csv_dir/$csv_file_name"
    fi
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
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
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
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
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
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
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
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
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
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
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
            # get token
            if [[ "$chosen_id" ]]; then
                set_credentials "$jss_instance" "$chosen_id"
                echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
            else
                set_credentials "$jss_instance"
                echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
            fi
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
                # get token
                if [[ "$chosen_id" ]]; then
                    set_credentials "$jss_instance" "$chosen_id"
                    echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
                else
                    set_credentials "$jss_instance"
                    echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
                fi
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

are_you_sure() {
    echo
    read -r -p "Are you sure you want to proceed? (Y/N) : " sure
    case "$sure" in
        Y|y)
            return
            ;;
        *)
            echo
            echo "Action cancelled, quitting"
            exit 
            ;;
    esac
}


# --------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------

mdm_command=""
recovery_lock_password=""

# read inputs
while test $# -gt 0 ; do
    case "$1" in
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
            ;;
        -i|--instance)
            shift
            chosen_instance="$1"
            ;;
        --client-id|--user|--username)
            shift
            chosen_id="$1"
        ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        --id)
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
            mdm_command="removemdm"
            ;;
        --flushmdm|--flush-mdm)
            mdm_command="flushmdm"
            ;;
        --msuplan|--msuplanstatus|--msu-plan)
            mdm_command="msuplanstatus"
            ;;
        --msuupdate|--msuupdatestatus|--msu-update-status)
            mdm_command="msuupdatestatus"
            ;;
        --events)
            events=true
            ;;
        -o|--open)
            open_csv=true
            ;;
        --msucreateplan|--msu-create-plan)
            mdm_command="msucreateplan"
            ;;
        --version-type)
            shift
            version_type="$1"
            ;;
        --version)
            shift
            specific_version="$1"
            ;;
        --days-until-force-install)
            shift
            days_until_force_install="$1"
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

# Ask for the instance list, show list, ask to apply to one, multiple or all

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Only one instance may be selected. Selecting the first: ${chosen_instances[0]}"
    chosen_instance="${chosen_instances[0]}"
fi

# select the instances that will be changed
choose_destination_instances

# get first intance from the list
jss_instance="${instance_choice_array[0]}"

if [[ $mdm_command ]]; then
    echo "MDM command preselected: $mdm_command"
else
    echo
    echo "Select from the following supported MDM commands:"
    echo "   [E] Erase All Content And Settings"
    echo "   [M] Redeploy Management Framework"
    echo "   [R] Set Recovery Lock"
    echo "   [P] Remove MDM Enrollment Profile"
    echo "   [D] Delete all users (Shared iPads)"
    echo "   [S] Restart device (mobile devices)"
    echo "   [L] Logout user (mobile devices)"
    echo "   [B0] [B1] Disable/Enable Bluetooth (mobile devices)"
    echo "   [F] Flush MDM commands"
    echo "   [MSUP] Get MSU Software Update Plan Status"
    echo "   [MSUS] Get MSU Software Update Status"
    echo "   [MSUC] Create MSU Software Update Plan"
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
        MSUP|msup)
            mdm_command="msuplanstatus"
            ;;
        MSUS|msus)
            mdm_command="msuupdatestatus"
            ;;
        MSUC|msuc)
            mdm_command="msucreateplan"
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
if [[ $group_name && $mdm_command != "flushmdm" && $mdm_command != "toggle" && $mdm_command != "msu"* ]]; then
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
    elif [[ $mdm_command != "toggle" && $mdm_command != "msu"* ]]; then
        generate_computer_list
    fi
elif [[ $mdm_command != "toggle" && $mdm_command != "msu"* ]]; then
    echo "Using group: $group_name"
fi

# for toggling software update feature status we want to display the current value
if [[ $mdm_command == "toggle" || $mdm_command == "msu"* ]]; then
    get_software_update_feature_status
    echo "   [get_software_update_feature_status] WARNING: Do not proceed if either of the above values is less than 100%"
    if [[ $mdm_command == "toggle" ]]; then
        echo "   [toggle_software_update_feature] Proceed to toggle to '$toggle_set_value'..."
    fi
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
    msuplanstatus)
        echo "   [main] Getting Software Update Plan Status for Individual Devices"
        msu_plan_status
        ;;
    msuupdatestatus)
        echo "   [main] Getting Software Update Status for Individual Devices"
        msu_update_status
        ;;
    msucreateplan)
        echo "   [main] Creating Software Update Plan for Group of Devices"
        msu_create_plan
        ;;
esac

echo 
echo "Finished"
echo
