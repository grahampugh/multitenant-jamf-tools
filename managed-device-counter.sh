#!/bin/bash

# --------------------------------------------------------------------------------
# Script for counting devices on all instances
# Adapted from an idea by Anver Husseini (AnyKey IT) by Graham Pugh
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
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
    
# Managed Device Counter
A script for counting managed and unmanaged devices and computers on one or more Jamf Pro instances.

# Requirements
- Credentials for the Jamf Pro instance(s) must be set in the AutoPkg preferences or in the Keychain (the script will prompt you to run the set_credentials.sh script if not found)
- The _common-framework.sh script must be available in the same folder as this script.

# Usage:
[no arguments]                       - interactive mode
-a | --anonymous (or -a)             - output to shell with anonymous contexts
-o | --output /path/to/file.txt      - output to the specified text file (default is 
                                       /tmp/managed-device-counter.txt)
-c | --csv /path/to/file.csv         - output to the specified CSV file (default is 
                                       /tmp/managed-device-counter.csv)
-il | --instance-list FILENAME       - provide a server-list filename (without .txt)
                                       (must exist in the instance-lists folder)
-i | --instance JSS_URL              - perform action on a single instance
                                       (must exist in the relevant instance list)
--all                                - perform action on ALL instances in the instance list
-x | --nointeraction                 - run without checking instance is in an instance list 
                                       (prevents interactive mode)
-v | --verbose                       - add verbose curl output
-h | --help                          - Show this help message

USAGE
}

get_computer_count() {
    # determine jss_url
    jss_url="${jss_instance}"
    # send request
    curl_url="$jss_url/api/v1/inventory-information"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request
}

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi


# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# get command line arguments
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
        --all)
            all_instances=1
        ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        -a|--anonymous)
            anonymous="yes"
        ;;
        -c|--csv)
            shift
            output_csv="$1"
        ;;
        -o|--output)
            shift
            output_file="$1"
        ;;
        -v|--verbose)
            verbose=1
        ;;
        -h|--help)
            usage
            exit
        ;;
        *)
            app_name="$1"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# set default output file
if [[ ! $output_file ]]; then
    output_file="/Users/Shared/MJT/managed-device-counter.txt"
fi
if [[ ! $csv ]]; then
    output_csv="/Users/Shared/MJT/managed-device-counter.csv"
fi

# ensure the directories can be written to, and empty the files
mkdir -p "$(dirname "$output_file")"
echo "" > "$output_file"
mkdir -p "$(dirname "$output_csv")"
echo "" > "$output_csv"

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# clear any existing values
total_managed_computers="0"
total_unmanaged_computers="0"
total_managed_devices="0"
total_unmanaged_devices="0"

# heading for csv
echo "Context,Managed Computers,Unmanaged Computers,Managed Devices,Unmanaged Devices" >> "$output_csv"
# heading for text file
(
    echo "-------------------------------------------------------------------------------------"
    echo "Jamf Pro Device Count                                    $(date)"
    echo "-------------------------------------------------------------------------------------"
    echo "                                                   Computers           Devices"
    echo "Context                                        Managed  Unmanaged  Managed  Unmanaged"
    echo "-------------------------------------------------------------------------------------"
) >> "$output_file"

echo
echo "Building List..."
echo

instance_count=0
for jss_instance in "${instance_choice_array[@]}"; do
    ((instance_count++))
    set_credentials "$jss_instance"

    get_computer_count
    # cat "$curl_output_file"  # TEMP
    managed_computers=0
    unmanaged_computers=0
    managed_devices=0
    unmanaged_devices=0
    while read -r line ; do
        if [[ $line == *"unmanagedComputers"* ]]; then
            unmanaged_computers=$( grep "unmanagedComputers" <<< "$line" | cut -d' ' -f3 | cut -d, -f1 )
        elif [[ $line == *"managedComputers"* ]]; then
            managed_computers=$( grep "managedComputers" <<< "$line" | cut -d' ' -f3 | cut -d, -f1 )
        elif [[ $line == *"unmanagedDevices"* ]]; then
            unmanaged_devices=$( grep "unmanagedDevices" <<< "$line" | cut -d' ' -f3 | cut -d, -f1 )
        elif [[ $line == *"managedDevices"* ]]; then
            managed_devices=$( grep "managedDevices" <<< "$line" | cut -d' ' -f3 | cut -d, -f1 )
        fi
    done < "$curl_output_file"

    # echo $unmanaged_computers
    # echo $managed_computers
    # echo $unmanaged_devices
    # echo $managed_devices

    total_managed_computers=$((total_managed_computers + managed_computers))
    total_unmanaged_computers=$((total_unmanaged_computers + unmanaged_computers))
    total_managed_devices=$((total_managed_devices + managed_devices))
    total_unmanaged_devices=$((total_unmanaged_devices + unmanaged_devices))

    # Anonymous output
    [[ $anonymous ]] && instance_show="$instance_count" || instance_show="$jss_instance"

    # format for csv
    echo "$instance_show,$managed_computers,$unmanaged_computers,$managed_devices,$unmanaged_devices" >> "$output_csv"
    # format for text file
    printf "%-45s %+8s %+10s %+8s %+10s\n" \
    "$instance_show" "$managed_computers" "$unmanaged_computers" "$managed_devices" "$unmanaged_devices" >> "$output_file"
done

# summary for csv
echo "Sum of $instance_count contexts,$total_managed_computers,$total_unmanaged_computers,$total_managed_devices,$total_unmanaged_devices" >> "$output_csv"
# summary for text file
(
    echo "-------------------------------------------------------------------------------------"
    printf "Total: Contexts: %-28s %+8s %+10s %+8s %+10s\n" \
    "$instance_count" "$total_managed_computers" "$total_unmanaged_computers" "$total_managed_devices" "$total_unmanaged_devices"
    echo "-------------------------------------------------------------------------------------"
    echo
) >> "$output_file"

# now echo the file
echo
echo "Results:"
echo
cat "$output_file"
echo
echo "These results are saved to:"
echo "   Text format: $output_file"
echo "   CSV format:  $output_csv"
echo
echo "Finished"
echo
