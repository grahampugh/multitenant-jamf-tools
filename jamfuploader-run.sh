#!/bin/bash

# --------------------------------------------------------------------------------
# A wrapper script for running the jamf-upload.sh script
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="mac"

# define autopkg_prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

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
    echo "

# JamfUploader-Run
A script for uploading items to a Jamf Pro instance using the AutoPkg framework and JamfUploader processors, without having to write AutoPkg recipes. 

# Requirements
- AutoPkg must be installed and configured
- JamfUploader processors must be available (e.g. by running 'autopkg repo-add grahampugh/jamf-upload')
- Credentials for the Jamf Pro instance must be set in the AutoPkg preferences or in the Keychain (the script will prompt you to run the set_credentials.sh script if not found)
- The jamf-upload.sh script must be available (the script will look for it in ~/Library/AutoPkg/RecipeRepos/com.github.grahampugh.jamf-upload/jamf-upload.sh or in ../jamf-upload/jamf-upload.sh)

# Usage
UPLOADTYPE                       - type of upload (e.g. pkg, policy, script, etc. 
                                   Exactly one value must be provided)
-il | --instance-list FILENAME   - provide an instance list filename (without .txt)
                                   (must exist in the instance-lists folder)
-i | --instance JSS_URL          - perform action on a specific instance
                                   (must exist in the relevant instance list)
                                   (multiple values can be provided)
-a | -ai | --all-instances       - perform action on ALL instances in the instance list
-x | --nointeraction             - run without checking instance is in an instance list 
                                   (prevents interactive mode)
--dp                             - filter fileshare distribution points on DP name
--prefs <path>                   - Inherit AutoPkg prefs file provided by the full path to the file
-v[vvv]                          - Set value of verbosity (default is -v)
-q                               - Quiet mode (verbosity 0)
-j <path>                        - Alternative path to jamf-upload.sh script 
                                   (default is ~/Library/AutoPkg/RecipeRepos/
                                   com.github.grahampugh.jamf-upload/jamf-upload.sh)
                                   (if not found, will look in ../jamf-upload/jamf-upload.sh)
-h | --help                      - Show this help message
--[args]                         - Pass through required arguments for jamf-upload.sh. 
                                   Scroll up for a full list of valid arguments.

# Notes
Credentials set in the AutoPkg preferences file will be used if they exist. If not, the keychain will be used. If there is no keychain entry, the script will prompt for you to run the set_credentials.sh script.

The --dp argument can be bypassed by setting the environment variable 'dp_url_filter' to the desired value in the AutoPkg preferences.
"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

if [[ ! -f "$jamf_upload_path" ]]; then
    # default path to jamf-upload.sh
    jamf_upload_path="$HOME/Library/AutoPkg/RecipeRepos/com.github.grahampugh.jamf-upload/jamf-upload.sh"
fi
# ensure the path exists, revert to defaults otherwise
if [[ ! -f "$jamf_upload_path" ]]; then
    cd "$(dirname "${BASH_SOURCE[0]}")" || exit
    jamf_upload_path="../jamf-upload/jamf-upload.sh"
fi

# get command line args
args=()
chosen_instances=()
while test $# -gt 0 ; do
    case "$1" in
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
        -x|--nointeraction)
            no_interaction=1
            ;;
        -s|--share)
            shift
            smb_url="$1"
            ;;
        -d|--dp)
            shift
            dp_url_filter="$1"
            ;;
        -j|--jamf-upload-path)
            shift
            jamf_upload_path="$1"
            if [[ ! -f "$jamf_upload_path" ]]; then
                echo "ERROR: jamf-upload.sh not found. Please either run 'autopkg repo-add grahampugh/jamf-upload' or clone the grahampugh/jamf-upload repo to the parent folder of this repo"
                exit 1
            fi
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
            echo "Outputting the help sheet for jamf-upload.sh"
            echo
            echo "==========================================="
            echo
            "$jamf_upload_path" --help
            echo
            echo "==========================================="
            echo
            usage
            exit 0
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift
done
echo

# fail if no valid path found
if [[ ! -f "$jamf_upload_path" ]]; then
    echo "ERROR: jamf-upload.sh not found. Please either run 'autopkg repo-add grahampugh/jamf-upload' or clone the grahampugh/jamf-upload repo to the parent folder of this repo"
    exit 1
fi

if [[ ! $verbosity_mode && ! $quiet_mode ]]; then
    # default verbosity
    args+=("-v")
elif [[ ! $quiet_mode ]]; then
    args+=("$verbosity_mode")
fi

echo "This script will run grahampugh/jamf-upload/jamf-upload.sh on the instance(s) you choose."

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# run on specified instances
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    set_credentials "$jss_instance"
    echo "Running on $jss_instance..."
    echo "jamf-upload.sh ${args[*]}"
    run_jamfupload
done

echo 
echo "Finished"
echo
