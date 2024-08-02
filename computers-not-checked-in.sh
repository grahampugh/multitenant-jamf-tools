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
NOTE: This script requires the following Smart Groups to exist on each server checked:

   - "Computer not checked in DAYS days"

Where DAYS is the entered value of DAYS (e.g. 90)

Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
[DAYS] (30/90/180)            - show count of computers not checked in for DAYS days (default 90)
[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--all                         - perform action on ALL instances in the instance list
-v                            - add verbose curl output
USAGE
}

encode_name() {
    group_name_encoded="$( echo "$1" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"
}

do_the_counting() {
    set_credentials "$jss_instance"
    jss_url="$jss_instance"

    # send request to get each version
    curl_url="$jss_url/JSSResource/computergroups/name/${group_name_encoded}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    if [[ $http_response -eq 404 ]]; then
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
            instance_list_file="$1"
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

# Set default server
default_instance_list="prd"

# set default
if [[ $days -ne 30 && $days -ne 90 && $days -ne 180 ]]; then
    read -r -p "Enter 30 or 90 : " days
fi
if [[ $days -ne 30 && $days -ne 90 && $days -ne 180 ]]; then
    days=90
fi
echo

# encode the group name - returns $group_name_encoded
group_name="Computer not checked in $days days"
encode_name "$group_name"

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