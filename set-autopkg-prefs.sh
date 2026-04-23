#!/bin/bash

# --------------------------------------------------------------------------------
# A script for adding the correct JSS_URL to autopkg
# This is to allow use of AutoPkgr or other AutoPkg runners without maunally editing the prefs.
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="ios"

# define autopkg_prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

# define autopkg binary
autopkg_binary="/usr/local/bin/autopkg"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

# Check if the script directory is set
if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# check for autopkg
if [[ ! -f "$autopkg_binary" ]]; then
    echo "ERROR: AutoPkg is not installed on this device"
    exit 1
fi

# ensure pillow module is installed, this is required for recipes that use IconGenerator
if ! /usr/local/autopkg/python -m pip show pillow &>/dev/null; then
    echo "Installing Pillow module..."
    /usr/local/autopkg/python -m pip install --upgrade pillow
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'

# Set-AutoPkg-Prefs
A script for running AutoPkg recipes on one or more Jamf Pro instances.

# Requirements
- AutoPkg must be installed and configured
- Credentials for the Jamf Pro instance(s) must be set in the AutoPkg preferences or in the Keychain (the script will prompt you to run the set_credentials.sh script if not found)

Usage:
./set_credentials.sh               - set the Keychain credentials

-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - perform action on a specific instance
                                     (must exist in the relevant instance list)
                                     (multiple values can be provided)
-x | --nointeraction               - run without checking instance is in an instance list 
                                     (prevents interactive choosing of instances)
-v[vvv]                            - add verbose output
USAGE
}

update_autopkg_prefs() {

    /usr/bin/defaults write "$autopkg_prefs" JSS_URL -string "$jss_instance"

}


# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
args=()
chosen_instances=()
recipes=()
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
        -a|-ai|--all|--all-instances)
            all_instances=1
            ;;
        --id|--client-id|--user|--username)
            shift
            chosen_id="$1"
        ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        --prefs)
            shift
            autopkg_prefs="$1"
            if [[ ! -f "$autopkg_prefs" ]]; then
                echo "ERROR: prefs file not found"
                exit 1
            fi
            ;;
        -q)
            quiet_mode="yes"
            ;;
        -v*)
            verbosity_mode="$1"
            ;;
        -h|--help)
            usage
            exit
            ;;
        *)
            args+=("$1")
            ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if [[ ! $verbosity_mode && ! $quiet_mode ]]; then
    # default verbosity
    verbosity_mode="-v"
elif [[ $verbosity_mode == "-vvvvv"* ]]; then
    verbosity_mode="-vvvv"
elif [[ $quiet_mode ]]; then
    verbosity_mode=""
fi

# Ask for the instance list, show list, ask to apply to one, multiple or all

echo
echo "This script will set the autopkg prefs to the instance you choose."

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "ERROR: multiple instances cannot be specified in this script."
    exit 1
fi

# select the instances that will be changed
choose_destination_instances

# run on specified instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    echo "Setting URL in AutoPkg prefs to $jss_instance..."
    update_autopkg_prefs
done

echo 
echo "Finished"
echo
