#!/bin/bash

# --------------------------------------------------------------------------------
# Script for opening the JSS web console in a browser
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="ios"

# don't strip failovers
strip_failover="no"

# get current user
current_user=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}')

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
Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
-x | --nointeraction          - run without checking instance is in an instance list 
                                (prevents interactive choosing of instances)
-a                            - select browser to open the JSS in (interactively)
-v                            - add verbose curl output
USAGE
}

list_browsers() {
    # list the browsers available

    # default browser
    default_browser_idenfitier=$(plutil -p "/Users/$current_user/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist" | grep 'https' -b3 | awk 'NR==3 {split($4, arr, "\""); print arr[2]}')
    # fix for Safari bug
    if [[ "$default_browser_idenfitier" == "com.apple.safari" ]]; then
        default_browser_idenfitier="com.apple.Safari"
    fi
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
        if [[ "$(echo "$browser" | tr '[:upper:]' '[:lower:]')" == "$(echo "$default_browser" | tr '[:upper:]' '[:lower:]')" ]]; then
            default_browser_number=$item
        fi
        ((item++))
    done
    echo
    browser_selection=""
    if [[ $select_browser ]]; then
        if [[ "$default_browser_number" ]]; then
            echo "Enter the number of the browser to use,"
            echo "   or leave blank to select [$default_browser_number] $default_browser:"
        fi
        read -r -p "Enter the number of the browser to use : " browser_selection
    fi
    if [[ "$browser_selection" ]]; then
        browser_selected="${browser_list[browser_selection]}"
        echo "Selected browser: $browser_selected"
    else
        browser_selected="${browser_list[$default_browser_number]}"
    fi
}

get_failover_address() {
    # get the failover address for a given instance
    # $1: jss_instance
    local instance
    instance="$1"
    echo "   [get_failover_address] Getting failover address for $instance..."
    # determine jss_url
    set_credentials "$instance"
    jss_url="$instance"
    curl_url="$jss_url/api/v1/sso/failover"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    curl_args=("--request")
    curl_args+=("GET")
    send_curl_request
    failover_address=$(cat "$curl_output_file" | jq -r '.failoverUrl')
    if [[ "$failover_address" == "null" ]] || [[ -z "$failover_address" ]]; then
        failover_address=""
    fi
    export failover_address
}

open_jss() {
    local jss_instance
    jss_instance="$1"
    # open the JSS in the selected browser
    echo  # weirdly, Safari crashes without this line
    sleep 0.1
    open -a "$browser_selected" "$jss_instance"
}

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Get command line args
chosen_instances=()
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
        ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        -i|--instance)
            shift
            chosen_instances+=("$1")
        ;;
        -v|--verbose)
            verbose=1
        ;;
        -f|--failover)
            failover=1
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

# Ask for the instance list, show list, ask to apply to one, multiple or all
if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "   [main] Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "   [main] Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# list browsers
list_browsers

# open each selected instance in the selected browser
for instance in "${instance_choice_array[@]}"; do
    # check if the URL already includes a failover address
    if [[ "$instance" == *"?failover="* ]]; then
        if [[ $verbose -gt 0 ]]; then
            echo "   [main] Instance $instance already includes a failover address."
        fi
        jss_instance="$instance"
    elif [[ $failover ]]; then
        get_failover_address "$instance"
        if [[ "$failover_address" ]]; then
            echo "   [main] Using failover address $failover_address for $instance"
            jss_instance="$failover_address"
        else
            echo "   [main] No failover address set for $instance, using primary address"
            jss_instance="$instance"
        fi
    else
        jss_instance="$instance"
    fi
    echo "   [main] Opening $jss_instance in $browser_selected..."
    open_jss "$jss_instance"
done

echo 
echo "Finished"
echo
