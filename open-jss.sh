#!/bin/bash

: <<'DOC'
Script for opening the JSS web console in a browser
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# set instance list type
instance_list_type="ios"

# don't strip failovers
strip_failover="no"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
-a                            - select browser to open the JSS in (interactively)
-v                            - add verbose curl output
USAGE
}

list_browsers() {
    # list the browsers available

    # default browser
    default_browser_idenfitier=$(plutil -p ~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist | grep 'https' -b3 |awk 'NR==3 {split($4, arr, "\""); print arr[2]}')
    default_browser=$(mdfind "kMDItemCFBundleIdentifier == $default_browser_idenfitier" | grep -e "^/Applications/" | grep -iv "dropbox" | head -n 1)

    # check for browsers using mdfind
    browser_list=()
    while IFS='' read -r line; do 
        browser_list+=("$line")
    done < <(mdfind "kMDItemKind == 'Application'" | grep -i "safari\|chrome\|firefox\|opera\|brave\|edge" | grep -e "^/Applications/" | grep -iv "dropbox" | sort)
    
    echo "Available browsers:"
    echo
    item=0
    for browser in "${browser_list[@]}"; do
        printf '   %-7s %-30s\n' "($item)" "$browser"
        if [[ "$browser" == "$default_browser" ]]; then
            default_browser_number=$item
        fi
        ((item++))
    done
    echo
    browser_selection=""
    if [[ $select_browser ]]; then
        echo "Enter the number of the browser to use,"
        echo "   or leave blank to select [$default_browser_number] $default_browser:"
        read -r -p "Enter the number of the browser to use : " browser_selection
    fi
    if [[ "$browser_selection" ]]; then
        browser_selected="${browser_list[browser_selection]}"
        echo "Selected browser: $browser_selected"
    else
        browser_selected="${browser_list[$default_browser_number]}"
    fi
}

open_jss() {
    echo  # weirdly, Safari crashes without this line
    sleep 0.1
    open -a "$browser_selected" "$jss_instance"
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
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        -v|--verbose)
            verbose=1
        ;;
        -a|--application)
            select_browser=1
        ;;
        -h|--help)
            usage
            exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# select the instances that will be changed
choose_destination_instances

# list browsers
list_browsers

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Opening $jss_instance in $browser_selected..."
    open_jss
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Opening $jss_instance in $browser_selected..."
        open_jss
    done
fi

echo 
echo "Finished"
echo
