#!/bin/bash

: <<'DOC'
Script for setting account preferences on all instances
DOC

# source the get-token.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "get-token.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
--il FILENAME (without .txt)  - provide an instance list filename
                                (must exist in the instance-lists folder)
--i JSS_URL                   - perform action on a single instance
                                (must exist in the relevant instance list)
--timezone                    - Set timezone (e.g. Europe/London)
--date-format                 - Set date format (e.g. yyyy/MM/dd)
--all                         - perform action on ALL instances in the instance list
-v                            - add verbose curl output
USAGE
}

set_prefs() {
    # set all the values here. 
    # Note that there is a bug with computerPeripheralSearchMethod so that cannot be altered

    if [[ ! $timezone ]]; then
        timezone="Europe/Berlin"
    fi
    if [[ ! $dateformat ]]; then
        dateformat="yyyy/MM/dd"
    fi

    data='{
  "language" : "en",
  "dateFormat" : "'$dateformat'",
  "timezone" : "'$timezone'",
  "disableRelativeDates" : false,
  "disablePageLeaveCheck" : false,
  "disableShortcutsTooltips" : false,
  "disableTablePagination" : false,
  "configProfilesSortingMethod" : "ALPHABETICALLY",
  "resultsPerPage" : 100,
  "userInterfaceDisplayTheme" : "MATCH_SYSTEM",
  "computerSearchMethod" : "CONTAINS",
  "computerApplicationSearchMethod" : "CONTAINS",
  "computerApplicationUsageSearchMethod" : "CONTAINS",
  "computerFontSearchMethod" : "CONTAINS",
  "computerPluginSearchMethod" : "CONTAINS",
  "computerLocalUserAccountSearchMethod" : "CONTAINS",
  "computerSoftwareUpdateSearchMethod" : "CONTAINS",
  "computerPackageReceiptSearchMethod" : "CONTAINS",
  "computerPrinterSearchMethod" : "CONTAINS",
  "computerPeripheralSearchMethod" : "CONTAINS",
  "computerServiceSearchMethod" : "CONTAINS",
  "mobileDeviceSearchMethod" : "CONTAINS",
  "mobileDeviceAppSearchMethod" : "CONTAINS",
  "userSearchMethod" : "CONTAINS",
  "userAllContentSearchMethod" : "CONTAINS",
  "userMobileDeviceAppSearchMethod" : "CONTAINS",
  "userMacAppStoreAppSearchMethod" : "CONTAINS",
  "userEbookSearchMethod" : "CONTAINS"
}'
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    # send request
    curl_url="$jss_url/api/v2/account-preferences"
    curl_args=("--request")
    curl_args+=("PATCH")
    curl_args+=("--header")
    curl_args+=("Content-Type: application/json")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    curl_args+=("--data")
    curl_args+=("$data")
    send_curl_request

    # show output
    cat "$curl_output_file"
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
        -t|--tz|--timezone)
            shift
            timezone="$1"
        ;;
        -d|--date-format)
            shift
            dateformat="$1"
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

# Set default instance list
default_instance_list="prd"

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Setting preferences on $jss_instance..."
    set_prefs
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Setting preferences on $jss_instance..."
        set_prefs
    done
fi

echo 
echo "Finished"
echo
