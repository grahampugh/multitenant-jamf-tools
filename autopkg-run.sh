#!/bin/bash

: <<'DOC'
Script for running an autopkg recipe or recipe list on all instances
DOC

# source the _common-framework.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="mac"

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh          - set the Keychain credentials

[no arguments]                - interactive mode
-r                            - recipe to run (e.g. Firefox.jamf)
-l                            - recipe-list to run (must be path to a .txt file)
-il FILENAME (without .txt)   - provide an instance list filename
                                (must exist in the instance-lists folder)
-i JSS_URL                    - perform action on a single instance
                                (must exist in the relevant instance list)
--all                         - perform action on ALL instances in the instance list
--dp                          - filter DPs on DP name
-e                            - Force policy to enabled (--key POLICY_ENABLED=True)
-v[vv]                        - add verbose output
--[args]                      - Pass through any arguments for AutoPkg
USAGE
}

run_autopkg() {
    # run an AutoPkg recipe or recipe list. Some options may be added
    autopkg_run_options=()

    # specify the URL
    autopkg_run_options+=("--key")
    autopkg_run_options+=("JSS_URL=$jss_instance")

    # add the credentials
    # autopkg_run_options+=("--key")
    # autopkg_run_options+=("API_USERNAME=$jss_api_user")
    # autopkg_run_options+=("--key")
    # autopkg_run_options+=("API_PASSWORD=$jss_api_password")

    # temporarily clear any API clients in the AutoPkg prefs
    autopkg_run_options+=("--key")
    autopkg_run_options+=("CLIENT_ID=")
    autopkg_run_options+=("--key")
    autopkg_run_options+=("CLIENT_SECRET=")

    # determine the share
    get_instance_distribution_point
    if [[ "$smb_url" ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("SMB_URL=$smb_url")
        autopkg_run_options+=("--key")
        autopkg_run_options+=("SMB_USERNAME=$user_rw")
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
                    if [[ $smb_url == *"(readwrite)"* && $smb_user && $smb_pass ]]; then
                        echo "Username and password for $dp found in keychain - URL=$smb_url"
                        # dp_found=1
                        pass_rw="$smb_pass"
                        return
                    fi
                fi
            fi
        else
            echo "DP not determined. Trying AutoPkg prefs"
            pass_rw=$(defaults read ~/Library/Preferences/com.github.autopkg.plist SMB_PASSWORD)
            if [[ ! "$pass_rw" ]]; then
                echo "ERROR: DP not determined. Cannot continue"
                exit 1
            fi
        fi

    else
        defaults delete ~/Library/Preferences/com.github.autopkg.plist SMB_URL
        # defaults delete ~/Library/Preferences/com.github.autopkg.plist SMB_USERNAME
        # defaults delete ~/Library/Preferences/com.github.autopkg.plist SMB_PASSWORD
        # autopkg_run_options+=("--key")
        # autopkg_run_options+=("jcds2_mode=True")
    fi

    # option to replace pkg
    if [[ $replace_pkg -eq 1 ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("replace_pkg=True")
    fi

    if [[ $policy_enabled -eq 1 ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("POLICY_ENABLED=True")
    fi

    # add additional args
    if [[ ${#args[@]} -gt 0 ]]; then
        autopkg_run_options+=("${args[@]}")
    fi
    
    # verbosity
    case $verbose in
        2) autopkg_verbosity="-vv";;
        3) autopkg_verbosity="-vvv";;
        *) autopkg_verbosity="-v";;
    esac

    # report to Slack
    if get_slack_webhook "$instance_list_file"; then
        if [[ $slack_webhook_url ]]; then
            autopkg_run_options+=(
                "--key"
                "slack_webhook_url=${slack_webhook_url}"
                "--post"
                "com.github.grahampugh.jamf-upload.processors/JamfUploaderSlacker"
            )
        fi
    else
        echo "No Slack webhook found for $instance_list_file"
    fi

    if [[ $recipe_list ]]; then
        "$autopkg_binary" run "$autopkg_verbosity" --recipe-list "$recipe_list" "${autopkg_run_options[@]}"
    elif  [[ $recipe ]]; then
        "$autopkg_binary" run "$autopkg_verbosity" "$recipe" "${autopkg_run_options[@]}"
    else
        echo "ERROR: no recipe or recipe list supplied"
        exit 1
    fi
}


## MAIN BODY

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# check if autopkg is installed, otherwise this won't work
autopkg_binary="/usr/local/bin/autopkg"

if [[ ! -f "$autopkg_binary" ]]; then
    echo "ERROR: AutoPkg is not installed on this device"
    exit 1
fi

# ensure pillow module is installed, this is required for recipes that use IconGenerator
if ! /usr/local/autopkg/python -m pip show pillow &>/dev/null; then
    echo "Installing Pillow module..."
    /usr/local/autopkg/python -m pip install --upgrade pillow
fi

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

# Command line override for the above settings
args=()
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -r|--recipe)
            shift
            recipe="$1"
        ;;
        -l|--recipe-list)
            shift
            recipe_list="$1"
        ;;
        -p|--replace)
            replace_pkg=1
        ;;
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        # -s|--share)
        #     shift
        #     smb_share="$1"
        # ;;
        -d|--dp)
            shift
            dp_url_filter="$1"
        ;;
        -a|--all)
            all_instances=1
        ;;
        -e|--enabled)
            policy_enabled=1
        ;;
        -v)
            verbose=1
        ;;
        -vv)
            verbose=2
        ;;
        -vvv*)
            verbose=3
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

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

echo
echo "This script will run autopkg recipes on the instance(s) you choose."

# select the instances that will be changed
choose_destination_instances

# set recipe
if [[ "$recipe" == "" && "$recipe_list" == "" ]]; then
    printf "Enter Recipe or Recipe List to run (e.g. Firefox.jamf or /path/to/recipes.txt) : "
    read -r recipe_choice
    if [[ $recipe_choice == *".txt" ]]; then
        recipe=""
        recipe_list="$recipe_choice"
    elif [[ $recipe_choice ]]; then
        recipe_list=""
        recipe="$recipe_choice"
    else
        echo "ERROR: no recipe or recipe list supplied"
        exit 1
    fi
fi

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    set_credentials "$jss_instance"
    echo "Running AutoPkg on $jss_instance..."
    run_autopkg
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        set_credentials "$jss_instance"
        echo "Running AutoPkg on $jss_instance..."
        run_autopkg
    done
fi

echo 
echo "Finished"
echo
