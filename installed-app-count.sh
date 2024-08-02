#!/bin/bash

: <<DOC 
Script for counting applications installed on computers in all instances
This interrogates the inventory, not smart groups
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# set instance list type
instance_list_type="mac"

# prepare working directory
workdir="/Users/Shared/Jamf/InstallAppsCount"
mkdir -p "$workdir"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh prd                     - set the Keychain credentials

[no arguments]                  - interactive mode
[APPNAME]                       - show count of computers with app installed
-t                              - show count of computers (total only, no instance data)
--versions                      - show count of computers with app installed with version info
--versions=10                   - show count of computers with app installed with version info
                                  (restrict to versions with more than 10% of total)
--il FILENAME (without .txt)    - provide a server-list filename
                                  (must exist in the instance-lists folder)
--i JSS_URL                    - perform action on a single instance
                                  (must exist in the relevant instance list)
--all                           - perform action on ALL instances in the instance list
-v                              - add verbose curl output
                  
Note:
If APPNAME is set to "macOS", Migration Assistant will be searched, which corresponds exactly to the macOS minor version.
USAGE
}

encode_name() {
    app_name_encoded="$( echo "$1" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"
}

do_the_counting() {
    set_credentials "$jss_instance"
    jss_url="$jss_instance"

    # send request to get each version
    curl_url="$jss_url/JSSResource/computerapplications/application/${app_name_encoded}*"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # temp dump to file
    working_file="$workdir/${app_name_capitalised} - Working.xml"
    /usr/bin/xmllint --format "$curl_output_file" > "$working_file"

    # get version information
    if [[ $get_versions ]]; then
        versions_list=$(/usr/bin/xmllint --xpath '//versions/version/number' "$working_file" 2>/dev/null | sed 's|<number>||g' | sed 's|<\/number>| |g' | sed 's| $||')
        versions=()
        while read -r line ; do
            versions+=("$line")
        done <<< "$versions_list"

        versions_counts=()
        for ver in "${versions[@]}"; do
            version_count=$(/usr/bin/xmllint --xpath "//versions/version[number='$ver']/computers/computer/id" "$working_file" 2>/dev/null | sed 's|<id>||g' | sed 's|<\/id>| |g' | sed 's| $||'  | wc -w | sed -e 's/^[[:space:]]*//')
            # echo "Version Count: $version_count"  # TEMP
            versions_counts+=("$ver,$version_count")
            n=0
            found=0
            for pair in "${summary_versions_counts[@]}"; do
                summary_version=${pair%,*}
                summary_count=${pair#*,}
                if [[ "$ver" == "$summary_version" ]]; then
                    new_count=$((summary_count+version_count))
                    summary_versions_counts[$n]="$summary_version,$new_count"
                    found=1
                fi
                (( n++ ))
            done
            if [[ $found -eq 0 ]]; then
                summary_versions_counts+=("$ver,$version_count")
            fi
        done
        # echo "Version counts: ${versions_counts[*]}" # TEMP
    fi

    # get the number of computers in this instance
    instance_computers=$( /usr/bin/xmllint --xpath '//unique_computers' "$working_file" 2>/dev/null | /usr/bin/xmllint --format - 2>/dev/null )
    computers=0
    while read -r line ; do
        if grep -q "<udid>" <<< "$line"; then
            computers=$((computers + 1))
        fi
    done <<< "$instance_computers"

    if [[ $total_only != "yes" ]]; then
        instance_pretty=$(echo "$jss_instance" | rev | cut -d"/" -f1 | rev )
        printf "%-54s %+4s\n" "$instance_pretty" "$computers" >> "$output_file"
        if [[ $get_versions ]]; then
            if [[ $version_restriction =~ ^[-+]?[0-9]+$ ]]; then 
                cutoff=$version_restriction
            else 
                cutoff=0
            fi
            # print count of each version
            for pair in "${versions_counts[@]}"; do
                version=${pair%,*}
                version_count=${pair#*,}
                if [[ "$version_count" -gt 0 ]]; then
                    version_percent=$(( version_count * 100 / computers ))
                    if [[ $version_percent -gt $cutoff ]]; then
                        printf '   %-15s %-3s %s%%\n' "$version" "$version_count" "$version_percent" >> "$output_file"
                    fi
                fi
            done
            echo
        fi
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
        -t|--total)
            total_only="yes"
        ;;
        --versions)
            get_versions="yes"
        ;;
        --versions=*)
            get_versions="yes"
            version_restriction="${key#*=}"
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
            app_name="$1"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# Set default instance list
default_instance_list="prd"

# set app name
os=0
if [[ $app_name == "macOS" ]]; then
    os=1
    app_name="Migration Assistant"
elif [[ ! $app_name ]]; then
    read -r -p "Enter an application name : " app_name
    echo
    if [[ $app_name == "macOS" ]]; then
        os=1
        app_name="Migration Assistant"
    fi
fi

# encode the app name - returns $app_name_encoded
encode_name "$app_name"

# app name with capitals
if [[ $os == 1 ]]; then
    app_name_capitalised="macOS"
else
    app_name_capitalised=$(awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1)) substr($i,2) }}1' <<< "$app_name")
fi

# set default output file
if [[ ! $output_file ]]; then
    output_file="$workdir/$app_name_capitalised - Result.txt"
fi

# ensure the directories can be written to, and empty the files
mkdir -p "$(dirname "$output_file")"
echo "" > "$output_file"

# select the instances that will be checked
choose_destination_instances

(
    echo "Timestamp: $( date )"
    echo "-----------------------------------------------------------"
    echo "Jamf Pro App Count - $app_name_capitalised"
    echo "-----------------------------------------------------------"
    echo "Context ($instance_list_file)                                         Count"
    echo "-----------------------------------------------------------"
) > "$output_file"

# set up the summary arrays
summary_versions_counts=()

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    get_versions="yes"
    do_the_counting "$app_name" 
else
    for instance in "${instances_list[@]}"; do
        jss_instance="$instance"
        do_the_counting "$app_name"
    done
fi

if [[ ! $chosen_instance ]]; then
    (
        echo "-----------------------------------------------------------"
        printf "Total contexts: %-38s %+4s\n" "${#instances_list[@]}" "$total_computers"
        echo "-----------------------------------------------------------"
    ) >> "$output_file"
fi

# summary of all the versions
if [[ $get_versions ]]; then
    (
        echo "Summary of versions:"
        echo "-----------------------------------------------------------"
    ) >> "$output_file"

    # sort the array
    IFS=$'\n' sorted_summary_versions_counts=($(sort <<<"${summary_versions_counts[*]}"))
    unset IFS

    # print count of each version
    for pair in "${sorted_summary_versions_counts[@]}"; do
        version=${pair%,*}
        version_count=${pair#*,}
        if [[ "$version_count" -gt 0 ]]; then
            version_percent=$(( version_count * 100 / total_computers ))
            if [[ $version_percent -gt $cutoff ]]; then
                printf '   %-15s %-3s %s%%\n' "$version" "$version_count" "$version_percent" >> "$output_file"
            fi
        fi
    done
    (
        echo "-----------------------------------------------------------"
        echo
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