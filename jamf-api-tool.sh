#!/bin/bash

: <<DOC
A wrapper script for running the jamf_api_tool.py script
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "_common-framework.sh"

# set instance list type
instance_list_type="mac"

###########
## USAGE ##
###########

usage() {
    echo "
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
--[args]                      - Pass through any arguments for jamf_api_tool.py

"
}

###############
## FUNCTIONS ##
###############

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
            if [[ "$dp" ]]; then
                echo "   [check_for_smb_repo] Checking credentials for '$dp'."
                # check for existing service entry in login keychain
                dp_check=$(/usr/bin/security find-generic-password -s "$dp" 2>/dev/null)
                if [[ $dp_check ]]; then
                    # echo "   [check_for_smb_repo] Checking keychain entry for $dp_check" # TEMP
                    smb_url=$(/usr/bin/grep "0x00000007" <<< "$dp_check" 2>&1 | /usr/bin/cut -d \" -f 2 |/usr/bin/cut -d " " -f 1)
                    if [[ $smb_url ]]; then
                        # echo "   [check_for_smb_repo] Checking $smb_url" # TEMP
                        smb_user=$(/usr/bin/grep "acct" <<< "$dp_check" | /usr/bin/cut -d \" -f 4)
                        smb_pass=$(/usr/bin/security find-generic-password -s "$dp" -w -g 2>/dev/null)
                    fi
                fi
            else
                echo "ERROR: DP not determined. Cannot continue"
                exit 1
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
            echo "jamf-api-tool.py ${args[*]}"
            read -r -p "(Y/N) : " are_you_sure
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


##############
## DEFAULTS ##
##############

# source the _common-framework.sh file
# this folder
tool_directory="../jamf-api-tool"
tool="jamf_api_tool.py"
tmp_prefs="${HOME}/Library/Preferences/jamf-api-tool.plist"
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"
output_dir="/Users/Shared/Jamf/Jamf-API-Tool"


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
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# Set default instance list
default_instance_list="prd"

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    confirm
    set_credentials "$jss_instance"
    echo "Running jamf-api-tool.py ${args[*]} on $jss_instance..."
    run_api_tool
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        confirm
        set_credentials "$jss_instance"
        echo "Running jamf-api-tool.py ${args[*]} on $jss_instance..."
        run_api_tool
    done
fi

echo 
echo "Finished"
echo
