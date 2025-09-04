#!/bin/bash

: <<DOC 
Script for counting computers that have not checked in
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="mac"

# prepare working directory
workdir="/Users/Shared/Jamf/ComputersNotCheckedIn"
mkdir -p "$workdir"

usage() {
    cat <<'USAGE'

# Computers Not Checked In Script
A script to count the number of computers that have not checked in for a specified number of days.

NOTE: This script requires the following Smart Groups to exist on each server checked:

   - "Computer not checked in for DAYS days"

Where DAYS is the entered value of DAYS (e.g. 90)

A Computer Group Template is provided for this in the templates folder. The group can be created in all required instances with the following jamfuploader-run.sh command (assuming 7 days):

./jamfuploader-run.sh computergroup --template templates/SmartGroup-LastCheckIn.xml --name "Computer Not Checked in for %DAYS_AGO% Days" --key DAYS_AGO=7

# Usage:
[no arguments]                - interactive mode
[DAYS] (1-180)                - show count of computers not checked in for DAYS days 
                                (default 90)
[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--all                         - perform action on ALL instances in the instance list
-x | --nointeraction          - run without checking instance is in an instance list 
                                (prevents interactive mode)
-v                            - add verbose curl output
USAGE
}

do_the_counting() {
    set_credentials "$jss_instance"
    jss_url="$jss_instance"

    # send request to get each version
    curl_url="$jss_url/JSSResource/computergroups/name/${encoded_group_name}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    if [[ $curl_failed == "true" ]]; then
        echo
        echo "Smart group '$group_name' does not exist on this server"
        computers=0
    else
        # temp dump to file
        working_file="$workdir/${group_name} - Working.xml"
        /usr/bin/xmllint --format "$curl_output_file" > "$working_file"

        # get the number of computers in this instance
        computers=$( /usr/bin/xmllint --xpath '//computers/size/text()' "$working_file" 2>/dev/null)
    fi

    if [[ $total_only != "yes" ]]; then
        instance_pretty=$(echo "$jss_instance" | rev | cut -d"/" -f1 | rev )
        printf "%-54s %+4s\n" "$instance_pretty" "$computers" >> "$output_file"
    fi

    total_computers=$((total_computers + computers))
}

if [[ ! -d "$this_script_dir" ]]; then
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
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        -a|--all)
            all_instances=1
        ;;
        -t|--total)
            total_only="yes"
        ;;
        -o|--output)
            shift
            output_file="$1"
        ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        -v|--verbose)
            verbose=1
        ;;
        -h|--help)
            usage
            exit
        ;;
        *)
            days="$1"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# set default
if [[ ($days -le 0 || $days -gt 180) && -z $no_interaction ]]; then
    read -r -p "Enter a number between 1 and 180 : " days
fi
if [[ $days -le 0 || $days -gt 180 ]]; then
    echo "No valid number entered, using default of 90 days"
    days=90
fi
echo

# encode the group name
group_name="Computer not checked in for $days days"
encoded_group_name=$(encode_name "$group_name")

# set default output file
if [[ ! $output_file ]]; then
    output_file="$workdir/$group_name - Result.txt"
fi

# ensure the directories can be written to, and empty the files
mkdir -p "$(dirname "$output_file")"
echo "" > "$output_file"

# select the instances that will be changed
choose_destination_instances

echo

(
    echo "Timestamp: $( date )"
    echo "-----------------------------------------------------------"
    echo "Jamf Pro Computer Check-in Count - $days days"
    echo "-----------------------------------------------------------"
    echo "Instance ($instance_list_file)                                         Count"
    echo "-----------------------------------------------------------"
) > "$output_file"

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    do_the_counting "$group_name" 
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        do_the_counting "$group_name"
    done
fi

if [[ ! $chosen_instance ]]; then
    (
        echo "-----------------------------------------------------------"
        printf "Total contexts: %-38s %+4s\n" "${#instance_choice_array[@]}" "$total_computers"
        echo "-----------------------------------------------------------"
    ) >> "$output_file"
fi

# now echo the file
echo
echo "Results:"
echo
cat "$output_file"
echo
echo "These results are saved to:"
echo "   Text format: $output_file"
echo