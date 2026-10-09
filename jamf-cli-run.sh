#!/bin/bash

# --------------------------------------------------------------------------------
# A wrapper script for running jamf-cli using credentials saved in the Keychain
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

# Jamf-CLI-Run
A script for performing actions using the Jamf-CLI tool, with credentials saved in the Keychain.

# Requirements
- jamf-cli must be installed, configured, and be in the path
- Credentials for the Jamf Pro instance must be set in the Keychain (the script will prompt you to run the set_credentials.sh script if not found)

# Usage
UPLOADTYPE                         - type of upload (e.g. pkg, policy, script, etc. 
                                     Exactly one value must be provided)
-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - perform action on a specific instance
                                     (must exist in the relevant instance list)
                                     (multiple values can be provided)
-a | -ai | --all-instances         - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list 
                                     (prevents interactive mode)
--user | --client-id CLIENT_ID     - use the specified client ID or username
--prefs <path>                     - Inherit AutoPkg prefs file provided by the full path to the file
-v[vv]                             - Set value of verbosity (default is not verbose)
-j <path>                          - Alternative path to jamf-cli
-h | --help                        - Show this help message
[args]                             - Pass through required arguments for jamf-upload.sh. 

Scroll up for a full list of valid arguments.

# Notes
Credentials set in the AutoPkg preferences file will be used if they exist. If not, the keychain will be used. If there is no keychain entry, the script will prompt for you to run the set_credentials.sh script.
"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

if [[ ! -f "$jamf_cli_path" ]]; then
    # default path to jamf-cli
    jamf_cli_path=$(which jamf-cli)
fi
# ensure the path exists, revert to defaults otherwise
if [[ ! -f "$jamf_upload_path" ]]; then
    cd "$(dirname "${BASH_SOURCE[0]}")" || exit
fi

# get command line args
args=()
chosen_instances=()
while test $# -gt 0; do
    case "$1" in
    -il | --instance-list)
        shift
        chosen_instance_list_file="$1"
        ;;
    -i | --instance)
        shift
        chosen_instances+=("$1")
        ;;
    -a | -ai | --all-instances)
        all_instances=1
        ;;
    --id | --client-id | --user | --username)
        shift
        chosen_id="$1"
        ;;
    -x | --nointeraction)
        no_interaction=1
        ;;
    -j | --jamf-cli-path)
        shift
        jamf_cli_path="$1"
        if [[ ! -f "$jamf_cli_path" ]]; then
            echo "ERROR: jamf-cli not found. Please ensure jamf-cli is installed and the path is correct."
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
    *)
        args+=("$1")
        ;;
    esac
    shift
done
echo

# fail if no valid path found
if [[ ! -f "$jamf_cli_path" ]]; then
    echo "ERROR: jamf-cli not found. Please ensure jamf-cli is installed and the path is correct."
    exit 1
fi

# requires at least one argument to be passed to jamf-cli
if [[ ${#args[@]} -eq 0 ]]; then
    echo "ERROR: No arguments provided. Please provide arguments for jamf-cli."
    usage
    exit 1
fi

# if help, -h or --help is passed, or --profile, or multi, then we bypass the instance selection and run the jamf-cli command with the provided arguments
raw_output=0
for arg in "${args[@]}"; do
    if [[ "$arg" == "help" || "$arg" == "-h" || "$arg" == "--help" || "$arg" == "--profile" || "$arg" == "multi" ]]; then
        raw_output=1
        break
    fi
done

# if help command is passed, output the help sheet for jamf-cli and exit
if [[ $raw_output -eq 1 ]]; then
    "$jamf_cli_path" "${args[@]}"
    exit 0
fi

echo "This script will run jamf-cli on the instance(s) you choose."

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
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    echo "Running on $jss_instance..."
    echo "jamf-cli ${args[*]}"
    run_jamfcli
done

echo
echo "Finished"
echo
