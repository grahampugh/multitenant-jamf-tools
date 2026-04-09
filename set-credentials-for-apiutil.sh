#!/bin/bash

# --------------------------------------------------------------------------------
# Script to create a CSV file of the credentials for each instance in an instance list, to be used with the Jamf API Utility
# 
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# 2. Ask for the username (show any existing value of first instance in list as default)
# 3. Ask for the password (show the associated user if already existing)
# 4. Loop through each selected instance, look for an existing entry in a CSV file, create or overwrite
# --------------------------------------------------------------------------------

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

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    echo "
set-credentials.sh usage:
[no arguments]                   - interactive mode
-il FILENAME (without .txt)      - provide an instance list filename
                                   (must exist in the instance-lists folder)
-i JSS_URL                       - perform action on a single instance
                                   (must exist in the relevant instance list)
-a | --all | --all-instances     - perform action on ALL instances in the instance list
-x | --nointeraction             - run without checking instance is in an instance list 
                                   (prevents interactive choosing of instances)
-v[vvv]                          - Set value of verbosity (default is -v)

"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

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
        -a|-ai|--all|--all-instances)
            all_instances=1
            ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        --user|--id|--client-id)
            shift
            chosen_id="$1"
            ;;
        --pass|--secret|--client-secret)
            shift
            chosen_secret="$1"
            ;;
        --csv)
            shift
            csv_file="$1"
            ;;
        --apiutil)
            shift
            apiutil_path="$1"
            ;;
        -v*)
            verbose=1
            ;;
        *)
            echo
            usage
            exit 0
            ;;
    esac
    shift
done
echo

# set default path for apiutil if not provided
if [[ -z "$apiutil_path" ]]; then
    apiutil_path="/Applications/API Utility.app"
    # check if API Utility exists at the default path
    if [[ ! -d "$apiutil_path" ]]; then
        echo "   [main] ERROR: API Utility not found at default path '$apiutil_path'. Please provide the correct path using the --apiutil argument."
        exit 1
    fi
    echo "   [main] No path provided for Jamf API Utility, using default: $apiutil_path"
else
    # check if API Utility exists at the provided path
    if [[ ! -d "$apiutil_path" ]]; then
        echo "   [main] ERROR: API Utility not found at provided path '$apiutil_path'. Please check the path and try again."
        exit 1
    fi
    echo "   [main] Using provided path for Jamf API Utility: $apiutil_path"
fi

# check that the CSV file either exists or can be created
delete_csv_file=0
if [[ -n "$csv_file" ]]; then
    if [[ -f "$csv_file" ]]; then
        # check format of CSV file, must have 5 columns
        if [[ $(head -n 1 "$csv_file" | awk -F',' '{print NF}') -ne 5 ]]; then
            echo "   [main] ERROR: CSV file '$csv_file' does not have the correct format. It must have 5 columns: type,JSS_URL,account,credential,isApiClient but no column titles. Please check the file and try again."
            exit 1
        fi
        echo "   [main] Using existing CSV file: $csv_file"
    else
        touch "$csv_file" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            echo "   [main] ERROR: CSV file '$csv_file' does not exist and cannot be created. Please check the path and permissions."
            exit 1
        else
            # add column titles to the new CSV file
            echo "   [main] CSV file '$csv_file' does not exist but was successfully created. Credentials will be saved to this file."
            delete_csv_file=1
        fi
    fi
else
    echo "   [main] No CSV file specified. Creating a temporary CSV file in your Documents folder."
    csv_file=$(mktemp "$HOME/Documents/credentials.XXXXXX")
    mv "$csv_file" "${csv_file}.csv"
    csv_file="${csv_file}.csv"
    delete_csv_file=1
fi

# Ask for the instance list, show list, ask to apply to one, multiple or all
if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "   [main] Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "   [main] Running on instances: ${chosen_instances[*]}"
fi


# Ask for the instance list, show list, ask to apply to one, multiple or all
choose_destination_instances

# Ask for the username (show any existing value of first instance in list as default)
if [[ ! $chosen_id ]]; then
    echo "Enter username or Client ID for ${instance_choice_array[0]}"
    read -r -p "User/Client ID : " chosen_id
    if [[ ! $chosen_id ]]; then
        echo "No username/Client ID supplied"
        exit 1
    fi
fi

echo

if [[ ! "$chosen_secret" ]]; then
    echo "Enter password/Client Secret for $chosen_id on $instance_base"
    [[ $instance_pass ]] && echo "(or press ENTER to use existing password/Client Secret from keychain for $chosen_id)"
    read -r -s -p "Pass : " chosen_secret
    if [[ $instance_pass && ! "$chosen_secret" ]]; then
        chosen_secret="$instance_pass"
    elif [[ ! $chosen_secret ]]; then
        echo "No password/Client Secret supplied"
        exit 1
    fi
fi

# Loop through each selected instance
for instance in "${instance_choice_array[@]}"; do
    echo "   [main] Checking existing credentials for $instance in $csv_file..."
    # check for existing entry in CSV file where url column matches instance URL
    existing_entry=$(grep -E "^[^,]+,$instance," "$csv_file")
    if [[ $existing_entry ]]; then
        echo "   [main] Existing entry found for $instance. Updating credentials."
        # update the existing entry with the new credentials (type,JSS_URL,account,credential,isApiClient)
        #  Valid types: Jamf Pro, Jamf School, Jamf Protect
        # API Cliennts are always a UUID, so check if the chosen_id contains a UUID pattern to determine if it is an API client or not
        if [[ "$chosen_id" =~ [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12} ]]; then
            is_api_client="true"
        else
            is_api_client="false"
        fi
        # extract the type from the existing entry
        type=$(echo "$existing_entry" | cut -d',' -f1)
        # create the new entry with the updated credentials
        new_entry="$type,$instance,$chosen_id,$chosen_secret,$is_api_client"
        # replace the existing entry with the new entry in the CSV file
        sed -i '' "s|$existing_entry|$new_entry|" "$csv_file"
        if [[ $? -eq 0 ]]; then
            echo "   [main] Credentials for $instance updated successfully in $csv_file."
        else
            echo "   [main] ERROR: Failed to update credentials for $instance in $csv_file."
        fi
    else
        echo "   [main] No existing entry found for $instance. Adding new entry to $csv_file."
        # set type to Jamf Pro
        type="Jamf Pro"
        # determine if it is an API client based on the chosen_id containing a UUID pattern
        if [[ "$chosen_id" =~ [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12} ]]; then
            is_api_client="true"
        else
            is_api_client="false"
        fi
        # create the new entry
        new_entry="$type,$instance,$chosen_id,$chosen_secret,$is_api_client"
        # add the new entry to the CSV file
        echo "$new_entry" >> "$csv_file"
        if [[ $? -eq 0 ]]; then
            echo "   [main] Credentials for $instance added successfully to $csv_file."
        else
            echo "   [main] ERROR: Failed to add credentials for $instance to $csv_file."
        fi
    fi
    echo "   [main] Processed credentials for $instance."    
    
done

# now import the credentials from the CSV into apiutil
echo "   [main] Importing credentials from $csv_file into Jamf API Utility..."
apiutil_cli_path="$apiutil_path/Contents/MacOS/apiutil"
if [[ ! -f "$apiutil_cli_path" ]]; then
    echo "   [main] ERROR: API Utility CLI not found at expected path '$apiutil_cli_path'. Please check the API Utility installation and try again."
    exit 1
fi
# check that API Utitily is not already running, as it needs to be restarted to import the new credentials
if pgrep -x "apiutil" > /dev/null; then
    echo "   [main] API Utility is currently running. Restarting API Utility to import new credentials..."
    pkill -x "apiutil"
    sleep 1
fi
echo
while ! "$apiutil_cli_path" --importCreds "$csv_file"; do
    echo "   [main] ERROR: Failed to import credentials into Jamf API Utility. Please check that you have allowed the directory containing the CSV file to be accessed by Jamf API Utility in Settings > Permitted Import Path"
    # allow the user to open the API Utility settings to check the permitted import path
    echo
    read -n 1 -s -r -p "Press any key to open Jamf API Utility settings and ensure the Permitted Import Path\ntincludes $(dirname "$csv_file"), then close the API Utility window to continue."
    open -a "$apiutil_path"
    echo
    # wait until app is closed
    while pgrep -x "apiutil" > /dev/null; do
        sleep 1
    done
    # fail after 3 attempts
    ((attempts++))
    if [[ $attempts -ge 3 ]]; then
        echo "   [main] ERROR: Failed to import credentials into Jamf API Utility after 3 attempts."
        exit 1
    fi
done
echo
echo "   [main] Credentials imported successfully into Jamf API Utility."

# if the CSV file was created during this script, delete it afterwards for security reasons
if [[ -f "$csv_file" && $delete_csv_file -eq 1 ]]; then
    rm "$csv_file"
    echo "   [main] Temporary CSV file '$csv_file' deleted."
fi

echo
echo "Finished"
echo
