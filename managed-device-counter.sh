#!/bin/bash

# --------------------------------------------------------------------------------
# Script for counting devices on all instances
# Adapted from an idea by Anver Husseini (AnyKey IT) by Graham Pugh
# --------------------------------------------------------------------------------

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
[no arguments]                     - interactive mode
-a | --anonymous (or -a)           - output to shell with anonymous contexts
-o | --output /path/to/file.txt    - output to the specified text file (default is 
                                     /tmp/managed-device-counter.txt)
-c | --csv /path/to/file.csv       - output to the specified CSV file (default is 
                                     /tmp/managed-device-counter.csv)
-il | --instance-list FILENAME     - provide a server-list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - perform action on a single instance
                                     (must exist in the relevant instance list)
--all                              - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list 
                                     (prevents interactive mode)
--user | --client-id CLIENT_ID     - use the specified client ID or username
-v | --verbose                     - add verbose AutoPkg output
-h | --help                        - Show this help message

USAGE
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
        --id|--client-id|--user|--username)
            shift
            chosen_id="$1"
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
        *)
            usage
            exit
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

# create a temporary output directory for the parallel inventory runs
parallel_output_dir=$(mktemp -d /tmp/managed-device-counter.XXXXXX)

# Run the inventory-information recipe against every selected instance in
# parallel. autopkg-run.sh handles credentials per instance and writes
# "<subdomain>-inventory-information.json" per instance into parallel_output_dir
# (distinct filenames, no collision). run_autopkg_parallel is defined in
# _common-framework.sh and throttles concurrency (default 8). The terminal
# reporter streams each instance's log live as it runs.
ap_args=(
    --recipe "multitenant-jamf-tools.jamf.DownloadInventoryInformation"
    --key "OUTPUT_DIR=${parallel_output_dir}"
    --log-dir "${parallel_output_dir}/parallel-logs"
    --reporter terminal
    --no-smb
)
[[ "$chosen_id" ]] && ap_args+=(--id "$chosen_id")
[[ "$verbose" ]] && ap_args+=(--verbosity "-v")
for jss_instance in "${instance_choice_array[@]}"; do
    ap_args+=(--instance "$jss_instance")
done

run_autopkg_parallel "${ap_args[@]}"

# Accumulate per-instance results. PARALLEL_JOB_STATUS[$idx] holds the exit code
# for instance_choice_array[$idx] (the runner preserves --instance order).
instance_count=0
failed_count=0
for idx in "${!instance_choice_array[@]}"; do
    jss_instance="${instance_choice_array[$idx]}"
    ((instance_count++))

    subdomain=$(echo "$jss_instance" | sed -E 's~https?://([^./]+)\..*~\1~')
    inventory_file="${parallel_output_dir}/${subdomain}-inventory-information.json"

    if [[ "${PARALLEL_JOB_STATUS[$idx]:-1}" -ne 0 || ! -f "$inventory_file" ]]; then
        echo "   [error] inventory run failed or output missing for $jss_instance"
        ((failed_count++))
        # mark the row as unread rather than reporting a misleading 0, and do
        # not fold it into the totals
        managed_computers="-"
        unmanaged_computers="-"
        managed_devices="-"
        unmanaged_devices="-"
    else
        managed_computers=$(/usr/bin/plutil -extract managedComputers raw -o - "$inventory_file" 2>/dev/null || echo 0)
        unmanaged_computers=$(/usr/bin/plutil -extract unmanagedComputers raw -o - "$inventory_file" 2>/dev/null || echo 0)
        managed_devices=$(/usr/bin/plutil -extract managedDevices raw -o - "$inventory_file" 2>/dev/null || echo 0)
        unmanaged_devices=$(/usr/bin/plutil -extract unmanagedDevices raw -o - "$inventory_file" 2>/dev/null || echo 0)

        total_managed_computers=$((total_managed_computers + managed_computers))
        total_unmanaged_computers=$((total_unmanaged_computers + unmanaged_computers))
        total_managed_devices=$((total_managed_devices + managed_devices))
        total_unmanaged_devices=$((total_unmanaged_devices + unmanaged_devices))
    fi

    # Anonymous output
    [[ $anonymous ]] && instance_show="$instance_count" || instance_show="$jss_instance"

    # format for csv
    echo "$instance_show,$managed_computers,$unmanaged_computers,$managed_devices,$unmanaged_devices" >> "$output_csv"
    # format for text file
    printf "%-45s %+8s %+10s %+8s %+10s\n" \
    "$instance_show" "$managed_computers" "$unmanaged_computers" "$managed_devices" "$unmanaged_devices" >> "$output_file"
done

# clean up the temporary inventory output
rm -rf "$parallel_output_dir"

# summary for csv
echo "Sum of $((instance_count - failed_count)) contexts,$total_managed_computers,$total_unmanaged_computers,$total_managed_devices,$total_unmanaged_devices" >> "$output_csv"
# summary for text file
(
    echo "-------------------------------------------------------------------------------------"
    printf "Total: Contexts: %-28s %+8s %+10s %+8s %+10s\n" \
    "$((instance_count - failed_count))" "$total_managed_computers" "$total_unmanaged_computers" "$total_managed_devices" "$total_unmanaged_devices"
    echo "-------------------------------------------------------------------------------------"
    echo
    if [[ "$failed_count" -gt 0 ]]; then
        echo "Note: $failed_count of $instance_count context(s) could not be read (shown as '-') and are excluded from the totals."
        echo
    fi
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
