#!/bin/bash

# --------------------------------------------------------------------------------
# Script for updating extension attribute values on computer or mobile device inventory records
#
# This script:
# - Supports both text-based and popup-style extension attributes
# - Validates that the EA is of the expected type (text or popup)
# - For popup EAs: Checks that the value is valid for the popup choices
# - Updates the computer or mobile device inventory records via the Jamf Pro API
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

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
Usage:

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

Extension Attribute options:

--name EA_NAME                  - Name of the extension attribute to update (required)
--value EA_VALUE                - Value to assign to the extension attribute (required)
                                     For popup EAs, must be a valid popup choice
--text                          - Extension attribute is text-based
--popup                         - Extension attribute is popup-style
                                     (if neither --text nor --popup is specified, you will be prompted)

Device type:

--computers                     - Update computer extension attributes (default)
--devices                       - Update mobile device extension attributes

Define the target clients:

--id ID                            - Predefine an ID (from Jamf) to search for
--serial SERIAL                    - Predefine a computer's Serial Number to search for. 
                                     Can be a CSV list,
                                     e.g. ABCD123456,ABDE234567,XWSA123456
--group GROUP_NAME                 - Predefine devices to those in a specified group
"
}

update_extension_attribute() {
    # This function will update an extension attribute value for selected computers or mobile devices
    # It validates that the EA is popup type and the value is valid

    # Check if extension attribute name was provided
    if [[ -z "$ea_name" ]]; then
        if [[ $no_interaction -ne 1 ]]; then
            # Get list of all EAs of the specified type
            echo
            echo "   [update_extension_attribute] Getting list of Extension Attributes..."
            if [[ "$chosen_id" ]]; then
                set_credentials "$jss_instance" "$chosen_id"
                echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
            else
                set_credentials "$jss_instance"
                echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
            fi
            
            # Get all EAs
            jss_url="$jss_instance"
            if [[ "$device_type" == "devices" ]]; then
                endpoint="/api/v1/mobile-device-extension-attributes"
            else
                endpoint="/api/v1/computer-extension-attributes"
            fi
            curl_url="$jss_url/$endpoint"
            curl_args=("--request")
            curl_args+=("GET")
            curl_args+=("--header")
            curl_args+=("Accept: application/json")
            send_curl_request

            # Filter EAs by input type and store in arrays
            ea_names=()
            ea_ids=()
            if [[ "$ea_type" == "text" ]]; then
                required_type="TEXT"
            else
                required_type="POPUP"
            fi

            while IFS= read -r line; do
                ea_names+=("$line")
            done < <(/usr/bin/jq -r --arg type "$required_type" '.results[] | select(.inputType == $type) | .name' "$curl_output_file")

            while IFS= read -r line; do
                ea_ids+=("$line")
            done < <(/usr/bin/jq -r --arg type "$required_type" '.results[] | select(.inputType == $type) | .id' "$curl_output_file")

            if [[ ${#ea_names[@]} -eq 0 ]]; then
                echo "Error: No $ea_type extension attributes found."
                exit 1
            fi

            # Display numbered list
            echo
            echo "Available $ea_type extension attributes:"
            for i in "${!ea_names[@]}"; do
                printf '   [%d] %s\n' "$i" "${ea_names[$i]}"
            done
            echo
            read -r -p "Enter the number or name of the Extension Attribute: " ea_selection
            
            # Check if input is a number
            if [[ "$ea_selection" =~ ^[0-9]+$ ]]; then
                if [[ $ea_selection -ge 0 && $ea_selection -lt ${#ea_names[@]} ]]; then
                    ea_name="${ea_names[$ea_selection]}"
                    ea_id="${ea_ids[$ea_selection]}"
                else
                    echo "Error: Invalid selection number."
                    exit 1
                fi
            else
                ea_name="$ea_selection"
                # Will look up ID below
                ea_id=""
            fi
        fi
        if [[ -z "$ea_name" ]]; then
            echo "Error: Extension Attribute name is required."
            exit 1
        fi
    fi

    # Get the extension attribute details (if we don't already have the ID)
    if [[ -z "$ea_id" ]]; then
        echo "   [update_extension_attribute] Getting Extension Attribute details: $ea_name"
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
        
        # Search for the extension attribute by name
        jss_url="$jss_instance"
        if [[ "$device_type" == "devices" ]]; then
            endpoint="/api/v1/mobile-device-extension-attributes"
        else
            endpoint="/api/v1/computer-extension-attributes"
        fi
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request

        # Find the EA ID by name
        ea_id=$(/usr/bin/jq -r --arg name "$ea_name" '.results[] | select(.name == $name) | .id' "$curl_output_file")
        
        if [[ -z "$ea_id" ]]; then
            echo "Error: Extension Attribute '$ea_name' not found."
            exit 1
        fi
    fi
    
    echo "   [update_extension_attribute] Found Extension Attribute ID: $ea_id"

    # Get the full extension attribute details
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    if [[ "$device_type" == "devices" ]]; then
        endpoint="/api/v1/mobile-device-extension-attributes/$ea_id"
    else
        endpoint="/api/v1/computer-extension-attributes/$ea_id"
    fi
    curl_url="$jss_url/$endpoint"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # Check the input type
    input_type=$(/usr/bin/jq -r '.inputType' "$curl_output_file")
    
    echo "   [update_extension_attribute] Extension Attribute input type: $input_type"
    
    # Validate that the EA type matches what was requested
    if [[ "$ea_type" == "text" ]]; then
        if [[ "$input_type" != "TEXT" ]]; then
            echo "Error: Extension Attribute '$ea_name' is not a text-based extension attribute (type: $input_type)."
            echo "Only text-based extension attributes (inputType 'TEXT') can be updated with --text option."
            exit 1
        fi
        echo "   [update_extension_attribute] Extension Attribute is text-based and can be updated."
    elif [[ "$ea_type" == "popup" ]]; then
        if [[ "$input_type" != "POPUP" ]]; then
            echo "Error: Extension Attribute '$ea_name' is not a popup type (type: $input_type)."
            echo "Only popup-style extension attributes can be updated with --popup option."
            exit 1
        fi
        echo "   [update_extension_attribute] Extension Attribute is popup type."
        
        # Get the valid popup choices
        popup_choices_array=()
        while IFS= read -r line; do
            popup_choices_array+=("$line")
        done < <(/usr/bin/jq -r '.popupMenuChoices[]' "$curl_output_file")
        
        echo "   [update_extension_attribute] Valid popup choices:"
        for i in "${!popup_choices_array[@]}"; do
            printf '   [%d] %s\n' "$i" "${popup_choices_array[$i]}"
        done
        echo
    fi

    # Check if EA value was provided
    if [[ -z "$ea_value" ]]; then
        if [[ $no_interaction -ne 1 ]]; then
            if [[ "$ea_type" == "popup" ]]; then
                echo "Enter the number or value to assign (must be one of the above):"
            else
                echo "Enter the value to assign:"
            fi
            read -r ea_value_input
            
            # For popup EAs, check if input is a number
            if [[ "$ea_type" == "popup" && "$ea_value_input" =~ ^[0-9]+$ ]]; then
                if [[ $ea_value_input -ge 0 && $ea_value_input -lt ${#popup_choices_array[@]} ]]; then
                    ea_value="${popup_choices_array[$ea_value_input]}"
                else
                    echo "Error: Invalid selection number."
                    exit 1
                fi
            else
                ea_value="$ea_value_input"
            fi
        fi
        if [[ -z "$ea_value" ]]; then
            echo "Error: Extension Attribute value is required."
            exit 1
        fi
    fi

    # For popup EAs, validate the value against popup choices
    if [[ "$ea_type" == "popup" ]]; then
        value_found=0
        for choice in "${popup_choices_array[@]}"; do
            if [[ "$choice" == "$ea_value" ]]; then
                value_found=1
                break
            fi
        done
        if [[ $value_found -eq 0 ]]; then
            echo "Error: Value '$ea_value' is not a valid choice for this extension attribute."
            echo "Valid choices are:"
            for choice in "${popup_choices_array[@]}"; do
                echo "  - $choice"
            done
            exit 1
        fi
        echo "   [update_extension_attribute] Value '$ea_value' is valid."
    else
        echo "   [update_extension_attribute] Value to be set: '$ea_value'"
    fi
    echo

    # are we sure to proceed?
    are_you_sure

    # Get the EA definition ID
    ea_definition_id="$ea_id"

    # Now loop through the selected computers or mobile devices and update each one
    if [[ "$device_type" == "devices" ]]; then
        device_list=("${mobile_device_choice[@]}")
    else
        device_list=("${computer_choice[@]}")
    fi

    for device in "${device_list[@]}"; do
        if [[ "$device_type" == "devices" ]]; then
            device_id="${mobile_device_ids[$device]}"
            device_name="${mobile_device_names[$device]}"
            echo
            echo "   [update_extension_attribute] Processing Mobile Device: id: $device_id  name: $device_name"
        else
            device_id="${computer_ids[$device]}"
            device_name="${computer_names[$device]}"
            echo
            echo "   [update_extension_attribute] Processing Computer: id: $device_id  name: $device_name"
        fi
        
        # Get current computer inventory to update extension attribute
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
        
        # Use the PATCH endpoint to update just the extension attribute
        jss_url="$jss_instance"
        if [[ "$device_type" == "devices" ]]; then
            endpoint="/api/v2/mobile-devices/$device_id"
        else
            endpoint="/api/v1/computers-inventory-detail/$device_id"
        fi
        curl_url="$jss_url/$endpoint"
        curl_args=("--request")
        curl_args+=("PATCH")
        curl_args+=("--header")
        curl_args+=("Content-Type: application/json")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        curl_args+=("--data-raw")
        curl_args+=('{"general":{"extensionAttributes":[{"definitionId":"'"$ea_definition_id"'","values":["'"$ea_value"'"]}]}}')
        
        send_curl_request
        
        if [[ $http_response -ge 200 && $http_response -lt 300 ]]; then
            echo "   [update_extension_attribute] Successfully updated $device_name"
        else
            echo "   [update_extension_attribute] Failed to update $device_name (HTTP $http_response)"
        fi
    done

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*update-extension-attribute.sh*\nUser: $jss_api_user\nInstance: $jss_url\nAction: Update Extension Attribute\nAttribute: $ea_name\nValue: $ea_value'}"
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

ea_name=""
ea_value=""
device_type="computers"  # default to computers
ea_type=""  # will be set to 'text' or 'popup'

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
        --name)
            shift
            ea_name="$1"
            ;;
        --value)
            shift
            ea_value="$1"
            ;;
        --text)
            ea_type="text"
            ;;
        --popup)
            ea_type="popup"
            ;;
        --computers)
            device_type="computers"
            ;;
        --devices)
            device_type="devices"
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

# get first instance from the list
jss_instance="${instance_choice_array[0]}"

# if device type not set and not in no_interaction mode, ask for it
if [[ -z "$device_type" && $no_interaction -ne 1 ]]; then
    echo "Please select a device type:"
    read -r -p "Select [C] for computers or [D] for mobile devices: " device_type_choice
    case "$device_type_choice" in
        C|c)
            device_type="computers"
            ;;
        D|d)
            device_type="devices"
            ;;
        *)
            echo "Invalid device type. Defaulting to computers."
            device_type="computers"
            ;;
    esac
fi

echo "Device type: $device_type"
echo

# if EA type not set and not in no_interaction mode, ask for it
if [[ -z "$ea_type" && $no_interaction -ne 1 ]]; then
    echo "Please select an extension attribute type:"
    read -r -p "Select [T] for text-based or [P] for popup-style: " ea_type_choice
    case "$ea_type_choice" in
        T|t)
            ea_type="text"
            ;;
        P|p)
            ea_type="popup"
            ;;
        *)
            echo "Invalid EA type selected. Exiting."
            exit 1
            ;;
    esac
fi

if [[ -z "$ea_type" ]]; then
    echo "Error: Extension attribute type must be specified (--text or --popup)."
    exit 1
fi

echo "Extension Attribute type: $ea_type"
echo

# if a group name was supplied at the command line, compile the list of computers/devices from that group
if [[ $group_name ]]; then
    echo
    if [[ "$device_type" == "devices" ]]; then
        get_mobile_devices_in_group
    else
        get_computers_in_group
    fi
fi

# generate the computer or mobile device list
if [[ "$device_type" == "devices" ]]; then
    generate_mobile_device_list
else
    generate_computer_list
fi

# update the extension attribute
echo "   [main] Updating Extension Attribute"
update_extension_attribute

echo 
echo "Finished"
echo
