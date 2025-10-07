#!/bin/bash

# --------------------------------------------------------------------------------
# A wrapper script for running the jamf_api_tool.py script
#
# Requirements:
# - Python 3 - AutoPkg installation recommended as this includes a python3 distribution(
#   required for other tools in the suite)
# - jamf-api-tool.py - the main script for interacting with the Jamf API
# 
# To obtain jamf-api-tool.py, clone or download the repository from:
# https://github.com/grahampugh/jamf-api-tool
# 
# USAGE:
# This script can be run with no parameters to enter interactive mode, or
# with parameters to run in non-interactive mode.
# 
# See --help for command line options
# --------------------------------------------------------------------------------

# set instance list type
instance_list_type="mac"

# path to the jamf-api-tool repo
tool_directory="../jamf-api-tool"
tool="jamf_api_tool.py"

# paths to preference files
tmp_prefs="${HOME}/Library/Preferences/jamf-api-tool.plist"
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

# output directory
output_dir="/Users/Shared/Jamf/Jamf-API-Tool"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
source "_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    echo "
# jamf-api-tool.sh
# A wrapper script for running the jamf_api_tool.py script
#
# Requirements:
# - Python 3 - AutoPkg installation recommended as this includes a python3 distribution(
#   required for other tools in the suite)
# - jamf-api-tool.py - the main script for interacting with the Jamf API

Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
-il FILENAME (without .txt)   - provide an instance list filename
                                (must exist in the instance-lists folder)
-i JSS_URL                    - perform action on a single instance
                                (must exist in the relevant instance list)
-ai | --all-instances         - perform action on ALL instances in the instance list
--dp                          - filter DPs on DP name
--prefs <path>                - Inherit AutoPkg prefs file provided by the full path to the file
-v[vvv]                       - Set value of verbosity
--confirm                     - Automatically confirm the command (no prompt)
--[args]                      - Pass through any arguments for jamf_api_tool.py

"
}

run_api_tool(){
    instance_args=()
    
    # specify the URL
    instance_args+=("--url")
    instance_args+=("$jss_instance")

    # add the credentials
    instance_args+=("--user")
    instance_args+=("$jss_api_user")
    instance_args+=("--pass")
    instance_args+=("$jss_api_password")

    # set the CSV output location
    instance_args+=("--csv")
    instance_args+=("$output_dir/${jss_instance//https:\/\//}.csv")

    # determine the share
    if [[ "${args[*]}" == *"--packages"* ]]; then
        get_instance_distribution_point
        if [[ "$smb_url" ]]; then
            instance_args+=("--smb_url")
            instance_args+=("$smb_url")
            # we need the new endpoints for the password. For now use the keychain
        if [[ "$dp_server" ]]; then
            get_smb_credentials
            if [[ $smb_url && $smb_user && $smb_pass ]]; then
                echo "Username and password for $dp_server found in keychain - URL=$smb_url"
                # dp_found=1
                pass_rw="$smb_pass"
            fi
        else
            echo "DP not determined. Trying AutoPkg prefs"
            pass_rw=$(defaults read "$autopkg_prefs" SMB_PASSWORD)
            if [[ ! "$pass_rw" ]]; then
                echo "ERROR: DP not determined. Cannot continue"
                exit 1
            fi
        fi
            instance_args+=("--smb_user")
            instance_args+=("$smb_user")
            instance_args+=("--smb_pass")
            instance_args+=("$smb_pass")
        fi
    fi

    # Run the script and output to stdout
    /Library/AutoPkg/Python3/Python.framework/Versions/Current/bin/python3 "$tool_directory/$tool" "${args[@]}" "${instance_args[@]}" 
}

confirm() {
    if [[ ${args[*]} ]]; then
        # confirm

        if [[ $confirmed == "yes" ]]; then
            echo "   [main] Action confirmed from command line"
        else
            echo
            echo "Please confirm that you would like to perform the following command"
            echo "on instance $jss_instance:"
            echo
            echo "   jamf-api-tool.py ${args[*]}"
            echo
            read -r -p "Enter Y/N : " are_you_sure
            case "$are_you_sure" in
                Y|y)
                    echo "   [main] Confirmed"
                ;;
                *)
                    echo "   [main] Cancelled"
                    exit
                ;;
            esac
        fi
    else
        echo "   [main] No actions provided"
        usage
        exit 1
    fi
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# get command line args
args=()
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
        -ai|--all-instances)
            all_instances=1
            ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        -s|--share)
            shift
            smb_share="$1"
        ;;
        -d|--dp)
            shift
            dp_url_filter="$1"
        ;;
        -ai|--all-instances)
            all_instances=1
        ;;
        --confirm)
            confirmed="yes"
            ;;
        --tool-dir)
            shift
            tool_directory="$1"
            # if ~ is supplied in the path, expand it
            tool_directory="${tool_directory/#\~/$HOME}"
            ;;
        -v*)
            args+=("$1")
            ;;
        -h|--help)
            echo "Outputting the help sheet for jamf-api-tool.py"
            echo
            echo "==========================================="
            echo
            /Library/AutoPkg/Python3/Python.framework/Versions/Current/bin/python3 "$tool_directory/$tool" --help
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

# make output directory
/bin/mkdir -p "$output_dir"

# ------------------------------------------------------------------------------------
# Ask for the object type if not supplied in the args
# Valid args are:
# --computers
# --packages
# --policies
# --scripts
# --ea
# --groups / --macosgroups
# --iosgroups
# --macosprofiles
# --iosprofiles
# --acs
# --ads
# ------------------------------------------------------------------------------------

if [[ ! "${args[*]}" == *"--computers"* ]] && \
   [[ ! "${args[*]}" == *"--packages"* ]] && \
   [[ ! "${args[*]}" == *"--policies"* ]] && \
   [[ ! "${args[*]}" == *"--scripts"* ]] && \
   [[ ! "${args[*]}" == *"--ea"* ]] && \
   [[ ! "${args[*]}" == *"--groups"* ]] && \
   [[ ! "${args[*]}" == *"--macosgroups"* ]] && \
   [[ ! "${args[*]}" == *"--iosgroups"* ]] && \
   [[ ! "${args[*]}" == *"--macosprofiles"* ]] && \
   [[ ! "${args[*]}" == *"--iosprofiles"* ]] && \
   [[ ! "${args[*]}" == *"--acs"* ]] && \
   [[ ! "${args[*]}" == *"--ads"* ]]; then
    echo "Please choose the object type to be processed:"
    echo "1) Computers"
    echo "2) Packages"
    echo "3) Policies"
    echo "4) Scripts"
    echo "5) Extension Attributes"
    echo "6) Groups (Mac)"
    echo "7) Groups (iOS)"
    echo "8) Configuration Profiles (Mac)"
    echo "9) Configuration Profiles (iOS)"
    echo "10) Advanced Searches (Mac)"
    echo "11) Advanced Searches (iOS)"
    read -r -p "(1-11): " object_type
    case "$object_type" in
        1)
            args+=("--computers")
            ;;
        2)
            args+=("--packages")
            ;;
        3)
            args+=("--policies")
            ;;
        4)
            args+=("--scripts")
            ;;
        5)
            args+=("--ea")
            ;;
        6)
            args+=("--macosgroups")
            ;;
        7)
            args+=("--iosgroups")
            ;;
        8)
            args+=("--macosprofiles")
            ;;
        9)
            args+=("--iosprofiles")
            ;;
        10)
            args+=("--acs")
            ;;
        11)
            args+=("--ads")
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
    echo
fi

# ------------------------------------------------------------------------------------
# If packages, and valid options not supplied at the command line,
# ask which option is needed
# ------------------------------------------------------------------------------------

if [[ "${args[*]}" == *"--packages"* ]]; then
    if [[ ! "${args[*]}" == *"--all"* ]] && \
       [[ ! "${args[*]}" == *"--unused"* ]] && \
       [[ ! "${args[*]}" == *"--search"* ]] && \
       [[ ! "${args[*]}" == *"--from_csv"* ]]; then
        echo "Please choose the action to be performed on Packages:"
        echo "1) List all packages"
        echo "2) List all packages with additional details"
        echo "3) List unused packages"
        echo "4) List and delete unused packages"
        echo "5) Search packages by name"
        echo "6) Search and delete packages by name"
        echo "7) Delete packages from a CSV"
        read -r -p "(1-7): " action
        case "$action" in
            1)
                args+=("--all")
                if [[ "${args[*]}" == *"--details"* ]]; then
                    echo "   [main] Warning: --details option supplied at command line will be ignored"
                    args=("${args[@]/--details}")
                fi
                ;;
            2)
                args+=("--all")
                if [[ ! "${args[*]}" == *"--details"* ]]; then
                    args+=("--details")
                fi
                ;;
            3)
                args+=("--unused")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            4)
                args+=("--unused")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            5)
                args+=("--search")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            6)
                args+=("--search")
                read -r -p "Enter search string: " search_string
                args+=("$search_string")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            7)
                args+=("--from_csv")
                read -r -p "Enter the full path to the CSV file: " csv_path
                args+=("$csv_path")
                if [[ ! -f "$csv_path" ]]; then
                    echo "   [main] Error: $csv_path not found. Exiting."
                    exit 1
                fi
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
        echo
    fi
elif [[ "${args[*]}" == *"--policies"* ]]; then
    if [[ ! "${args[*]}" == *"--all"* ]] && \
       [[ ! "${args[*]}" == *"--unused"* ]] && \
       [[ ! "${args[*]}" == *"--search"* ]] && \
       [[ ! "${args[*]}" == *"--category"* ]] && \
       [[ ! "${args[*]}" == *"--from_csv"* ]]; then
        echo "Please choose the action to be performed on Policies:"
        echo "1) List all policies"
        echo "2) List disabled policies"
        echo "3) List and delete disabled policies"
        echo "4) List unused policies"
        echo "5) List and delete unused policies"
        echo "6) List policies in a defined category"
        echo "7) List and delete policies in a defined category"
        echo "8) Search policies by name"
        echo "9) Search and delete policies by name"
        echo "10) Delete policies from a CSV"
        read -r -p "(1-10): " action
        case "$action" in
            1)
                args+=("--all")
                if [[ "${args[*]}" == *"--details"* ]]; then
                    echo "   [main] Warning: --details option supplied at command line will be ignored"
                    args=("${args[@]/--details}")
                fi
                ;;
            2)
                args+=("--disabled")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            3)
                args+=("--disabled")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            4)
                args+=("--unused")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            5)
                args+=("--unused")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            6)
                args+=("--category")
                read -r -p "Enter category name: " category_name
                args+=("$category_name")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            7)
                args+=("--category")
                read -r -p "Enter category name: " category_name
                args+=("$category_name")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            8)
                args+=("--search")
                read -r -p "Enter search string: " search_string
                args+=("$search_string")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            9)
                args+=("--search")
                read -r -p "Enter search string: " search_string
                args+=("$search_string")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            10)
                args+=("--from_csv")
                read -r -p "Enter the full path to the CSV file: " csv_path
                args+=("$csv_path")
                if [[ ! -f "$csv_path" ]]; then
                    echo "   [main] Error: $csv_path not found. Exiting."
                    exit 1
                fi
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
        echo
    fi
elif [[ "${args[*]}" == *"--macosprofiles"* || "${args[*]}" == *"--iosprofiles"* || "${args[*]}" == *"--scripts"* || "${args[*]}" == *"--ea"* || "${args[*]}" == *"--groups"* || "${args[*]}" == *"--macosgroups"* || "${args[*]}" == *"--iosgroups"* || "${args[*]}" == *"--acs"* || "${args[*]}" == *"--ads"* ]]; then
    if [[ ! "${args[*]}" == *"--all"* ]] && \
       [[ ! "${args[*]}" == *"--unused"* ]]; then
        echo "Please choose the action to be performed on objects:"
        echo "1) List all objects"
        echo "2) List all objects with additional details"
        echo "3) List unused objects"
        echo "4) List and delete unused objects"
        read -r -p "(1-4): " action
        case "$action" in
            1)
                args+=("--all")
                if [[ "${args[*]}" == *"--details"* ]]; then
                    echo "   [main] Warning: --details option supplied at command line will be ignored"
                    args=("${args[@]/--details}")
                fi
                ;;
            2)
                args+=("--all")
                if [[ ! "${args[*]}" == *"--details"* ]]; then
                    args+=("--details")
                fi
                ;;
            3)
                args+=("--unused")
                if [[ "${args[*]}" == *"--delete"* ]]; then
                    echo "   [main] Warning: --delete option supplied at command line will be ignored"
                    args=("${args[@]/--delete}")
                fi
                ;;
            4)
                args+=("--unused")
                if [[ ! "${args[*]}" == *"--delete"* ]]; then
                    args+=("--delete")
                fi
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
        echo
    fi
elif [[ "${args[*]}" == *"--computers"* ]]; then
    if [[ ! "${args[*]}" == *"--all"* ]] && \
       [[ ! "${args[*]}" == *"--search"* ]]; then
        echo "Please choose the action to be performed on Computers:"
        echo "1) List all computers"
        echo "2) List all computers with compliance details"
        echo "3) Search computers by name"
        read -r -p "(1-3): " action
        case "$action" in
            1)
                args+=("--all")
                if [[ "${args[*]}" == *"--details"* ]]; then
                    echo "   [main] Warning: --details option supplied at command line will be ignored"
                    args=("${args[@]/--details}")
                fi
                ;;
            2)
                args+=("--all")
                if [[ ! "${args[*]}" == *"--os"* ]]; then
                    args+=("--os")
                    read -r -p "Enter minimum macOS version: " min_os
                    args+=("$min_os")
                fi
                ;;
            3)
                args+=("--search")
                read -r -p "Enter search string: " search_string
                args+=("$search_string")
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
        echo
    fi
fi

# ------------------------------------------------------------------------------------
# Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

# get Slack webhook
if get_slack_webhook "$instance_list_file"; then
    if [[ $slack_webhook_url ]]; then
        args+=("--slack")
        args+=("--slack_webhook")
        args+=("$slack_webhook_url")
    fi
fi

# loop through the chosen instances and run the jamf-api-tool.py script
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    # confirm if --delete in the args
    if [[ "${args[*]}" == *"--delete"* ]]; then
        confirm
    fi
    set_credentials "$jss_instance"
    echo "Running jamf-api-tool.py ${args[*]} on $jss_instance..."
    run_api_tool
done

echo 
echo "Finished"
echo
