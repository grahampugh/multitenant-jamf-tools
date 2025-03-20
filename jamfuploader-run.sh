#!/bin/bash

: <<DOC
A wrapper script for running the jamf-upload.sh script
DOC

# source _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

# set instance list type
instance_list_type="mac"

# define autopkg_prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

###########
## USAGE ##
###########

usage() {
    echo "
jamfuploader-run.sh usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
-il FILENAME (without .txt)   - provide an instance list filename
                                (must exist in the instance-lists folder)
-i JSS_URL                    - perform action on a single instance
                                (must exist in the relevant instance list)
-ai | --all-instances         - perform action on ALL instances in the instance list
--dp                          - filter DPs on DP name
--prefs <path>                - Inherit AutoPkg prefs file provided by the full path to the file
-v[vvv]                       - Set value of verbosity (default is -v)
-q                            - Quiet mode (verbosity 0)
--[args]                      - Pass through any arguments for jamf-upload.sh

"
}

##############
## DEFAULTS ##
##############

if [[ ! -f "$jamf_upload_path" ]]; then
    # default path to jamf-upload.sh
    jamf_upload_path="$HOME/Library/AutoPkg/RecipeRepos/com.github.grahampugh.jamf-upload/jamf-upload.sh"
fi
# ensure the path exists, revert to defaults otherwise
if [[ ! -f "$jamf_upload_path" ]]; then
    jamf_upload_path="../jamf-upload/jamf-upload.sh"
fi

###############
## ARGUMENTS ##
###############

args=()

while test $# -gt 0 ; do
    case "$1" in
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
            ;;
        -i|--instance)
            shift
            chosen_instance="$1"
            ;;
        -s|--share)
            shift
            smb_url="$1"
            ;;
        -d|--dp)
            shift
            dp_url_filter="$1"
            ;;
        -ai|--all-instances)
            all_instances=1
            ;;
        -j)
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

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

echo "This script will run grahampugh/jamf-upload/jamf-upload.sh on the instance(s) you choose."

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    set_credentials "$jss_instance"
    echo "Running on $jss_instance..."
    echo "jamf-upload.sh ${args[*]}"
    run_jamfupload
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        set_credentials "$jss_instance"
        echo "Running on $jss_instance..."
        echo "jamf-upload.sh ${args[*]}"
        run_jamfupload
    done
fi

echo 
echo "Finished"
echo


echo 

