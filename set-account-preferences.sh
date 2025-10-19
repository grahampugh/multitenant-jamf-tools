#!/bin/bash

# --------------------------------------------------------------------------------
# Script for setting account preferences on all instances
# 
# Note: these account preferences reflect the account making the request. Therefore
# it can't be run using an API Client
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "   [main] ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh               - set the Keychain credentials

[no arguments]                     - interactive mode
--il FILENAME (without .txt)       - provide an instance list filename
                                     (must exist in the instance-lists folder)
--i JSS_URL                        - perform action on a single instance
                                     (must exist in the relevant instance list)
--timezone                         - Set timezone (e.g. Europe/London)
--date-format                      - Set date format (e.g. yyyy/MM/dd)
--all                              - perform action on ALL instances in the instance list
--user | --client-id CLIENT_ID     - use the specified client ID or username
-v                                 - add verbose curl output
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
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
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

# -------------------------------------------------------------------------
# MAIN
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
        --id|--client-id|--user|--username)
            shift
            chosen_id="$1"
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

# Ask for the instance list, show list, ask to apply to one, multiple or all
if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# loop through the chosen instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    echo "Setting preferences on $jss_instance..."
    set_prefs
done

echo 
echo "Finished"
echo
