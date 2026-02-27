#!/bin/bash

# --------------------------------------------------------------------------------
# Script for identifying unmanaged mobile device applications across Jamf instances
# This script queries all mobile devices and identifies apps that are not managed
# by Jamf Pro, then generates reports showing:
# 1. Devices with unmanaged apps (CSV listing each device and its unmanaged apps)
# 2. Unmanaged apps with devices (CSV listing each app and which devices have it)
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="ios"

# reduce the curl tries
max_tries_override=2

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# prepare working directory
workdir="/Users/Shared/Jamf/UnmanagedMobileApps"
mkdir -p "$workdir"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh prd           - set the Keychain credentials

[no arguments]                     - interactive mode
--il FILENAME (without .txt)       - provide a server-list filename
                                     (must exist in the instance-lists folder)
--i JSS_URL                        - perform action on a single instance
                                     (must exist in the relevant instance list)
--all                              - perform action on ALL instances in the instance list
--user | --client-id CLIENT_ID     - use the specified client ID or username
--list-apps                        - list all apps for each device with management status
-v                                 - add verbose curl output
USAGE
}

get_all_mobile_devices() {
    # Get a list of all mobile device IDs
    echo "   [get_all_mobile_devices] Fetching all mobile devices for $jss_instance..."

    curl_url="$jss_url/JSSResource/mobiledevices"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $http_response -eq 200 ]]; then
        device_count=$(jq -r '.mobile_devices | length' "$curl_output_file" 2>/dev/null)
        echo "   [get_all_mobile_devices] Found $device_count mobile devices"

        mobile_device_ids=()
        mobile_device_names=()

        i=0
        while [[ $i -lt $device_count ]]; do
            device_id=$(jq -r ".mobile_devices[$i].id" "$curl_output_file" 2>/dev/null)
            device_name=$(jq -r ".mobile_devices[$i].name" "$curl_output_file" 2>/dev/null)
            mobile_device_ids+=("$device_id")
            mobile_device_names+=("$device_name")
            ((i++))
        done
    else
        echo "   [get_all_mobile_devices] ERROR: Failed to fetch mobile devices (HTTP $http_response)"
        return 1
    fi
}

get_device_applications() {
    local device_id="$1"
    local device_name="$2"

    # Fetch the Applications subset for this device
    curl_url="$jss_url/JSSResource/mobiledevices/id/${device_id}/subset/Applications"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $http_response -eq 200 ]]; then
        # Parse the applications and identify unmanaged ones
        app_count=$(jq -r '.mobile_device.applications | length' "$curl_output_file" 2>/dev/null)

        if [[ "$app_count" == "null" || -z "$app_count" ]]; then
            echo "   [get_device_applications] Device '$device_name' (ID: $device_id) - no applications data found"
            if [[ $list_apps -eq 1 ]]; then
                echo "      DEBUG: Response structure:"
                jq -r '.mobile_device | keys' "$curl_output_file" 2>/dev/null || echo "      ERROR: Failed to parse JSON"
            fi
            return
        fi

        echo "   [get_device_applications] Device '$device_name' (ID: $device_id) has $app_count total apps"

        if [[ $app_count -gt 0 ]]; then
            # Debug: show keys of first app to identify correct field names
            if [[ $list_apps -eq 1 ]]; then
                echo "      DEBUG: Available keys in first app object:"
                jq -r ".mobile_device.applications[0] | keys" "$curl_output_file" 2>/dev/null
                echo "      DEBUG: First app full object:"
                jq -r ".mobile_device.applications[0]" "$curl_output_file" 2>/dev/null
                echo ""
            fi

            local unmanaged_apps=()
            local managed_count=0
            local unmanaged_count=0
            i=0
            while [[ $i -lt $app_count ]]; do
                app_name=$(jq -r ".mobile_device.applications[$i].application_name" "$curl_output_file" 2>/dev/null)
                app_version=$(jq -r ".mobile_device.applications[$i].application_version" "$curl_output_file" 2>/dev/null)
                management_status=$(jq -r ".mobile_device.applications[$i].application_status" "$curl_output_file" 2>/dev/null)

                # List apps if requested
                if [[ $list_apps -eq 1 ]]; then
                    printf "      %-50s %-15s [%s]\n" "$app_name" "$app_version" "$management_status"
                fi

                # Check if app is Unmanaged
                if [[ "$management_status" == "Unmanaged" ]]; then
                    unmanaged_apps+=("${app_name}|${app_version}")
                    ((unmanaged_count++))
                elif [[ "$management_status" == "Managed" ]]; then
                    ((managed_count++))
                fi
                ((i++))
            done

            echo "   [get_device_applications] Device '$device_name': Managed=$managed_count, Unmanaged=$unmanaged_count"

            # If device has unmanaged apps, add to report data
            if [[ ${#unmanaged_apps[@]} -gt 0 ]]; then
                # Add to devices-with-apps report
                for app_data in "${unmanaged_apps[@]}"; do
                    app_name="${app_data%|*}"
                    app_version="${app_data#*|}"
                    # Escape commas and quotes in names for CSV
                    escaped_device_name=$(echo "$device_name" | sed 's/"/""/g')
                    escaped_app_name=$(echo "$app_name" | sed 's/"/""/g')
                    echo "\"$jss_instance\",\"$escaped_device_name\",\"$device_id\",\"$escaped_app_name\",\"$app_version\"" >>"$devices_report_file"

                    # Track for apps-with-devices report
                    app_key="${app_name}::${app_version}"
                    if [[ ! " ${tracked_apps[*]} " =~ " ${app_key} " ]]; then
                        tracked_apps+=("$app_key")
                    fi
                    # Store device info for this app (will aggregate later)
                    echo "\"$jss_instance\",\"$escaped_app_name\",\"$app_version\",\"$escaped_device_name\",\"$device_id\"" >>"$apps_report_file"
                done
            fi
        else
            echo "   [get_device_applications] Device '$device_name' (ID: $device_id) has no applications"
        fi
    else
        echo "   [get_device_applications] WARNING: Failed to fetch applications for device ID $device_id (HTTP $http_response)"
        if [[ -f "$curl_output_file" ]]; then
            echo "      Response: $(cat "$curl_output_file")"
        fi
    fi
}

process_instance() {
    echo
    echo "========================================="
    echo "Processing instance: $jss_instance"
    echo "========================================="

    # Get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [process_instance] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [process_instance] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"

    # Get all mobile devices
    get_all_mobile_devices

    if [[ ${#mobile_device_ids[@]} -eq 0 ]]; then
        echo "   [process_instance] No mobile devices found for this instance"
        return
    fi

    # Process each device
    local device_index=0
    for device_id in "${mobile_device_ids[@]}"; do
        device_name="${mobile_device_names[$device_index]}"
        echo "   [process_instance] Processing device $((device_index + 1))/${#mobile_device_ids[@]}: $device_name (ID: $device_id)"

        get_device_applications "$device_id" "$device_name"

        ((device_index++))
    done

    echo "   [process_instance] Completed processing $jss_instance"
}

create_csv_files() {
    # Create CSV for devices with unmanaged apps
    devices_report_file="$workdir/devices-with-unmanaged-apps-$(date +%Y-%m-%d_%H%M%S).csv"
    echo "Instance,Device Name,Device ID,App Name,App Version" >"$devices_report_file"
    echo "   [create_csv_files] Created devices report: $devices_report_file"

    # Create CSV for apps with devices
    apps_report_file="$workdir/unmanaged-apps-with-devices-$(date +%Y-%m-%d_%H%M%S).csv"
    echo "Instance,App Name,App Version,Device Name,Device ID" >"$apps_report_file"
    echo "   [create_csv_files] Created apps report: $apps_report_file"
}

finalize_reports() {
    echo
    echo "========================================="
    echo "Report Generation Complete"
    echo "========================================="
    echo
    echo "Reports saved to:"
    echo "1. Devices with unmanaged apps: $devices_report_file"

    # Count unique devices
    device_count=$(tail -n +2 "$devices_report_file" | cut -d',' -f2,3 | sort -u | wc -l | xargs)
    echo "   - Total devices with unmanaged apps: $device_count"

    echo
    echo "2. Unmanaged apps with devices: $apps_report_file"

    # Count unique apps
    app_count=$(tail -n +2 "$apps_report_file" | cut -d',' -f2,3 | sort -u | wc -l | xargs)
    echo "   - Total unique unmanaged apps: $app_count"

    echo
    echo "You can open these files with:"
    echo "  open \"$devices_report_file\""
    echo "  open \"$apps_report_file\""
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Initialize arrays for tracking
tracked_apps=()
list_apps=0

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
    -il | --instance-list)
        shift
        chosen_instance_list_file="$1"
        ;;
    -i | --instance)
        shift
        chosen_instances+=("$1")
        ;;
    -a | -ai | --all | --all-instances)
        all_instances=1
        ;;
    --id | --client-id | --user | --username)
        shift
        chosen_id="$1"
        ;;
    -x | --nointeraction)
        no_interaction=1
        ;;
    --list-apps)
        list_apps=1
        ;;
    -v | --verbose)
        verbose=1
        ;;
    -h | --help)
        usage
        exit
        ;;
    *)
        usage
        exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# Select the instances that will be processed
choose_destination_instances

# Create CSV files
create_csv_files

# Process all chosen instances
for instance in "${instance_choice_array[@]}"; do
    # set the instance variable
    jss_instance="$instance"

    # Process this instance
    process_instance
done

# Finalize and display report summary
finalize_reports

echo
echo "Done!"
