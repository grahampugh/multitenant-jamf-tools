#!/bin/bash

: <<'DOC'
Script for doing a healthcheck on all instances
by Graham Pugh
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh            - set the Keychain credentials

[no arguments]                  - interactive mode
--anonymous (or -a)             - output to shell with anonymous contexts
--csv (or -c)                   - output to shell as comma-separated list
--csv > /path/to/file.csv       - output to CSV file
--il FILENAME (without .txt)    - provide a server-list filename
                                  (must exist in the instance-lists folder)
--i JSS_URL                     - perform action on a single instance
                                  (must exist in the relevant instance list)
--all                           - perform action on ALL instances in the instance list
-v                              - add verbose curl output
                  
USAGE
}

get_healthcheck() {
    # determine jss_url
    jss_url="${jss_instance}"
    # send request
    curl_url="$jss_url/healthCheck.html"
    curl -s "$curl_url" -o "$curl_output_file"
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
        -c|--csv)
            shift
            output_csv="$1"
        ;;
        -o|--output)
            shift
            output_file="$1"
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
    output_file="/tmp/jamf-healthcheck.txt"
fi
if [[ ! $csv ]]; then
    output_csv="/tmp/jamf-healthcheck.csv"
fi

# ensure the directories can be written to, and empty the files
mkdir -p "$(dirname "$output_file")"
echo "" > "$output_file"
mkdir -p "$(dirname "$output_csv")"
echo "" > "$output_csv"

# Set default instance list
default_instance_list_file="instance-lists/default-instance-list.txt"
[[ -f "$default_instance_list_file" ]] && default_instance_list=$(cat "$default_instance_list_file") || default_instance_list="prd"

# select the instances that will be checked
choose_destination_instances

# heading for csv
echo "Context,Healthcheck" >> "$output_csv"
# heading for text file
(
    echo "-------------------------------------------------------------------------------------"
    printf "%-50s %+34s\n" "Jamf Pro Healthcheck" "$(date)"
    echo "-------------------------------------------------------------------------------------"
    printf "%-50s %+34s\n" "Context" "Healthcheck"
    echo "-------------------------------------------------------------------------------------"
) >> "$output_file"

echo
echo "Building List..."
echo

instance_count=0
healthy_count=0
unhealthy_count=0
for jss_instance in "${instance_choice_array[@]}"; do
    ((instance_count++))
    get_healthcheck
    check=$(cat "$curl_output_file")
    if [[ $check == "[]" ]]; then 
        check="Healthy"
        ((healthy_count++))
    elif [[ $check == *"503 Server Unavailable"* ]]; then 
        check="503 Server Unavailable"
        ((unhealthy_count++))
    elif [[ $check == *"Access Denied"* ]]; then
        check="Instance not found/access denied"
        ((unhealthy_count++))
    else
        ((unhealthy_count++))
    fi

    # format for text file
    printf "%-50s %+34s\n" "$jss_instance" "$check" >> "$output_file"
    # format for csv
    echo "$jss_instance,$check" >> "$output_csv"
done

# summary for csv
# echo "Sum of $instance_count contexts,$healthy_count,$unhealthy_count" >> "$output_csv"

# summary for text file
(
    echo "-------------------------------------------------------------------------------------"
    printf "Total Contexts: %-20s %+32s %+15s\n" \
    "$instance_count" "Healthy: $healthy_count" "Unhealthy: $unhealthy_count"
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