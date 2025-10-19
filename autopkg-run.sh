#!/bin/bash

# --------------------------------------------------------------------------------
# A script for running an autopkg recipe or recipe list on multiple instances
# --------------------------------------------------------------------------------

# set the maximum number of the curl requests to try until success
max_tries_override=2

# set instance list type
instance_list_type="mac"

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

# AutoPkg-Run
A script for running AutoPkg recipes on one or more Jamf Pro instances.

# Requirements
- AutoPkg must be installed and configured
- Credentials for the Jamf Pro instance(s) must be set in the AutoPkg preferences or in the Keychain (the script will prompt you to run the set_credentials.sh script if not found)

Usage:
./set_credentials.sh               - set the Keychain credentials

-r | --recipe RECIPE               - recipe to run (e.g. Firefox.jamf, /path/to/recipe)
                                     (multiple values can be provided)
-l | --recipe-list LIST            - recipe-list to run (must be path to a .txt file)
-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - perform action on a specific instance
                                     (must exist in the relevant instance list)
                                     (multiple values can be provided)
-a | --all | --all-instances       - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list 
                                     (prevents interactive choosing of instances)
--user | --client-id CLIENT_ID     - use the specified client ID or username
--report-plist                     - pass through the report-plist value
--dp                               - filter DPs on DP name
-e | --enabled                     - Force policy to enabled (--key POLICY_ENABLED=True)
-p | --replace                     - Replace existing pkg in Jamf Pro (for pkg uploads)
-v[vv]                             - add verbose output
--[args]                           - Pass through any arguments for AutoPkg
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
        autopkg_run_options+=("--key")
        autopkg_run_options+=("SMB_USERNAME=$smb_user")
        if [[ $pass_rw ]]; then
            autopkg_run_options+=("--key")
            autopkg_run_options+=("SMB_PASSWORD=$pass_rw")
        else
            echo "ERROR: Password not found for $dp_server"
            exit 1
        fi

    else
        defaults delete "$autopkg_prefs" SMB_URL
        # defaults delete "$autopkg_prefs" SMB_USERNAME
        # defaults delete "$autopkg_prefs" SMB_PASSWORD
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

    # option to replace pkg
    if [[ $report_plist ]]; then
        autopkg_run_options+=("--report-plist")
        autopkg_run_options+=("$report_plist")
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
    if [[ "$instance_list_file" ]]; then
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
    fi

    if [[ $recipe_list ]]; then
        "$autopkg_binary" run "$autopkg_verbosity" --recipe-list "$recipe_list" "${autopkg_run_options[@]}"
    elif  [[ $recipe ]]; then
        if ! "$autopkg_binary" run "$autopkg_verbosity" "$recipe" "${autopkg_run_options[@]}"; then
            echo "ERROR: AutoPkg run failed"
            exit 1
        else
            echo "AutoPkg run completed"
        fi
    else
        echo "ERROR: no recipe or recipe list supplied"
        exit 1
    fi
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
        -r|--recipe)
            shift
            recipes+=("$1")
            ;;
        -l|--recipe-list)
            shift
            recipe_list="$1"
            ;;
        -p|--replace)
            replace_pkg=1
            ;;
        -d|--dp)
            shift
            dp_url_filter="$1"
            ;;
        --prefs)
            shift
            autopkg_prefs="$1"
            if [[ ! -f "$autopkg_prefs" ]]; then
                echo "ERROR: prefs file not found"
                exit 1
            fi
            ;;
        --report-plist)
            shift
            report_plist="$1"
            ;;
        -e|--enabled)
            policy_enabled=1
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
    args+=("-v")
elif [[ ! $quiet_mode ]]; then
    args+=("$verbosity_mode")
fi

# Ask for the instance list, show list, ask to apply to one, multiple or all

echo
echo "This script will run autopkg recipes on the instance(s) you choose."

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

if [[ ${#recipes[@]} -ge 1 ]]; then
    echo "Running recipes: ${recipes[*]}"
elif [[ "$recipe" == "" && "$recipe_list" == "" ]]; then
    printf "Enter Recipe or Recipe List to run (e.g. Firefox.jamf or /path/to/recipes.txt) : "
    read -r recipe_choice
    if [[ $recipe_choice == *".txt" ]]; then
        recipe_list="$recipe_choice"
    elif [[ $recipe_choice ]]; then
        recipe_list=""
        recipes+=("$recipe_choice")
    else
        echo "ERROR: no recipe or recipe list supplied"
        exit 1
    fi
fi

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
    echo "Running AutoPkg on $jss_instance..."
    if [[ $recipe_list ]]; then
        run_autopkg
    elif [[ ${#recipes[@]} -gt 0 ]]; then
        for recipe in "${recipes[@]}"; do
            run_autopkg
        done
    else
        echo "No recipes or recipe lists supplied"
        exit 1
    fi
done

echo 
echo "Finished"
echo
