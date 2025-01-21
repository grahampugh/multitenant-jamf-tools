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

###############
## FUNCTIONS ##
###############

element_in() {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

run_jamfupload() {
    instance_args=()
    
    # specify the URL
    instance_args+=("--url")
    instance_args+=("$jss_instance")

    # add the credentials
    instance_args+=("--user")
    instance_args+=("$jss_api_user")
    instance_args+=("--pass")
    instance_args+=("$jss_api_password")

    # determine the share
    if element_in "pkg" "${args[@]}" || element_in "package" "${args[@]}"; then
        get_instance_distribution_point
        if [[ "$smb_url" ]]; then
            # get the smb credentials from the keychain
            get_smb_credentials

            instance_args+=("--smb-url")
            instance_args+=("$smb_url")
            instance_args+=("--smb-user")
            instance_args+=("$smb_user")
            instance_args+=("--smb-pass")
            instance_args+=("$smb_pass")
        fi
    fi

    # Run the script and output to stdout
    # echo "$jamf_upload_path" "${args[@]}" "${instance_args[@]}" # TEMP
    "$jamf_upload_path" "${args[@]}" "${instance_args[@]}" 

    # Send Slack notification
    slack_text="{'username': '$jss_url', 'text': '*jamfuploader_run.sh*\nUser: $jss_api_user\nInstance: $jss_url\nArguments: ${args[*]}'}"
    send_slack_notification "$slack_text"
}


##############
## DEFAULTS ##
##############

if [[ ! -f "$jamf_upload_path" ]]; then
    # default path to jamf-upload-sh
    jamf_upload_path="$HOME/Library/AutoPkg/RecipeRepos/com.github.grahampugh.jamf-upload/jamf-upload.sh"
fi
# ensure the path exists, revert to defaults otherwise
if [[ ! -f "$jamf_upload_path" ]]; then
    jamf_upload_path="../jamf-upload/jamf-upload.sh"
fi
# fail if no valid path found
if [[ ! -f "$jamf_upload_path" ]]; then
    echo "ERROR: jamf-upload.sh not found. Please either run 'autopkg repo-add grahampugh/jamf-upload' or clone the grahampugh/jamf-upload repo to the parent folder of this repo"
    exit 1
fi


###############
## ARGUMENTS ##
###############

args=()

while test $# -gt 0 ; do
    case "$1" in
        -il|--instance-list)
            shift
            instance_list_file="$1"
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
            jamf_upload_path="../jamf-upload/jamf-upload.sh"
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

if [[ ! $verbosity_mode && ! $quiet_mode ]]; then
    # default verbosity
    args+=("-v")
elif [[ ! $quiet_mode ]]; then
    args+=("$verbosity_mode")
fi

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
    set_credentials "$jss_instance"
    echo "Running jamf-api-tool on $jss_instance..."
    run_jamfupload
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        set_credentials "$jss_instance"
        echo "Running jamf-api-tool on $jss_instance..."
        run_jamfupload
    done
fi

echo 
echo "Finished"
echo


echo 

