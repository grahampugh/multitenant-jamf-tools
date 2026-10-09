#!/bin/bash
# shellcheck disable=SC2154

# --------------------------------------------------------------------------------
# This script is meant to be sourced in order to supply credentials and a token
# to Jamf Pro API scripts
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# remove history expansion
set +H

# Path to here
this_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# temp files for tokens, cookies and headers
output_location="/tmp/mjt"
mkdir -p "$output_location"

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

root_check() {
    # Check that the script is NOT running as root
    if [[ $EUID -eq 0 ]]; then
        echo "This script is NOT MEANT to run as root."
        echo "Please run without sudo."
        echo
        exit 4 # Running as root.
    else
        # check that user is an admin
        if ! /usr/sbin/dseditgroup -o checkmember -m "$USER" admin; then
            echo "This particular action requires a user with admin privileges."
            echo
            exit 5 # Running as a standard user.
        else
            echo "Please enter your account password to continue:"
            sudo echo "Thank you."
        fi
    fi
}

get_slack_webhook() {
    instance_list_file="$1" # slack webhook filename should match the current instance list file
    # allow a global slack webhook if found in the autopkg prefs
    if [[ -f "$autopkg_prefs" ]]; then
        slack_webhook_key=$(defaults read "$autopkg_prefs" slack_webhook_url 2>/dev/null)
        if [[ "$slack_webhook_key" && ! "$slack_webhook_url" ]]; then
            slack_webhook_url="$slack_webhook_key"
            echo "   [get_slack_webhook] Using global Slack webhook from autopkg prefs."
            return 0
        fi
    fi

    slack_webhook_file="$(dirname "$instance_list_file")/../slack-webhooks/$(basename "$instance_list_file")"

    webhook_found=0
    if [[ -f "$slack_webhook_file" ]]; then
        # generate a standard "complete" list
        slack_webhook_url=""
        while IFS= read -r slack_webhook_url; do
            if [[ "$slack_webhook_url" ]]; then
                webhook_found=1
                echo "   [get_slack_webhook] Slack webhook found."
                break
            fi
        done <"$slack_webhook_file"
    fi
    if [[ $webhook_found -eq 0 ]]; then
        return 1
    fi
}

get_instance_list_files() {
    # get a list of instance list files
    # import relevant instance list
    echo
    default_instance_lists_folder="$this_script_dir/instance-lists"
    if defaults read com.github.autopkg instance_lists &>/dev/null; then
        if [[ $(defaults read com.github.autopkg instance_lists) ]]; then
            instance_lists_folder=$(defaults read com.github.autopkg instance_lists)
            echo "Instance lists folder: $instance_lists_folder"
            echo
        fi
    fi
    # Set default instance list (already set if using jocads.sh and selecting destination)
    if [[ ! $default_instance_list ]]; then
        if [[ -d "$instance_lists_folder" ]]; then
            default_instance_list_file="$instance_lists_folder/default-instance-list.txt"
            if [[ -f "$default_instance_list_file" ]]; then
                default_instance_list="$instance_lists_folder/$(cat "$default_instance_list_file").txt"
            else
                default_instance_list="$instance_lists_folder/prd.txt"
            fi
        else
            default_instance_list_file="$default_instance_lists_folder/default-instance-list.txt"
            if [[ -f "$default_instance_list_file" ]]; then
                default_instance_list="$default_instance_lists_folder/$(cat "$default_instance_list_file").txt"
            else
                default_instance_list="$default_instance_lists_folder/prd.txt"
            fi
        fi
    fi

    default_instance_list_for_dialogs="$(basename "$default_instance_list" | sed 's/\.txt//')"

    # handle prefix and overrides files
    if [[ -d "$instance_lists_folder" ]]; then
        display_name_prefix_file="$instance_lists_folder/display-name-prefix-list.txt"
        script_name_prefix_file="$instance_lists_folder/script-name-prefix-list.txt"
        pkg_name_prefix_file="$instance_lists_folder/pkg-name-prefix-list.txt"
        global_overrides_file="$instance_lists_folder/global-overrides-list.txt"
    fi

    i=0
    instance_list_files=()
    chosen_instance_list_filepath=""

    if [[ -d "$instance_lists_folder" ]]; then
        while IFS= read -r -d '' file; do
            filename=$(basename "$file" | sed 's/\.txt//')
            if [[ "$filename" == "$chosen_instance_list_file" ]]; then
                chosen_instance_list_filepath="$file"
            fi
            instance_list_files+=("$file")
            echo "[$i] $filename"
            ((i++))
        done < <(find "$instance_lists_folder" -type f -name "*.txt" -not -name "default-instance-list.txt" -not -name "display-name-prefix-list.txt" -not -name "script-name-prefix-list.txt" -not -name "pkg-name-prefix-list.txt" -not -name "global-overrides-list.txt" -print0)
    fi

    # repeat for the default in case we need to keep private lists
    if [[ -d "$default_instance_lists_folder" ]] && [[ $(find "$default_instance_lists_folder" -type f -name "*.txt" -not -name "default-instance-list.txt" -maxdepth 1 2>/dev/null | wc -l) -gt 0 ]]; then
        echo
        echo "Private Instance lists folder: $default_instance_lists_folder"
        echo
        while IFS= read -r -d '' file; do
            filename=$(basename "$file" | sed 's/\.txt//')
            match=0
            for il in "${instance_list_files[@]}"; do
                ilb=$(basename "$il" | sed 's/\.txt//')
                if [[ "$ilb" == "$filename" ]]; then
                    match=1
                fi
            done
            if [[ $match -eq 0 ]]; then
                if [[ $filename == "$chosen_instance_list_file" ]]; then
                    chosen_instance_list_filepath="$file"
                fi
                instance_list_files+=("$file")
                echo "[$i] $filename"
                ((i++))
            fi
        done < <(find "$default_instance_lists_folder" -type f -name "*.txt" -not -name "default-instance-list.txt" -not -name "display-name-prefix-list.txt" -not -name "script-name-prefix-list.txt" -not -name "pkg-name-prefix-list.txt" -not -name "global-overrides-list.txt" -print0)
    fi
    if [[ $i -eq 0 ]]; then
        echo
        echo "   [get_instance_list_files] No instance lists found. To create an instance list, add a text file into the $instance_lists_folder folder"
        exit 1
    fi
}

get_instance_list() {
    instance_list_file="$1"

    if [[ -f "$instance_list_file" ]]; then
        # generate a standard "complete" list
        instances_list=()
        instances_list_inc_ios_instances=()
        while IFS= read -r; do
            line="$REPLY"
            if [[ "$line" == *","* ]]; then
                instance=$(echo "$REPLY" | cut -d, -f1)
                note=$(echo "$REPLY" | cut -d, -f2)
            else
                instance="$line"
                note=""
            fi
            if [[ "$instance" ]]; then
                if [[ $strip_failover != "no" ]]; then
                    # strip the URL back to remove failover or other supplied URL parameters
                    instance=$(strip_url "$instance")
                fi
                instances_list_inc_ios_instances+=("$instance")
                if [[ "$note" != *"iOS"* ]]; then
                    instances_list+=("$instance")
                fi
            fi

        done <"$instance_list_file"
    else
        echo
        echo "No instance list found."
        exit 1
    fi
}

choose_instance_list() {
    # get instance list files
    get_instance_list_files
    echo

    # set instance list
    if [[ -f "$chosen_instance_list_filepath" ]]; then
        echo "Instance list $chosen_instance_list_file chosen"
        instance_list_file="$chosen_instance_list_filepath"
        slack_instance_list="$instance_list_file"
    else
        echo "Choose the instance list(s) from the list above"
        if [[ -f "$default_instance_list" ]]; then
            echo "or press ENTER to choose list(s) $default_instance_list_for_dialogs"
        fi
        read -r -p "Instance list(s) : " instance_list_choice
        echo
        if [[ "$instance_list_choice" ]]; then
            temp_instance_list=()
            # set slack_instance_list to the first choice (choices are separated by spaces)
            slack_instance_list="${instance_list_choice%% *}"

            for choice in $instance_list_choice; do
                if [[ -f "${instance_list_files[$choice]}" ]]; then
                    # get all the lines from the file $choice and add to temp_instance_list
                    while IFS= read -r line; do
                        # check that the entry is not already in temp_instance_list
                        if [[ ! " ${temp_instance_list[*]} " =~ " $line " ]]; then
                            temp_instance_list+=("$line")
                        fi
                    done <"${instance_list_files[$choice]}"
                fi
            done
            # sort the list alphabetically, but keeping the first entry first in the list
            sorted_temp_instance_list=()
            if [[ ${#temp_instance_list[@]} -gt 0 ]]; then
                # Keep the first entry
                sorted_temp_instance_list+=("${temp_instance_list[0]}")

                # Sort the remaining entries alphabetically
                if [[ ${#temp_instance_list[@]} -gt 1 ]]; then
                    while IFS= read -r line; do
                        sorted_temp_instance_list+=("$line")
                    done < <(printf '%s\n' "${temp_instance_list[@]:1}" | sort)
                fi
            fi

            # create a temporary instance list file and populate with the entries of temp_instance_list with each entry as a single line
            instance_list_file="$output_location/combo_instance_list.txt"
            echo "" >"$instance_list_file"
            for temp_instance in "${sorted_temp_instance_list[@]}"; do
                echo "$temp_instance" >>"$instance_list_file"
            done
        elif [[ -f "$default_instance_list" ]]; then
            instance_list_file="$default_instance_list"
        else
            echo "Instance list not found"
            exit 1
        fi
    fi

    # get the instance list and print it out
    get_instance_list "$instance_list_file"

    # print out the instance list
    if [[ "$instance_list_type" == "ios" ]]; then
        working_instances_list=("${instances_list_inc_ios_instances[@]}")
    else
        working_instances_list=("${instances_list[@]}")
    fi

    echo "Instance list $instance_list_file:"
    item=0
    for instance in "${working_instances_list[@]}"; do
        printf '   %-7s %-30s\n' "($item)" "$instance"
        ((item++))
    done
    echo

}

choose_source_instance() {
    choose_instance_list

    # Ask which instance we need to process, check if it exists and go from there
    source_default_template_instance="${working_instances_list[0]}"

    if [[ $source_instance == "template" || $source_instance == "0" ]]; then
        source_instance="$source_default_template_instance"
    else
        if [[ $source_instance ]]; then
            instance_selection="$source_instance"
        else
            instance_selection=""
            echo "Enter the number of source instance from which to download API data,"
            echo "   or enter a string to select the FIRST matching instance,"
            read -r -p "   or press enter for '(0) $source_default_template_instance' : " instance_selection
        fi
        # Check for the default or non-context
        if grep -qe "[A-Za-z]" <<<"$instance_selection"; then
            for instance in "${working_instances_list[@]}"; do
                if [[ "$instance" == *"${instance_selection}."* || "$instance" == *"${instance_selection}-"* ]]; then
                    source_instance="$instance"
                    for i in "${!working_instances_list[@]}"; do
                        [[ "${working_instances_list[$i]}" = "${instance}" ]] && source_instance_selection=$i
                    done
                    break
                fi
            done
            if [[ ! "$source_instance" ]]; then
                echo "ERROR: could not find matching instance"
                exit 1
            fi
        elif [[ "$instance_selection" ]]; then
            source_instance="${working_instances_list[instance_selection]}"
            source_instance_selection="$instance_selection"
        else
            source_instance="$source_default_template_instance"
            source_instance_selection="0"
        fi
    fi

    echo
    echo "   [main] Source instance chosen: $source_instance"

}

strip_url() {
    # remove any trailing slash and any failover or other supplied URL parameters
    local url="${1}"
    while true; do
        case "$url" in
        *\?*) url="${url%\?*}" ;;
        */) url="${url%/}" ;;
        *) break ;;
        esac
    done

    echo "$url"
}

choose_destination_instances() {
    # Ask which instance we need to process, check if it exists and go from there
    echo
    if [[ $no_interaction -eq 1 ]]; then
        # if no_interaction is set, we skip straight to a single provided instance
        if [[ $chosen_instance || ${#chosen_instances[@]} -gt 0 ]]; then
            instance_choice_array=()
            if [[ $chosen_instance ]]; then
                instance_choice_array+=("$chosen_instance")
            elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
                for instance in "${chosen_instances[@]}"; do
                    instance_choice_array+=("$instance")
                done
            fi
        else
            echo "No instance chosen. Cannot continue."
            exit 1
        fi
    else
        choose_instance_list
        instance_selection=""
        if [[ ! $chosen_instance && ${#chosen_instances[@]} -eq 0 && $all_instances -ne 1 ]]; then
            echo "Enter the number(s) of the destination JSS instance(s),"
            echo "   or enter a string to select the FIRST matching instance,"
            echo "   or enter 'ALL' to propagate to all destination instances"
            if [[ $source_instance ]]; then
                echo "   or press enter for '($source_instance_selection) $source_instance'."
            else
                echo "   or press enter for '(0) ${working_instances_list[0]}'."
            fi
            read -r -p "   Instance(s) : " instance_selection
            echo
        fi

        # Create an array of destination instances
        instance_choice_array=()
        if [[ $chosen_instance ]]; then
            for instance in "${working_instances_list[@]}"; do
                if [[ "$chosen_instance" == "$instance" ]]; then
                    instance_choice_array+=("$instance")
                    break
                fi
            done
            if [[ ${#instance_choice_array[@]} -eq 0 ]]; then
                echo "Chosen instance $chosen_instance does not exist in the selected instance list. Cannot continue."
                exit 1
            fi
        elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
            for instance in "${chosen_instances[@]}"; do
                for jss_instance in "${working_instances_list[@]}"; do
                    if [[ "$instance" == "$jss_instance" ]]; then
                        instance_choice_array+=("$jss_instance")
                        break
                    fi
                done
            done
        elif [[ $all_instances -eq 1 || "$instance_selection" == "ALL" ]]; then
            instance_choice_array+=("${working_instances_list[@]}")
            # shellcheck disable=SC2034
            do_all_instances="yes"
        elif grep -qe "[A-Za-z]" <<<"$instance_selection"; then
            for instance in "${working_instances_list[@]}"; do
                if [[ "$instance" == *"${instance_selection}."* || "$instance" == *"${instance_selection}-"* ]]; then
                    instance_choice_array+=("$instance")
                    break
                fi
            done
            if [[ ${#instance_choice_array[@]} -eq 0 ]]; then
                echo "ERROR: could not find matching instance"
                exit 1
            fi
        elif [[ "$instance_selection" ]]; then
            for instance in $instance_selection; do
                if [[ $instance == *"-"* ]]; then
                    list_first=$(echo "$instance" | cut -d'-' -f1)
                    list_last=$(echo "$instance" | cut -d'-' -f2)
                    for ((i = list_first; i <= list_last; i++)); do
                        instance_choice_array+=("${working_instances_list[$i]}")
                    done
                else
                    instance_choice_array+=("${working_instances_list[$instance]}")
                fi
            done
        elif [[ "$source_instance" ]]; then
            instance_choice_array+=("${working_instances_list[$source_instance_selection]}")
        else
            instance_choice_array+=("${working_instances_list[0]}")
        fi
    fi

    echo "Instances chosen:"
    echo

    for instance in "${instance_choice_array[@]}"; do
        echo "   $instance"
    done
    echo
}

get_instance_distribution_point() {
    # find out if there is a file share distribution point in this instance
    # determine jss_url
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="${jss_instance}"

    # skip dp check if the --skip-dp option is used
    if [[ $skip_dp_check -eq 1 ]]; then
        echo "   [get_instance_distribution_point] Skipping DP check as per --skip-dp option"
        smb_url=""
        return
    fi

    # Check for DPs
    # send request
    curl_url="$jss_url/api/v1/distribution-points"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # get the results array, find out if there are more than one
    dp_count=$(/usr/bin/jq -r .totalCount "$curl_output_file")
    # if 0
    if [[ $dp_count -eq 0 ]]; then
        echo "No DP found - assuming JCDS"
        smb_url=""

    else
        echo "Found $dp_count DPs in $jss_url"
        # check if dp_url_filter has been written to the autopkg prefs
        if [[ -f "$autopkg_prefs" ]]; then
            dp_key=$(defaults read "$autopkg_prefs" dp_url_filter 2>/dev/null)
            if [[ "$dp_key" && ! "$dp_url_filter" ]]; then
                dp_url_filter="$dp_key"
            fi
        fi

        # loop through the DPs and check that we have credentials for them - only check the first one for now
        i=0
        while ((i < dp_count)); do
            dp_server=$(/usr/bin/jq -r .results.[$i].serverName "$curl_output_file" 2>/dev/null)
            echo "   [get_instance_distribution_point] Checking DP $i: $dp_server"
            # echo "Distribution Point: $dp" # TEMP
            if [[ $dp_url_filter ]]; then
                if [[ $dp_server == *"$dp_url_filter"* ]]; then
                    echo "   [get_instance_distribution_point] Found matching DP: $dp_server"
                else
                    echo "   [get_instance_distribution_point] Skipping $dp_server - does not match filter $dp_url_filter"
                    ((i++))
                    continue
                fi
            else
                echo "   [get_instance_distribution_point] No filter set - using $dp_server"
            fi
            dp_type=$(/usr/bin/jq -r .results.[$i].fileSharingConnectionType "$curl_output_file" 2>/dev/null)
            echo "   [get_instance_distribution_point] DP type: $dp_type"
            if [[ "$dp_type" == "AFP" ]]; then
                dp_protocol="afp"
            elif [[ "$dp_type" == "SMB" ]]; then
                dp_protocol="smb"
            else
                echo "   [get_instance_distribution_point] Unsupported DP type: $dp_type"
                exit 1
            fi
            dp_share=$(/usr/bin/jq -r .results.[$i].shareName "$curl_output_file" 2>/dev/null)
            # user_rw=$(/usr/bin/jq -r .results.[$i].readWriteUsername "$curl_output_file" 2>/dev/null)
            break
        done
        # smb url
        smb_url="$dp_protocol://$dp_server/$dp_share"
        echo "   [get_instance_distribution_point] SMB URL: $smb_url"
        # smb_uri="$dp_server/$dp_share"
        # echo "SMB_URL: $smb_url" # TEMP
        # echo "SMB_USER: $user_rw" # TEMP
    # if > 1 # TODO
    fi
}

get_smb_credentials() {
    # we need the new endpoints for the password. For now use the keychain
    if [[ "$dp_server" ]]; then
        echo "   [get_smb_credentials] Checking credentials for '$dp_server'."
        # check for existing service entry in login keychain
        dp_check=$(/usr/bin/security find-generic-password -s "$dp_server" 2>/dev/null)
        if [[ $dp_check ]]; then
            # echo "   [get_smb_credentials] Checking keychain entry for $dp_check" # TEMP
            # echo "   [get_smb_credentials] Checking $smb_url" # TEMP
            smb_user=$(/usr/bin/grep "acct" <<<"$dp_check" | /usr/bin/cut -d \" -f 4)
            smb_pass=$(/usr/bin/security find-generic-password -a "$smb_user" -s "$dp_server" -w -g 2>/dev/null)
            # smb_pass=${smb_pass//\!/} # exclamation points are ignored and mess up the SMB command so we remove them
            # echo "   [get_smb_credentials] User: $smb_user - Pass: $smb_pass" # TEMP
        # else
        #     echo "   [get_smb_credentials] User: $smb_user - Pass: $smb_pass" # TEMP
        fi
    else
        echo "ERROR: DP not determined. Cannot continue"
        exit 1
    fi
}

send_slack_notification() {
    local slack_text=$1

    if get_slack_webhook "$slack_instance_list"; then
        response=$(
            curl -s -o /dev/null -S -i -X POST -H "Content-Type: application/json" \
                --write-out '%{http_code}' \
                --data "$slack_text" \
                "$slack_webhook_url"
        )
        echo "   [send_slack_notification] Sent Slack notification (response: $response)"
    else
        echo "   [send_slack_notification] No Slack webhook found"
    fi
}

set_credentials() {
    jss_url="$1"
    jss_api_user="$2"

    if [[ $verbose -gt 0 ]]; then
        echo "Setting credentials for $jss_url"
    fi

    instance_base="${jss_url/*:\/\//}"

    # check for username entry in login keychain
    if [[ ! $jss_api_user ]]; then
        find_all_internet_passwords "$jss_url"
        find_result=$?
        if [[ $find_result -eq 1 ]]; then
            echo "   [set_credentials] No username or Client ID found for $jss_url in keychain"
            exit 1
        elif [[ $find_result -eq 2 ]]; then
            echo "   [set_credentials] Multiple usernames/Client IDs found for $jss_url in keychain, but no interaction allowed"
            exit 1
        fi
        jss_api_user="$chosen_account"
        # echo "   [set_credentials] Using user/client ID: $jss_api_user" # TEMP
    fi

    if [[ ! $jss_api_user ]]; then
        echo "No keychain entry for $jss_url found. Please run the set_credentials.sh script to add the username/Client ID to your keychain"
        exit 1
    else
        if [[ $verbose -gt 0 ]]; then
            echo "   [set_credentials] Found username/Client ID: $jss_api_user for $jss_url"
        fi
    fi

    # check for password entry in login keychain
    # jss_api_password=$("${this_script_dir}/keychain.sh" -t internet -p -s "$jss_url")
    jss_api_password=$(/usr/bin/security find-internet-password -s "$jss_url" -l "$instance_base ($jss_api_user)" -a "$jss_api_user" -w -g 2>&1)

    if [[ ! $jss_api_password ]]; then
        echo "No password/Client Secret for $jss_api_user found. Please run the set_credentials.sh script to add the password/Client Secret to your keychain"
        exit 1
    else
        if [[ $verbose -gt 0 ]]; then
            echo "   [set_credentials] Found password/Client Secret for $jss_api_user"
        fi
    fi

    # encode the credentials so we are not sending in plain text
    b64_credentials=$(printf "%s:%s" "$jss_api_user" "$jss_api_password" | iconv -t ISO-8859-1 | base64 -i -)

    # echo "$jss_api_user:$jss_api_password"  # UNCOMMENT-TO-DEBUG
}

get_api_token() {
    # check if the user is a UUID (therefore implying a Client ID)
    if [[ $cred_type == "client-id" ]]; then
        http_response=$(
            curl --request POST \
                --silent \
                --url "$jss_url/api/v1/oauth/token" \
                --header 'Content-Type: application/x-www-form-urlencoded' \
                --data-urlencode "client_id=$jss_api_user" \
                --data-urlencode "grant_type=client_credentials" \
                --data-urlencode "client_secret=$jss_api_password" \
                --write-out "%{http_code}" \
                --header 'Accept: application/json' \
                --output "$token_file"
        )
        if [[ $verbose -gt 0 ]]; then
            echo "   [get_api_token] Token request HTTP response: $http_response"
        fi
        if [[ $http_response -lt 400 ]]; then
            token=$(jq -r .access_token "$token_file" 2>/dev/null)
        else
            echo "   [get_api_token] Token download failed for $jss_url"
            return 1
        fi
    else
        http_response=$(
            curl --request POST \
                --silent \
                --url "$jss_url/api/v1/auth/token" \
                --header "authorization: Basic $b64_credentials" \
                --write-out "%{http_code}" \
                --header 'Accept: application/json' \
                --output "$token_file"
        )
        if [[ $verbose -gt 0 ]]; then
            echo "   [get_api_token] Token request HTTP response: $http_response"
        fi
        if [[ $http_response -lt 400 ]]; then
            token=$(jq -r .token "$token_file" 2>/dev/null)
        else
            echo "   [get_api_token] Token download failed for $jss_url"
            return 1
        fi
    fi

    echo "$jss_url" >"$server_check_file"
    echo "$jss_api_user" >"$user_check_file"

    if [[ $verbose -gt 0 ]]; then
        echo "   [get_api_token] Token for $jss_api_user on $jss_url written to $token_file"
    fi
}

check_token() {
    instance_id=$(echo "$jss_url" | sed 's|https://||' | sed 's|:|_|g' | sed 's|/|_|g' | sed 's|\.|_|g')
    token_file="$output_location/jamf_api_token_${instance_id}_${jss_api_user}.txt"
    server_check_file="$output_location/jamf_server_check_${instance_id}_${jss_api_user}.txt"
    user_check_file="$output_location/jamf_user_check_${instance_id}_${jss_api_user}.txt"
    curl_output_file="$output_location/output_${instance_id}_${jss_api_user}.txt"
    curl_headers_file="$output_location/headers_${instance_id}_${jss_api_user}.txt"
    cookie_jar="$output_location/jamf_cookie_jar_${instance_id}_${jss_api_user}.txt"

    # determine account type
    if [[ $jss_api_user =~ ^\{?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}\}?$ ]]; then
        cred_type="client-id"
    else
        cred_type="account"
    fi

    # is there a token file
    if [[ -f "$token_file" ]]; then
        # check we are still querying the same server and with the same account
        server_check=$(cat "$server_check_file" 2>/dev/null)
        user_check=$(cat "$user_check_file" 2>/dev/null)
        if [[ "$server_check" == "$jss_url" && "$user_check" == "$jss_api_user" ]]; then
            if [[ $cred_type == "client-id" ]]; then
                if jq -e .access_token "$token_file" >/dev/null; then
                    token=$(jq -r .access_token "$token_file")
                else
                    token=""
                fi
                if jq -e .expires_in "$token_file" >/dev/null; then
                    expires=$(jq -r .expires_in "$token_file")
                    current_time_epoch=$(/bin/date +%s)
                    expiration_epoch=$((current_time_epoch + expires - 1))
                else
                    expiration_epoch="0"
                fi
                if [[ $expiration_epoch -gt $current_time_epoch ]]; then
                    human_cutoff_time=$(/bin/date -r "$expiration_epoch")
                    if [[ $verbose -gt 0 ]]; then
                        echo "   [check_token] Token is still valid (expires at $human_cutoff_time)"
                    fi
                else
                    if [[ $verbose -gt 0 ]]; then
                        echo "   [check_token] Token expired or invalid ($expiration_epoch v $current_time_epoch). Grabbing a new one"
                    fi
                    sleep 1
                    if ! get_api_token; then
                        return 1
                    fi
                fi
            else
                if jq -e .token "$token_file" >/dev/null; then
                    token=$(jq -r .token "$token_file")
                else
                    token=""
                fi
                if jq -e .expires "$token_file" >/dev/null; then
                    expires=$(jq -r .expires "$token_file")
                    # shellcheck disable=SC2001
                    expires_stripped=$(sed 's/\(\.[0-9]*\)\{0,1\}Z$//' <<<"$expires") # strip optional milliseconds and Z from the end of the date
                    expiration_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$expires_stripped" +"%s")
                else
                    expiration_epoch="0"
                fi
                # set a cutoff of one minute in the future to prevent problems with mismatched expiration
                cutoff_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(date -u +"%Y-%m-%dT%H:%M:%S")" +"%s")

                if [[ $expiration_epoch -lt $cutoff_epoch ]]; then
                    if [[ $verbose -gt 0 ]]; then
                        echo "   [check_token] Token expired or invalid ($expiration_epoch v $cutoff_epoch). Grabbing a new one"
                    fi
                    sleep 1
                    if ! get_api_token; then
                        return 1
                    fi
                else
                    human_cutoff_time=$(/bin/date -r "$expiration_epoch")
                    if [[ $verbose -gt 0 ]]; then
                        echo "   [check_token] Token is still valid (expires at $human_cutoff_time)"
                    fi
                fi
            fi
        elif [[ "$server_check" == "$jss_url" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "   [check_token] '$user_check' does not match '$jss_api_user'. Grabbing a new token"
            fi
            sleep 1
            if ! get_api_token; then
                return 1
            fi
        elif [[ "$user_check" == "$jss_api_user" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "   [check_token] '$server_check' does not match '$jss_url'. Grabbing a new token"
            fi
            sleep 1
            if ! get_api_token; then
                return 1
            fi
        else
            if [[ $verbose -gt 0 ]]; then
                echo "   [check_token] '$user_check' does not match '$jss_api_user', and '$server_check' does not match '$jss_url'. Grabbing a new token."
            fi
            sleep 1
            if ! get_api_token; then
                return 1
            fi
        fi
    else
        if [[ $verbose -gt 0 ]]; then
            echo "   [check_token] No token found. Grabbing a new one"
        fi
        if ! get_api_token; then
            return 1
        fi
    fi
    export token
}

handle_jpapi_get_request() {
    # handle Jamf Pro API GET requests that may require looping through multiple pages

    # local variables to pass in
    local endpoint="$1"
    local sort_or_filter="$2"
    local key="$3"
    local match="$4"

    if [[ -z $endpoint ]]; then
        echo "   [handle_jpapi_get_request] No endpoint provided for handle_jpapi_get_request"
        return 1
    fi

    # if endpoint already includes a filter, or if the endpoint includes an ID we cannot add another one
    # the ID could be any keyname but will always follow /api/v[number]/resourceName/<ID> or /api/apiType/v[number]/resourceName/<ID>
    # so we check that there are more than 1 slashes in the endpoint after the /v[number] part

    # Count number of slashes after the /v[number] part
    # Find the position of /v[digits] in the endpoint
    vpos=$(awk -v str="$endpoint" 'BEGIN{match(str, /\/v[0-9]+/); print RSTART+RLENGTH-1}')
    if [[ $vpos -gt 0 ]]; then
        # Get substring after /v[number]
        rest="${endpoint:$vpos}"
        slash_count=$(grep -o "/" <<<"$rest" | wc -l)
    else
        slash_count=$(grep -o "/" <<<"$endpoint" | wc -l)
    fi
    if [[ $slash_count -gt 1 ]]; then
        echo "   [handle_jpapi_get_request] Endpoint already includes an ID or other subfilter, cannot add sort or filter"
        filter_type="preset"
    # if there are parameters already in the endpoint, we cannot add more
    # we check for /? in the endpoint
    elif [[ "$endpoint" == *"/?"* || "$endpoint" == *"?"* ]]; then
        echo "   [handle_jpapi_get_request] Endpoint already includes parameters, cannot add more"
        filter_type="preset"
    elif [[ "$sort_or_filter" == "sort" ]]; then
        filter_type="sort"
        if [[ -z $key ]]; then
            echo "   [handle_jpapi_get_request] No sort key provided for handle_jpapi_get_request, using id as default sorting method"
            key="id"
        fi
    elif [[ "$sort_or_filter" == "filter" ]]; then
        if [[ ! "$key" || ! "$match" ]]; then
            echo "   [handle_jpapi_get_request] ERROR: No filter key or match provided for handle_jpapi_get_request"
            exit 1
        fi
    else
        echo "   [handle_jpapi_get_request] No sort or filter type provided for handle_jpapi_get_request, using id as default sorting method"
        filter_type="none"
    fi

    if [[ $filter_type == "sort" || $filter_type == "none" ]]; then
        # first check if the endpoint is paginated
        # we do this by requesting a single item and checking the totalCount value
        echo "   [handle_jpapi_get_request] Checking if endpoint is paginated..."
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
        check_if_paginated
        if [[ $paginated == "true" ]]; then
            # we need to run multiple loops to get all the devices if there are more than 1000
            # calculate how many loops we need
            loop_count=$((total_count / 100))
            if ((total_count % 100 > 0)); then
                loop_count=$((loop_count + 1))
            fi
            echo "   [handle_jpapi_get_request] Will loop through $loop_count times to get all items."

            # now loop through
            i=0
            combined_output=""
            while [[ $i -lt $loop_count ]]; do
                echo "   [handle_jpapi_get_request] Processing page $i of $loop_count..."
                # set the page number

                url_filter="?page=$i&page-size=100"
                if [[ "$filter_type" == "sort" && "$key" ]]; then
                    url_filter="$url_filter&sort=$key"
                fi
                curl_url="$jss_url$endpoint/$url_filter"
                curl_args=("--request")
                curl_args+=("GET")
                curl_args+=("--header")
                curl_args+=("Accept: application/json")
                send_curl_request
                # cat "$curl_output_file" # TEMP
                # append the results array to the combined_results array (do not export to a file)
                combined_output+=$(cat "$curl_output_file")
                # echo "$combined_output" > /tmp/combined_output.txt # TEMP
                ((i++))
            done
            echo "   [handle_jpapi_get_request] All pages processed."
        else
            echo "   [handle_jpapi_get_request] Endpoint is not paginated, using existing request."
            combined_output=$(cat "$curl_output_file")
        fi
    else
        # filter based on a key=match pair
        # get token
        if [[ "$chosen_id" ]]; then
            set_credentials "$jss_instance" "$chosen_id"
            echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
        else
            set_credentials "$jss_instance"
            echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
        fi
        jss_url="$jss_instance"
        if [[ "$filter_type" == "preset" ]]; then
            # if preset, the endpoint already includes the filter so we do not need to add anything
            curl_url="$jss_url$endpoint"
        else
            # url-encode the key without using python3
            match_encoded=$(printf "%s" "$match" | jq -s -R -r @uri)
            url_filter="?filter=$key%3D%3D%22$match_encoded%22"
            curl_url="$jss_url$endpoint/$url_filter"
        fi
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
        combined_output=$(cat "$curl_output_file")
    fi
}

send_curl_request() {
    # send a curl request with retries
    max_tries=3
    if [[ -n $max_tries_override ]]; then
        max_tries=$max_tries_override
    fi

    if [[ $verbose -gt 0 ]]; then
        echo "Supplied URL: $curl_url"
    fi

    try=0

    while [[ $try -le $max_tries ]]; do
        # skip token check for Platform API requests
        if [[ "$api_base_url" == *".apigw.jamf.com" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "   [send_curl_request] Detected Platform API endpoint."
            fi
            check_platform_api_token
        else
            if [[ $verbose -gt 0 ]]; then
                echo "   [send_curl_request] Detected Jamf Pro API endpoint."
            fi
            if ! check_token; then
                return 1
            fi
        fi
        # any additional curl_args must be defined before this request (even if empty). Normally the header and=/or request will be made there
        curl_standard_args+=("--location")
        curl_standard_args=("--header")
        curl_standard_args+=("authorization: Bearer $token")
        curl_standard_args+=("--write-out")
        curl_standard_args+=('%{http_code}')
        curl_standard_args+=("--cookie")
        curl_standard_args+=("$cookie_jar")
        curl_standard_args+=("--cookie-jar")
        curl_standard_args+=("$cookie_jar")
        curl_standard_args+=("--output")
        curl_standard_args+=("$curl_output_file")
        curl_standard_args+=("--silent")
        curl_standard_args+=("--show-error")
        curl_standard_args+=("--dump-header")
        curl_standard_args+=("$curl_headers_file")

        final_args=()
        final_args=("${curl_standard_args[@]}" "${curl_args[@]}" "$curl_url")
        curl_request=$(curl "${final_args[@]}")

        if [[ $verbose -gt 0 ]]; then
            echo "   [send_curl_request] Complete curl command sent:"
            printf 'curl'
            for arg in "${final_args[@]}"; do
                printf ' %q' "$arg"
            done
            printf '\n'
        fi

        http_response="$curl_request"

        # These lines can be commented out if we need to see what the request was and what the response is
        # echo "    REQUEST:" # TEMP
        # echo "curl ${final_args[*]}" # TEMP
        # echo "    RESPONSE:" # TEMP
        # cat "$curl_output_file" # TEMP

        if [[ "$http_response" == "10"* || "$http_response" == "20"* || "$http_response" == "30"* ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "   [send_curl_request] Success response ($http_response)"
                echo "   [send_curl_request] Output file: $curl_output_file"
            fi
            break
        elif [[ "$http_response" == "400" ]]; then
            echo "   [send_curl_request] Fail response ($http_response) - aborting"
            if [[ $verbose -gt 0 ]]; then
                echo
                cat "$curl_headers_file"
                echo
                cat "$curl_output_file"
                echo
                echo
            fi
            break
        else
            echo "   [send_curl_request] Fail response ($http_response) - attempt #$try."
        fi
        sleep $try
        ((try++))
    done
    if [[ $try -gt $max_tries ]]; then
        curl_failed="true"
        export curl_failed
        echo "   [send_curl_request] ERROR: fail response - maximum attempts reached - cannot continue."
    fi
}

get_template_files() {
    # get a list of template files
    templates_folder="$this_script_dir/templates"
    i=0
    template_files=()
    if [[ ! $filetype ]]; then
        filetype="xml"
    fi

    if [[ -d "$templates_folder" ]]; then
        while IFS= read -r -d '' file; do
            filename=$(basename "$file")
            template_files+=("$filename")
            echo "[$i] $filename"
            ((i++))
        done < <(find "$templates_folder" -type f -name "*.$filetype" -print0)
    fi
    if [[ $i -eq 0 ]]; then
        echo
        echo "   [get_template_files] No template files found. To choose from a list, add a text file into the $templates_folder folder"
        exit 1
    fi
}

choose_template_file() {
    # get template files
    echo
    echo "   [choose_template_file] Available templates:"
    echo
    get_template_files
    echo

    # set template
    if [[ $template ]]; then
        echo "   [choose_template_file] Template $template chosen"
        if [[ $template != "/"* ]]; then
            template_file="$templates_folder/$template"
        fi
        if [[ ! -f "$template_file" ]]; then
            echo "   [choose_template_file] Chosen template $template not found"
            exit 1
        fi
    else
        echo "Choose the template from the list above"
        read -r -p "Template : " template
        echo
        if [[ $template && -f "$templates_folder/${template_files[$template]}" ]]; then
            template_file="$templates_folder/${template_files[$template]}"
        else
            echo "   [choose_template_file] Template not found"
            exit 1
        fi
    fi
}

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
    # instance_args+=("--pass")
    # instance_args+=("$jss_api_password")

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
    echo "   [run_jamfupload] Running jamf-upload with the following arguments:"
    echo "$jamf_upload_path" "${args[@]}" "${instance_args[@]}" # TEMP

    "$jamf_upload_path" "${args[@]}" "${instance_args[@]}"

    # Send Slack notification
    slack_text="{'username': '$jss_instance', 'text': '*jamfuploader_run.sh*\nUser: $jss_api_user\nInstance: $jss_instance\nArguments: ${args[*]}'}"
    send_slack_notification "$slack_text"
}

run_jamfcli() {
    instance_args=()

    # specify the URL
    instance_args+=("--url")
    instance_args+=("$jss_instance")

    # get token
    if ! check_token; then
        return 1
    fi

    # export token to a token file for jamf-cli to use (needs to only contain the token, not the JSON)
    # create a temporary file for the token
    token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_jamfcli"

    # add the token (token file is generated by check_token)
    instance_args+=("--token-file")
    instance_args+=("$token_file_for_jamfcli")

    # Run jamf-cli and output to stdout
    echo "   [run_jamfcli] Running jamf-cli with the following arguments:"
    echo "$jamf_cli_path" "${args[@]}" "${instance_args[@]}" # TEMP

    "$jamf_cli_path" "${args[@]}" "${instance_args[@]}"

    # Send Slack notification
    slack_text="{'username': '$jss_instance', 'text': '*jamfcli_run.sh*\nUser: $jss_api_user\nInstance: $jss_instance\nArguments: ${args[*]}'}"
    send_slack_notification "$slack_text"
}

encode_name() {
    url_encoded_name="$(echo "$1" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g')"
    echo "$url_encoded_name"
}

get_object_id_from_name() {
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"

    api_object_type=$(get_api_object_type "$api_xml_object")
    api_xml_object_plural=$(get_plural_from_api_xml_object "$api_xml_object")

    # send request
    curl_url="$jss_url/JSSResource/${api_object_type}"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # echo
    # cat "$curl_output_file" # TEMP
    # echo

    # get id from output
    # shellcheck disable=SC2034
    existing_id=$(xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = '$object_name']/id/text()" "$curl_output_file" 2>/dev/null)
    # xmllint --xpath "//${api_xml_object_plural}/${api_xml_object}[name = 'Administrator Rights']" "$curl_output_file" # TEMP
}

get_computers_in_group() {
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"

    # send request to get each version
    url_encoded_group=$(encode_name "$group_name")
    curl_url="$jss_url/JSSResource/computergroups/name/${url_encoded_group}"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $http_response -eq 404 ]]; then
        echo "   [get_computers_in_group] Smart group '$group_name' does not exist on this server"
        computers_count=0
    else
        # now get all the computer IDs
        computers_count=$(/usr/bin/jq -r .computer_group.computers "$curl_output_file" 2>/dev/null | wc -l)
        if [[ $computers_count -gt 0 ]]; then
            echo "   [get_computers_in_group] Restricting list to members of the group '$group_name'"
            computer_names_in_group=()
            computer_ids_in_group=()
            i=0
            while [[ $i -lt $computers_count ]]; do
                computer_id_in_group=$(/usr/bin/jq -r .computer_group.computers[$i].id "$curl_output_file" 2>/dev/null)
                computer_name_in_group=$(/usr/bin/jq -r .computer_group.computers[$i].name "$curl_output_file" 2>/dev/null)
                # echo "$computer_name_in_group ($computer_id_in_group)"
                computer_names_in_group+=("$computer_name_in_group")
                computer_ids_in_group+=("$computer_id_in_group")
                ((i++))
            done
        else
            echo "   [get_computers_in_group] Group '$group_name' contains no computers, so showing all computers"
        fi

    fi
}

get_mobile_devices_in_group() {
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"

    # send request to get each version
    url_encoded_group=$(encode_name "$group_name")
    curl_url="$jss_url/JSSResource/mobiledevicegroups/name/${url_encoded_group}"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    if [[ $http_response -eq 404 ]]; then
        echo "   [get_mobile_devices_in_group] Smart group '$group_name' does not exist on this server"
        mobile_device_count=0
    else
        # now get all the device IDs
        mobile_device_count=$(/usr/bin/jq -r .mobile_device_group.mobile_devices "$curl_output_file" 2>/dev/null | wc -l)
        if [[ $mobile_device_count -gt 0 ]]; then
            echo "   [get_mobile_devices_in_group] Restricting list to members of the group '$group_name'"
            mobile_device_names_in_group=()
            mobile_device_ids_in_group=()
            i=0
            while [[ $i -lt $mobile_device_count ]]; do
                mobile_device_id_in_group=$(/usr/bin/jq -r .mobile_device_group.mobile_devices[$i].id "$curl_output_file" 2>/dev/null)
                mobile_device_name_in_group=$(/usr/bin/jq -r .mobile_device_group.mobile_devices[$i].name "$curl_output_file" 2>/dev/null)
                # echo "$computer_name_in_group ($mobile_device_id_in_group)"
                mobile_device_names_in_group+=("$mobile_device_name_in_group")
                mobile_device_ids_in_group+=("$mobile_device_id_in_group")
                ((i++))
            done
        else
            echo "   [get_mobile_devices_in_group] Group '$group_name' contains no mobile_devices, so showing all mobile_devices"
        fi

    fi
}

generate_computer_list() {
    # The Jamf Pro API returns a list of all computers.
    # first get the device count so we can find out how many loops we need
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"
    endpoint="api/preview/computers"
    url_filter="?page=0&page-size=1"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how many devices are there?
    total_count=$(/usr/bin/jq -r .totalCount "$curl_output_file")
    if [[ $total_count -eq 0 ]]; then
        echo "No computers found"
        exit 1
    fi
    echo "Total computers found: $total_count"

    # we need to run multiple loops to get all the devices if there are more than 100
    # calculate how many loops we need
    loop_count=$((total_count / 100))
    if ((total_count % 100 > 0)); then
        loop_count=$((loop_count + 1))
    fi
    echo "Will loop through $loop_count times to get all computers."

    # now loop through
    combined_output_file="$output_location/jamf_computer_list_combined.json"
    echo '{"results":[]}' >"$combined_output_file"
    i=0
    while [[ $i -lt $loop_count ]]; do
        # set the page number
        endpoint="api/preview/computers"
        url_filter="?page=$i&page-size=100&sort=id"
        curl_url="$jss_url/$endpoint/$url_filter"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
        # extract the results and append them to the combined output file
        /usr/bin/jq -s '
            {
              results: (.[0].results + .[1].results)
            }
            ' "$combined_output_file" "$curl_output_file" >"$combined_output_file.tmp" && mv "$combined_output_file.tmp" "$combined_output_file"
        ((i++))
    done

    # how big should the loop be?
    loopsize="$total_count"

    # now loop through
    i=0
    computer_ids=()
    computer_names=()
    management_ids=()
    serials=()
    computer_choice=()
    echo
    echo "Please wait while we process the list of computers..."
    echo
    while [[ $i -lt $loopsize ]]; do
        id_in_list=$(/usr/bin/jq -r .results.[$i].id "$combined_output_file")
        computer_name_in_list=$(/usr/bin/jq -r .results.[$i].name "$combined_output_file")
        management_id_in_list=$(/usr/bin/jq -r .results.[$i].managementId "$combined_output_file")
        serial_in_list=$(/usr/bin/jq -r .results.[$i].serialNumber "$combined_output_file")

        # echo "$computer_name_in_list ($id_in_list) - $serial_in_list" # TEMP

        computer_ids+=("$id_in_list")
        computer_names+=("$computer_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            computer_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<<"$serial" | wc -l)
                serial_count=$((count + 1))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$(cut -d, -f$j <<<"$serial")
                    if [[ "$serial_in_list" == "$serial_in_csv" ]]; then
                        computer_choice+=("$i")
                    fi
                    ((j++))
                done
            else
                if [[ "$serial_in_list" == "$serial" ]]; then
                    computer_choice+=("$i")
                fi
            fi
        elif [[ ${#computer_ids_in_group[@]} -gt 0 ]]; then
            for idx in "${computer_ids_in_group[@]}"; do
                if [[ $idx == "$id_in_list" ]]; then
                    computer_choice+=("$i")
                    break
                fi
            done
        else
            printf '%-5s %-9s %-16s %s\n' "($i)" "[id=$id_in_list]" "$serial_in_list" "$computer_name_in_list"
        fi
        ((i++))
    done

    if [ ${#computer_choice[@]} -eq 0 ]; then
        echo
        echo "Enter the ID(s) of the computer(s) above."
        read -r -p "Ranges can be provided, e.g. 0-4 : " computer_input
        # computers chosen
        for computer in $computer_input; do
            if [[ $computer == *"-"* ]]; then
                list_first=$(echo "$computer" | cut -d'-' -f1)
                list_last=$(echo "$computer" | cut -d'-' -f2)
                for ((i = list_first; i <= list_last; i++)); do
                    computer_choice+=("$i")
                done
            else
                computer_choice+=("$computer")
            fi
        done
    fi

    if [ ${#computer_choice[@]} -eq 0 ]; then
        echo "No ID or serial supplied"
        exit 1
    fi

    # show list of chosen computers
    echo
    echo "Computers chosen:"
    for computer in "${computer_choice[@]}"; do
        computer_id="${computer_ids[$computer]}"
        computer_name="${computer_names[$computer]}"
        computer_serial="${serials[$computer]}"
        printf '%-7s %-16s %s\n' "[id=$computer_id]" "$computer_serial" "$computer_name"
    done
}

generate_mobile_device_list() {
    # The Jamf Pro API returns a list of all mobile devices.

    # first get the device count so we can find out how many loops we need
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    jss_url="$jss_instance"
    endpoint="api/v2/mobile-devices"
    url_filter="?page=0&page-size=1"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how many devices are there?
    total_count=$(/usr/bin/jq -r .totalCount "$curl_output_file")
    if [[ $total_count -eq 0 ]]; then
        echo "No computers found"
        exit 1
    fi
    echo "Total computers found: $total_count"

    # we need to run multiple loops to get all the devices if there are more than 100
    # calculate how many loops we need
    loop_count=$((total_count / 100))
    if ((total_count % 100 > 0)); then
        loop_count=$((loop_count + 1))
    fi
    echo "Will loop through $loop_count times to get all computers."

    # now loop through
    echo '{"results":[]}' >"$combined_output_file"
    i=0
    while [[ $i -lt $loop_count ]]; do
        # set the page number
        page_number=$((i * 100))
        url_filter="?page=$page_number&page-size=100&sort=id"
        curl_url="$jss_url/$endpoint/$url_filter"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
        # append the results to the output file, ensuring only to append the results
        # if this is the first loop, we need to create the file
        combined_output_file="$output_location/jamf_mobile_device_list_combined.json"
        # extract the results and append them to the combined output file
        /usr/bin/jq -s '
            {
              results: (.[0].results + .[1].results)
            }
            ' "$combined_output_file" "$curl_output_file" >"$combined_output_file.tmp" && mv "$combined_output_file.tmp" "$combined_output_file"
        ((i++))
    done

    # how big should the loop be?
    loopsize="$total_count"

    # now loop through
    i=0
    mobile_device_ids=()
    mobile_device_names=()
    management_ids=()
    serials=()
    mobile_device_choice=()
    echo
    while [[ $i -lt $loopsize ]]; do
        id_in_list=$(/usr/bin/jq -r .results.[$i].id "$combined_output_file")
        mobile_device_name_in_list=$(/usr/bin/jq -r .results.[$i].name "$combined_output_file")
        management_id_in_list=$(/usr/bin/jq -r .results.[$i].managementId "$combined_output_file")
        serial_in_list=$(/usr/bin/jq -r .results.[$i].serialNumber "$combined_output_file")

        mobile_device_ids+=("$id_in_list")
        mobile_device_names+=("$mobile_device_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            mobile_device_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<<"$serial" | wc -l)
                serial_count=$((count + 1))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$(cut -d, -f$j <<<"$serial")
                    if [[ "$serial_in_list" == "$serial_in_csv" ]]; then
                        mobile_device_choice+=("$i")
                    fi
                    ((j++))
                done
            else
                if [[ "$serial_in_list" == "$serial" ]]; then
                    mobile_device_choice+=("$i")
                fi
            fi
        elif [[ ${#mobile_device_ids_in_group[@]} -gt 0 ]]; then
            for idx in "${mobile_device_ids_in_group[@]}"; do
                if [[ $idx == "$id_in_list" ]]; then
                    mobile_device_choice+=("$i")
                    break
                fi
            done
        else
            printf '%-5s %-9s %-16s %s\n' "($i)" "[id=$id_in_list]" "$serial_in_list" "$mobile_device_name_in_list"
        fi
        ((i++))
    done

    if [ ${#mobile_device_choice[@]} -eq 0 ]; then
        echo
        echo "Enter the ID(s) of the mobile_device(s) above."
        read -r -p "Ranges can be provided, e.g. 0-4 : " mobile_device_input
        # mobile_devices chosen
        for mobile_device in $mobile_device_input; do
            if [[ $mobile_device == *"-"* ]]; then
                list_first=$(echo "$mobile_device" | cut -d'-' -f1)
                list_last=$(echo "$mobile_device" | cut -d'-' -f2)
                for ((i = list_first; i <= list_last; i++)); do
                    mobile_device_choice+=("$i")
                done
            else
                mobile_device_choice+=("$mobile_device")
            fi
        done
    fi

    if [ ${#mobile_device_choice[@]} -eq 0 ]; then
        echo "No ID or serial supplied"
        exit 1
    fi

    # show list of chosen mobile_devices
    echo
    echo "mobile_devices chosen:"
    for mobile_device in "${mobile_device_choice[@]}"; do
        mobile_device_id="${mobile_device_ids[$mobile_device]}"
        mobile_device_name="${mobile_device_names[$mobile_device]}"
        mobile_device_serial="${serials[$mobile_device]}"
        printf '%-7s %-16s %s\n' "[id=$mobile_device_id]" "$mobile_device_serial" "$mobile_device_name"
    done
}

get_api_object_type() {
    local api_xml_object=$1

    case "$api_xml_object" in
    advanced_computer_search) api_object_type="advancedcomputersearches" ;;
    advanced_mobile_device_search) api_object_type="advancedmobiledevicesearches" ;;
    category) api_object_type="categories" ;;
    configuration_profile) api_object_type="mobiledeviceconfigurationprofiles" ;;
    group | user) api_object_type="accounts" ;;
    policy) api_object_type="policies" ;;
    restricted_software) api_object_type="restrictedsoftware" ;;
    *) api_object_type=$(echo "${api_xml_object}s" | sed 's|_||g') ;;

    esac
    echo "$api_object_type"
}

get_plural_from_api_xml_object() {
    local api_xml_object=$1

    case "$api_xml_object" in
    advanced_computer_search) api_xml_object_plural="advanced_computer_searches" ;;
    advanced_mobile_device_search) api_xml_object_plural="advanced_mobile_device_searches" ;;
    category) api_xml_object_plural="categories" ;;
    policy) api_xml_object_plural="policies" ;;
    restricted_software) api_xml_object_plural="restricted_software" ;;
    *) api_xml_object_plural="${api_xml_object}s" ;;
    esac
    echo "$api_xml_object_plural"
}

get_api_object_from_type() {
    local api_object_type=$1

    # shellcheck disable=SC2001
    case "$api_object_type" in
    advancedcomputersearches) api_xml_object="advanced_computer_search" ;;
    advancedmobiledevicesearches) api_xml_object="advanced_mobile_device_search" ;;
    categories) api_xml_object="category" ;;
    computerextensionattributes) api_xml_object="computer_extension_attribute" ;;
    computergroups) api_xml_object="computer_group" ;;
    distributionpoints) api_xml_object="distribution_point" ;;
    dockitems) api_xml_object="dock_item" ;;
    ldapservers) api_xml_object="ldap_server" ;;
    macapplications) api_xml_object="mac_application" ;;
    mobiledeviceapplications) api_xml_object="mobile_device_application" ;;
    mobiledeviceconfigurationprofiles) api_xml_object="configuration_profile" ;;
    mobiledeviceextensionattributes) api_xml_object="mobile_device_extension_attribute" ;;
    mobiledevicegroups) api_xml_object="mobile_device_group" ;;
    osxconfigurationprofiles) api_xml_object="os_x_configuration_profile" ;;
    policies) api_xml_object="policy" ;;
    restrictedsoftware) api_xml_object="restricted_software" ;;
    smtpserver) api_xml_object="smtp_server" ;;
    *) api_xml_object=$(sed 's|s$||' <<<"$api_object_type") ;;
    esac
    echo "$api_xml_object"
}

find_all_internet_passwords() {
    local server="$1"
    local count=0
    local in_inet_entry=false
    local matching_entries=()
    local instance_base="${server/*:\/\//}"

    echo "   [find_all_internet_passwords] Searching for all internet passwords with server: $server"

    # Get raw keychain data and process it
    while IFS= read -r line; do
        if [[ "$line" =~ keychain: ]]; then
            # current_keychain="$line"  # Not used, but kept for potential debugging
            :
        elif [[ "$line" =~ class:.*inet ]]; then
            in_inet_entry=true
            current_entry=""
        elif [[ "$in_inet_entry" == true ]]; then
            current_entry+="$line"$'\n'
            # echo "$instance_base ($jss_api_user)" # DEBUG
            if [[ "$line" =~ "0x00000007 <blob>".*"$instance_base (".*")" ]]; then
                ((count++))
                # echo "Entry #$count found in $current_keychain"
                matching_entries+=("$(echo "$current_entry" | grep -E '0x00000007 <blob>' | sed 's/.*<blob>="\([^"]*\)".*/\1/' | sed 's/.*(\([^)]*\)).*/\1/')")
            fi

            if [[ -z "$line" ]]; then
                in_inet_entry=false
                current_entry=""
            fi
        fi
    done < <(/usr/bin/security dump-keychain)

    echo "   [find_all_internet_passwords] Total entries found: $count"
    # Set chosen_account based on the number of matches
    chosen_account=""
    if [ $count -eq 0 ]; then
        echo "   [find_all_internet_passwords] No entries found for server: $server"
        return 1
    elif [ $count -eq 1 ]; then
        chosen_account="${matching_entries[0]}"
        echo "   [find_all_internet_passwords] Single entry found, using account: $chosen_account"
    elif [ $count -gt 1 ]; then
        echo "   [find_all_internet_passwords] Multiple entries found for server $server:"
        echo "   [find_all_internet_passwords] ${matching_entries[*]}"
        echo "   [find_all_internet_passwords] Checking for matching display name"
        echo
        if [[ $no_interaction -eq 1 ]]; then
            echo "   [find_all_internet_passwords] No interaction mode enabled, cannot choose between multiple entries."
            return 2
        fi
        echo "Please choose an account to use:"
        select chosen_account in "${matching_entries[@]}"; do
            if [[ -n "$chosen_account" ]]; then
                echo
                echo "   [find_all_internet_passwords] You selected: $chosen_account"
                break
            else
                echo "   [find_all_internet_passwords] Invalid selection. Please try again."
            fi
        done
    fi
}

set_platform_api_credentials() {
    api_base_url="$1"
    platform_api_client_id="$2"

    if [[ $verbose -gt 0 ]]; then
        echo "   [set_platform_api_credentials] Setting credentials for $api_base_url"
    fi

    instance_base="${api_base_url/*:\/\//}"

    if [[ $platform_api_client_id ]]; then
        # use supplied Client ID
        if [[ $verbose -gt 0 ]]; then
            echo "   [set_platform_api_credentials] Using supplied Client ID: $platform_api_client_id"
        fi
    else
        if [[ $verbose -gt 0 ]]; then
            echo "   [set_platform_api_credentials] No Client ID supplied, checking keychain for entry for $api_base_url (you will be prompted if multiple entries exist)"
        fi
        # check for Client ID entry in login keychain
        find_all_internet_passwords "$api_base_url"
        find_result=$?
        if [[ $find_result -eq 1 ]]; then
            echo "   [set_platform_api_credentials] No Client ID found for $api_base_url in keychain"
            exit 1
        elif [[ $find_result -eq 2 ]]; then
            echo "   [set_platform_api_credentials] Multiple Client IDs found for $api_base_url in keychain, but no interaction allowed"
            exit 1
        fi
        platform_api_client_id="$chosen_account"
    fi

    if [[ ! $platform_api_client_id ]]; then
        echo "   [set_platform_api_credentials] No keychain entry for $api_base_url found. Please run the set_platformapi_credentials.sh script to add the Client ID to your keychain"
        exit 1
    fi

    # check for secret entry in login keychain
    platform_api_client_secret=$(/usr/bin/security find-internet-password -s "$api_base_url" -l "$instance_base ($platform_api_client_id)" -a "$platform_api_client_id" -w -g 2>&1)

    if [[ $platform_api_client_secret ]]; then
        if [[ $verbose -gt 0 ]]; then
            echo "   [set_platform_api_credentials] Found Client Secret for $platform_api_client_id"
        fi
    else
        echo "   [set_platform_api_credentials] No Client Secret for $platform_api_client_id found. Please run the set_platformapi_credentials.sh script to add the Client Secret to your keychain"
        exit 1
    fi

    # echo "$platform_api_client_id:$platform_api_client_secret"  # UNCOMMENT-TO-DEBUG
}

check_if_paginated() {
    # echo "   [check_if_paginated] API base URL: $api_base_url" # TEMP
    # do a call to see if the endpoint is paginated

    if [[ $api_base_url == *".apigw.jamf.com"* ]]; then
        echo "   [check_if_paginated] Detected Platform API endpoint."
        check_platform_api_token
        curl_url="$api_base_url/$endpoint"
    else
        echo "   [check_if_paginated] Detected Jamf Pro API endpoint."
        if ! check_token; then
            return 1
        fi
        curl_url="$jss_instance/$endpoint"
    fi

    # remove any double-slashes from the URL (except for the https:// part)
    curl_url=$(echo "$curl_url" | sed 's|^\(https://\)/\{2,\}|\1/|' | sed 's|/\{2,\}|/|g')

    curl_cmd=(curl
        --location
        --silent
        --show-error
        --dump-header "$curl_headers_file"
        --request GET
        "$curl_url"
        --header "authorization: Bearer $token"
        --header 'Accept: application/json'
        --write-out "%{http_code}"
        --cookie "$cookie_jar"
        --cookie-jar "$cookie_jar"
        --output "$curl_output_file")

    echo "   [check_if_paginated] Curl command sent:"
    printf 'curl'
    for arg in "${curl_cmd[@]:1}"; do
        printf ' %q' "$arg"
    done
    printf '\n'

    if ! http_response=$("${curl_cmd[@]}"); then
        echo "   [check_if_paginated] ERROR: Failed to connect to the API."
        return 1
    fi
    # extract the token from the response
    if [[ "$http_response" -ge 400 ]]; then
        echo "   [check_if_paginated] ERROR: Failed to get a response from the API. HTTP response code: $http_response"
        if [[ -s "$token_file" ]]; then
            echo "   [check_if_paginated] Response:"
            cat "$token_file"
            echo
        fi
        return 1
    fi
    # check if the output includes a 'totalCount' key
    if jq -e .totalCount "$curl_output_file" >/dev/null; then
        paginated="true"
        total_count=$(/usr/bin/jq -r .totalCount "$curl_output_file")
        echo "   [check_if_paginated] Endpoint is paginated. Total count: $total_count"
    else
        paginated="false"
        echo "   [check_if_paginated] Endpoint is not paginated."
    fi
}

get_platform_api_token() {
    # get a token from the Platform API
    if ! http_response=$(curl \
        --silent \
        --show-error \
        --dump-header "$curl_headers_file" \
        --request POST \
        "$api_base_url/auth/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "client_id=$platform_api_client_id" \
        --data-urlencode "client_secret=$platform_api_client_secret" \
        --write-out "%{http_code}" \
        --output "$token_file"); then
        echo "   [get_platform_api_token] ERROR: Failed to connect to the Platform API."
        return 1
    fi
    # get the HTTP response code
    # echo "HTTP response: $http_response" # TEMP

    if [[ "$http_response" -ne 200 ]]; then
        echo "   [get_platform_api_token] ERROR: Failed to get token from the Platform API. HTTP response code: $http_response"
        if [[ -s "$token_file" ]]; then
            echo "   [get_platform_api_token] Response:"
            cat "$token_file"
            rm -f "$token_file"
            echo
            echo "   [get_platform_api_token] Curl command used:"
            echo "curl --request POST $api_base_url/auth/token --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'grant_type=client_credentials' --data-urlencode 'client_id=$platform_api_client_id' --data-urlencode 'client_secret=********' --output $token_file"
            echo
        fi
        return 1
    fi

    # check token is valid
    token=$(cat "$token_file" | jq -r '.access_token')
    if [[ "$token" == "null" || -z "$token" ]]; then
        echo "   [get_platform_api_token] ERROR: Failed to retrieve access token. Please check your credentials."
        return 1
    fi
    if [[ $verbose -eq 1 ]]; then
        echo "   [get_platform_api_token] Token: $token"
        echo "   [get_platform_api_token] Token file: $token_file"
    fi

    # save the server and user to the check files
    echo "$api_base_url" >"$server_check_file"
    echo "$platform_api_client_id" >"$user_check_file"
}

check_platform_api_token() {
    instance_id=$(echo "$api_base_url" | sed 's|https://||' | sed 's|:|_|g' | sed 's|/|_|g' | sed 's|\.|_|g')
    token_file="$output_location/jamf_platform_api_token_${instance_id}_${platform_api_client_id}.txt"
    server_check_file="$output_location/jamf_server_check_${instance_id}_${platform_api_client_id}.txt"
    user_check_file="$output_location/jamf_user_check_${instance_id}_${platform_api_client_id}.txt"
    curl_output_file="$output_location/output_${instance_id}_${platform_api_client_id}.txt"
    curl_headers_file="$output_location/headers_${instance_id}_${platform_api_client_id}.txt"
    cookie_jar="$output_location/jamf_cookie_jar_${instance_id}_${platform_api_client_id}.txt"

    # is there a token file
    if [[ -f "$token_file" ]]; then
        # check we are still querying the same server and with the same account
        server_check=$(cat "$server_check_file" 2>/dev/null)
        user_check=$(cat "$user_check_file" 2>/dev/null)
        if [[ "$server_check" == "$api_base_url" && "$user_check" == "$platform_api_client_id" ]]; then
            if jq -e .access_token "$token_file" >/dev/null; then
                token=$(jq -r .access_token "$token_file")
                echo "   [check_platform_api_token] Using stored token for $api_base_url at $token_file"
                if jq -e .expires_in "$token_file" >/dev/null; then
                    expires=$(jq -r .expires_in "$token_file")
                    current_time_epoch=$(/bin/date +%s)
                    file_created_epoch=$(/usr/bin/stat -f %m "$token_file")
                    cutoff_epoch=$((file_created_epoch + expires - 1))
                else
                    echo "   [check_platform_api_token] No expiry date found in $token_file. Grabbing a new one"
                    cutoff_epoch="0"
                fi
                if [[ $cutoff_epoch -gt $current_time_epoch ]]; then
                    # convert epoch to human readable
                    human_cutoff_time=$(/bin/date -r "$cutoff_epoch")
                    if [[ $verbose -gt 0 ]]; then
                        echo "   [check_platform_api_token] Token is still valid (expires at $human_cutoff_time)"
                    fi
                else
                    if [[ $verbose -gt 0 ]]; then
                        echo "   [check_platform_api_token] Token expired or invalid ($cutoff_epoch v $current_time_epoch). Grabbing a new one"
                    fi
                    sleep 1
                    get_platform_api_token
                fi
            else
                echo "   [check_platform_api_token] No token found in $token_file. Grabbing a new one"
                get_platform_api_token
            fi
        elif [[ "$server_check" == "$api_base_url" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "   [check_platform_api_token] '$user_check' does not match '$platform_api_client_id'. Grabbing a new token"
            fi
            sleep 1
            get_platform_api_token
        elif [[ "$user_check" == "$platform_api_client_id" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "   [check_platform_api_token] '$server_check' does not match '$api_base_url'. Grabbing a new token"
            fi
            sleep 1
            get_platform_api_token
        else
            if [[ $verbose -gt 0 ]]; then
                echo "   [check_platform_api_token] '$user_check' does not match '$platform_api_client_id', and '$server_check' does not match '$api_base_url'. Grabbing a new token."
            fi
            sleep 1
            get_platform_api_token
        fi
    else
        if [[ $verbose -gt 0 ]]; then
            echo "   [check_platform_api_token] No token found. Grabbing a new one"
        fi
        get_platform_api_token
    fi
    export token
}

get_platform_api_region() {
    local instance_url="$1"
    echo "   [get_platform_api_region] Instance: $instance_url"
    # check for .txt files in the platform-api-instance-lists directory and
    # see if the chosen instance is in one of those files
    finding_instance=0
    for instance_list in platform-api-instance-lists/*.txt; do
        if grep -q "^$instance_url$" "$instance_list"; then
            finding_instance=1
            # region is the name of the file without path or extension
            chosen_region=$(basename "$instance_list" | cut -d'.' -f1)
            break
        fi
    done
    if [[ $finding_instance -eq 0 ]]; then
        echo "   [get_platform_api_region] Chosen instance ($instance_url) not found in any platform-api-instance-lists/*.txt file - asking for region"
        return 1
    fi
    echo "   [get_platform_api_region] Region: $chosen_region"
    echo
}

get_region_url() {
    case $chosen_region in
    us)
        api_base_url="https://us.apigw.jamf.com"
        ;;
    eu)
        api_base_url="https://eu.apigw.jamf.com"
        ;;
    apac)
        api_base_url="https://apac.apigw.jamf.com"
        ;;
    *)
        echo "ERROR: Invalid region specified. Please use one of: us, eu, apac."
        exit 1
        ;;
    esac
    if [[ $verbose -gt 0 ]]; then
        echo "   [get_region_url] API Base URL: $api_base_url"
    fi
}

handle_platform_api_get_request() {
    # handle Platform API GET requests that may require looping through multiple pages

    # local variables to pass in
    local endpoint="$1"
    local sort_or_filter="$2"
    local key="$3"
    local match="$4"

    if [[ -z $endpoint ]]; then
        echo "   [handle_platform_api_get_request] No endpoint provided for handle_platform_api_get_request"
        return 1
    fi

    # if endpoint already includes a filter, or if the endpoint includes an ID we cannot add another one
    # the ID could be any keyname but will always follow /api/v[number]/resourceName/<ID> or /api/apiType/v[number]/resourceName/<ID>
    # so we check that there are more than 1 slashes in the endpoint after the /v[number] part

    # Count number of slashes after the /v[number] part
    # Find the position of /v[digits] in the endpoint
    vpos=$(awk -v str="$endpoint" 'BEGIN{match(str, /\/v[0-9]+/); print RSTART+RLENGTH-1}')
    if [[ $vpos -gt 0 ]]; then
        # Get substring after /v[number]
        rest="${endpoint:$vpos}"
        slash_count=$(grep -o "/" <<<"$rest" | wc -l)
    else
        slash_count=$(grep -o "/" <<<"$endpoint" | wc -l)
    fi
    if [[ $slash_count -gt 1 ]]; then
        echo "   [handle_platform_api_get_request] Endpoint already includes an ID or other subfilter, cannot add sort or filter"
        filter_type="preset"
    # if there are parameters already in the endpoint, we cannot add more
    # we check for /? in the endpoint
    elif [[ "$endpoint" == *"/?"* || "$endpoint" == *"?"* ]]; then
        echo "   [handle_platform_api_get_request] Endpoint already includes parameters, cannot add more"
        filter_type="preset"
    elif [[ "$sort_or_filter" == "sort" ]]; then
        filter_type="sort"
        if [[ -z $key ]]; then
            echo "   [handle_platform_api_get_request] No sort key provided for handle_platform_api_get_request, using id as default sorting method"
            key="id"
        fi
    elif [[ "$sort_or_filter" == "filter" ]]; then
        if [[ ! "$key" || ! "$match" ]]; then
            echo "   [handle_platform_api_get_request] ERROR: No filter key or match provided for handle_platform_api_get_request"
            exit 1
        fi
    else
        echo "   [handle_platform_api_get_request] No sort or filter type provided for handle_platform_api_get_request, using id as default sorting method"
        filter_type="none"
    fi

    if [[ $filter_type == "sort" || $filter_type == "none" ]]; then
        # first check if the endpoint is paginated
        set_platform_api_credentials "$api_base_url" "$platform_api_client_id"
        check_if_paginated
        if [[ "$paginated" == "true" ]]; then
            url_filter="?page=0&page-size=1"
            curl_url="$api_base_url$endpoint$url_filter"
            curl_args=("--request")
            curl_args+=("GET")
            curl_args+=("--header")
            curl_args+=("Accept: application/json")
            send_curl_request

            # we need to run multiple loops to get all the devices if there are more than 1000
            # calculate how many loops we need
            loop_count=$((total_count / 100))
            if ((total_count % 100 > 0)); then
                loop_count=$((loop_count + 1))
            fi
            echo "   [handle_platform_api_get_request] Will loop through $loop_count times to get all items."

            # now loop through
            i=0
            combined_output=""
            while [[ $i -lt $loop_count ]]; do
                echo "   [handle_platform_api_get_request] Processing page $i of $loop_count..."
                # set the page number

                url_filter="?page=$i&page-size=100"
                if [[ "$filter_type" == "sort" && "$key" ]]; then
                    url_filter="$url_filter&sort=$key"
                fi
                curl_url="$api_base_url$endpoint$url_filter"
                curl_args=("--request")
                curl_args+=("GET")
                curl_args+=("--header")
                curl_args+=("Accept: application/json")
                send_curl_request
                # cat "$curl_output_file" # TEMP
                # append the results array to the combined_results array (do not export to a file)
                combined_output+=$(cat "$curl_output_file")
                # echo "$combined_output" > /tmp/combined_output.txt # TEMP
                ((i++))
            done
            echo "   [handle_platform_api_get_request] All pages processed."
        else
            echo "   [handle_platform_api_get_request] Endpoint is not paginated, using existing request."
            combined_output=$(cat "$curl_output_file")
        fi
    else
        set_platform_api_credentials "$api_base_url"
        # filter based on a key=match pair
        if [[ "$filter_type" == "preset" ]]; then
            # if preset, the endpoint already includes the filter so we do not need to add anything
            curl_url="$api_base_url$endpoint"
        else
            # url-encode the key without using python3
            match_encoded=$(printf "%s" "$match" | jq -s -R -r @uri)
            url_filter="?filter=$key%3D%3D%22$match_encoded%22"
            curl_url="$api_base_url$endpoint$url_filter"
        fi
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
        combined_output=$(cat "$curl_output_file")
    fi
}

# ===============================================================================
# PARALLEL JOB RUNNER
# ===============================================================================
# A generic, bash-3.2-safe runner for launching independent units of work across
# multiple instances (or recipes) concurrently, with per-job logging, a
# concurrency throttle, live progress, and clean Ctrl-C teardown.
#
# macOS ships bash 3.2: no associative arrays and no `wait -n`. State is keyed by
# integer job index into indexed arrays, and completion is tracked via a shared
# sentinel file rather than `wait -n`. This design is portable to any newer shell
# without change.
#
# Two layers:
#   run_parallel_jobs   - generic core; you supply the job tokens and a worker fn
#   run_autopkg_parallel- convenience wrapper for "one recipe across N instances"
# ===============================================================================

# Extract a short, stable label from a Jamf Pro URL (the subdomain), e.g.
# https://customer.jamfcloud.com -> "customer". Used as the default job label.
parallel_instance_shortname() {
    local url="$1"
    local tmp="${url#*://}"  # strip protocol
    tmp="${tmp%%/*}"          # strip path
    tmp="${tmp%%:*}"          # strip port
    echo "${tmp%%.*}"         # first domain component only
}

# Recursively send a signal to a PID and all of its descendants. Background jobs
# spawn autopkg-run.sh, which spawns python; killing only the recorded job PID
# would orphan those children.
if ! declare -f kill_tree >/dev/null 2>&1; then
kill_tree() {
    local pid="$1"
    local sig="${2:-TERM}"
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child" "$sig"
    done
    kill -"$sig" "$pid" 2>/dev/null
}
fi

# INT/TERM handler installed by run_parallel_jobs. Tears down every background
# worker (and its process tree), the live-tail, and the dialog monitor, then
# exits. Background jobs started with & ignore SIGINT in a non-interactive shell,
# so the terminal Ctrl-C never reaches them on its own — forward SIGTERM here.
_parallel_terminate() {
    echo >&2
    echo "   [run_parallel_jobs] Interrupt received — stopping all background jobs..." >&2
    local pid
    for pid in "${_PARALLEL_BG_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill_tree "$pid" TERM
    done
    # Stop the tail supervisor loop relaunching, then kill it (its EXIT trap
    # kills the live tail child).
    [[ -n "${_PARALLEL_TAIL_STOP:-}" ]] && : > "$_PARALLEL_TAIL_STOP" 2>/dev/null
    [[ -n "${_PARALLEL_TAIL_PID:-}" ]] && kill "$_PARALLEL_TAIL_PID" 2>/dev/null
    [[ -n "${_PARALLEL_MONITOR_PID:-}" ]] && kill "$_PARALLEL_MONITOR_PID" 2>/dev/null
    sleep 1  # give children a moment, then escalate any survivors
    for pid in "${_PARALLEL_BG_PIDS[@]}"; do
        [[ -n "$pid" ]] && kill_tree "$pid" KILL
    done
    echo "   [run_parallel_jobs] All background jobs stopped." >&2
    exit 130
}

# Restore whatever INT/TERM traps were in place before run_parallel_jobs ran.
_parallel_restore_traps() {
    if [[ -n "${_parallel_prev_int_trap:-}" ]]; then
        eval "$_parallel_prev_int_trap"
    else
        trap - INT
    fi
    if [[ -n "${_parallel_prev_term_trap:-}" ]]; then
        eval "$_parallel_prev_term_trap"
    else
        trap - TERM
    fi
}

# Block until fewer than $1 background workers are still alive. Prunes dead PIDs
# from _PARALLEL_BG_PIDS as it goes (dead PIDs need no teardown). bash 3.2 has no
# `wait -n`, so poll with kill -0.
_parallel_throttle() {
    local max="$1"
    local p alive
    local still
    while true; do
        alive=0
        still=()
        for p in "${_PARALLEL_BG_PIDS[@]}"; do
            if kill -0 "$p" 2>/dev/null; then
                still+=("$p")
                alive=$((alive + 1))
            fi
        done
        _PARALLEL_BG_PIDS=("${still[@]}")
        [[ $alive -lt $max ]] && break
        sleep 0.3
    done
}

# Background monitor for the swiftDialog reporter. Watches the completion sentinel
# file and pushes progress + progresstext commands to the dialog command file.
# Writes the swiftDialog command protocol directly (echo ... >> file), so it has
# no dependency on the msp-toolkit dialog_command helper.
_parallel_dialog_monitor() {
    local total="$1" dlog="$2" completed_file="$3" title="$4"
    local done_count=0
    while true; do
        if [[ -f "$completed_file" ]]; then
            done_count=$(grep -c . "$completed_file" 2>/dev/null)
            [[ "$done_count" =~ ^[0-9]+$ ]] || done_count=0
        fi
        echo "progress: $(( done_count * 100 / total ))" >> "$dlog"
        echo "progresstext: ${title} (${done_count} of ${total} complete)" >> "$dlog"
        [[ $done_count -ge $total ]] && break
        sleep 0.5
    done
}

# run_parallel_jobs — launch a set of independent jobs concurrently.
#
# Flags:
#   --job <token>          repeatable; opaque string passed to the worker
#   --worker <fn>          required; shell function name, called: <fn> <token> <idx>
#   --log-dir <dir>        required; holds per-job logs and sentinel files
#   --label-fn <fn>        optional; maps a token to a short label
#                          (default: parallel_instance_shortname). The label is
#                          used in per-job log filenames, so it MUST be
#                          filename-safe (no slashes or spaces).
#   --max-concurrent <n>   optional; default 8
#   --reporter <mode>      optional; terminal | dialog | none (default terminal)
#   --dialog-log <file>    required when --reporter dialog; swiftDialog command file
#   --title <text>         optional; progress title for the dialog reporter
#
# The worker's exit code becomes the job status. Worker stdout/stderr go to the
# job's log file. Results are returned via globals:
#   PARALLEL_PASS_LABELS[]  labels of jobs that exited 0
#   PARALLEL_FAIL_LABELS[]  labels of jobs that exited non-zero
#   PARALLEL_JOB_STATUS[idx] exit code per job index
# Returns 0 if every job passed, 1 otherwise.
run_parallel_jobs() {
    local worker="" log_dir="" label_fn="parallel_instance_shortname"
    local max_concurrent=8 reporter="terminal" dialog_log="" title="Processing"
    local jobs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --job) shift; jobs+=("$1") ;;
        --worker) shift; worker="$1" ;;
        --log-dir) shift; log_dir="$1" ;;
        --label-fn) shift; label_fn="$1" ;;
        --max-concurrent) shift; max_concurrent="$1" ;;
        --reporter) shift; reporter="$1" ;;
        --dialog-log) shift; dialog_log="$1" ;;
        --title) shift; title="$1" ;;
        *) echo "run_parallel_jobs: unknown argument '$1'" >&2; return 2 ;;
        esac
        shift
    done

    if [[ -z "$worker" ]]; then
        echo "run_parallel_jobs: --worker is required" >&2; return 2
    fi
    if [[ -z "$log_dir" ]]; then
        echo "run_parallel_jobs: --log-dir is required" >&2; return 2
    fi
    if ! [[ "$max_concurrent" =~ ^[0-9]+$ ]] || [[ "$max_concurrent" -lt 1 ]]; then
        max_concurrent=8
    fi
    mkdir -p "$log_dir"

    PARALLEL_PASS_LABELS=()
    PARALLEL_FAIL_LABELS=()
    PARALLEL_JOB_STATUS=()

    local total=${#jobs[@]}
    if [[ $total -eq 0 ]]; then
        return 0
    fi

    local completed_file="${log_dir}/.parallel_completed"
    : > "$completed_file"

    # Reset teardown state and install the interrupt handler, saving any existing
    # INT/TERM traps so they can be restored on normal completion.
    _PARALLEL_BG_PIDS=()
    _PARALLEL_TAIL_PID=""
    _PARALLEL_TAIL_STOP=""
    _PARALLEL_MONITOR_PID=""
    _parallel_prev_int_trap=$(trap -p INT)
    _parallel_prev_term_trap=$(trap -p TERM)
    trap _parallel_terminate INT TERM

    local job_pids=()
    local job_logs=()
    local job_labels=()
    local idx token label log_file status_file

    # Pre-pass: derive each job's label and log/status paths and create the log
    # files up front. This lets the progress reporter attach BEFORE the launch
    # loop — the launch loop can block in _parallel_throttle when there are more
    # jobs than slots, and a reporter started after it would miss all output
    # from the first batch (which runs, and may finish, while later jobs queue).
    for (( idx = 0; idx < total; idx++ )); do
        token="${jobs[$idx]}"
        label=$("$label_fn" "$token")
        job_labels[$idx]="$label"
        log_file="${log_dir}/.parallel_${idx}_${label}.log"
        status_file="${log_dir}/.parallel_${idx}.status"
        job_logs[$idx]="$log_file"
        : > "$log_file"
        rm -f "$status_file"
    done

    # Start the chosen progress reporter (all log files now exist, so tail -F can
    # attach to every one without a race, and the dialog monitor's sentinel poll
    # sees completions as they happen).
    if [[ "$reporter" == "terminal" ]]; then
        echo
        echo "   [run_parallel_jobs] Live progress (streams below as jobs run):"
        echo
        # Use a supervised tail so terminal visibility survives the whole run.
        # Two failure modes made the old single `tail -f` the sole point of
        # failure: (1) `-f` follows the open descriptor and can silently stop
        # emitting if a log is truncated/rotated; `-F` re-opens by name and keeps
        # going. (2) A one-off tail death (SIGPIPE, a sleep/wake tty hiccup) used
        # to black out all output while long jobs kept writing — so we run tail
        # inside a loop that relaunches it until asked to stop. A relaunch may
        # re-dump a log from the top (harmless duplication, and rare); silence
        # would be far worse.
        _PARALLEL_TAIL_STOP="${log_dir}/.parallel_tail_stop"
        rm -f "$_PARALLEL_TAIL_STOP"
        (
            tail_child=""
            trap 'kill "$tail_child" 2>/dev/null' EXIT TERM
            while [[ ! -f "$_PARALLEL_TAIL_STOP" ]]; do
                tail -n +1 -F "${job_logs[@]}" &
                tail_child=$!
                wait "$tail_child"
                [[ -f "$_PARALLEL_TAIL_STOP" ]] && break
                sleep 1
            done
        ) &
        _PARALLEL_TAIL_PID=$!
    elif [[ "$reporter" == "dialog" && -n "$dialog_log" ]]; then
        _parallel_dialog_monitor "$total" "$dialog_log" "$completed_file" "$title" &
        _PARALLEL_MONITOR_PID=$!
    fi

    # Launch loop: throttle to max_concurrent, then start each worker in the
    # background writing to its pre-created log file.
    for (( idx = 0; idx < total; idx++ )); do
        token="${jobs[$idx]}"
        label="${job_labels[$idx]}"
        log_file="${job_logs[$idx]}"
        status_file="${log_dir}/.parallel_${idx}.status"

        # Block until a concurrency slot frees up before launching the next job.
        _parallel_throttle "$max_concurrent"

        (
            "$worker" "$token" "$idx"
            rc=$?
            echo "$rc" > "$status_file"
            # Record completion (pass or fail) for the progress reporter.
            printf '%s\n' "$label" >> "$completed_file"
            exit "$rc"
        ) > "$log_file" 2>&1 &

        job_pids[$idx]="$!"
        _PARALLEL_BG_PIDS+=("$!")
    done

    # Wait for every worker to finish (by recorded PID, in launch order).
    for (( idx = 0; idx < total; idx++ )); do
        local pid="${job_pids[$idx]:-}"
        [[ -n "$pid" ]] && wait "$pid" 2>/dev/null
    done

    # Stop the reporters.
    if [[ -n "$_PARALLEL_TAIL_PID" ]]; then
        sleep 1  # allow tail to flush the final lines
        # Signal the supervisor loop to stop relaunching, then kill it; its EXIT
        # trap kills the live tail child.
        [[ -n "$_PARALLEL_TAIL_STOP" ]] && : > "$_PARALLEL_TAIL_STOP"
        kill "$_PARALLEL_TAIL_PID" 2>/dev/null
        wait "$_PARALLEL_TAIL_PID" 2>/dev/null
        [[ -n "$_PARALLEL_TAIL_STOP" ]] && rm -f "$_PARALLEL_TAIL_STOP"
    fi
    if [[ -n "$_PARALLEL_MONITOR_PID" ]]; then
        kill "$_PARALLEL_MONITOR_PID" 2>/dev/null
        wait "$_PARALLEL_MONITOR_PID" 2>/dev/null
    fi

    # Collect per-job results from the status sentinels.
    local overall=0 rc
    for (( idx = 0; idx < total; idx++ )); do
        status_file="${log_dir}/.parallel_${idx}.status"
        rc=$(cat "$status_file" 2>/dev/null)
        [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
        PARALLEL_JOB_STATUS[$idx]="$rc"
        if [[ "$rc" -eq 0 ]]; then
            PARALLEL_PASS_LABELS+=("${job_labels[$idx]}")
        else
            PARALLEL_FAIL_LABELS+=("${job_labels[$idx]}")
            overall=1
        fi
    done

    _parallel_restore_traps
    return $overall
}

# run_autopkg_parallel — convenience wrapper: run ONE recipe across many instances
# concurrently. Builds the job list and worker for you and calls run_parallel_jobs.
#
# Flags:
#   --recipe <id>          required; recipe identifier or path
#   --instance <url>       repeatable; the instances to run against
#   --key "KEY=value"      repeatable; --key passed to every run
#   --id <client-id/user>  optional; passed to autopkg-run.sh as --user
#   --verbosity <-v...>    optional; verbosity flag passed to autopkg-run.sh
#   --no-smb               optional; skip the distribution point (SMB) lookup in
#                          autopkg-run.sh. Safe for recipes with no package upload
#                          step (e.g. read-only object/inventory recipes) and faster.
#   --log-dir <dir>        required; per-instance logs and sentinels
#   --max-concurrent <n>   optional; default 8
#   --reporter <mode>      optional; terminal | dialog | none (default terminal)
#   --dialog-log <file>    required when --reporter dialog
#   --title <text>         optional; progress title for the dialog reporter
#
# Results come back in the same globals as run_parallel_jobs, with labels being
# instance shortnames.
run_autopkg_parallel() {
    _AP_RECIPE=""
    _AP_KEYS=()
    _AP_ID=""
    _AP_VERBOSITY=""
    _AP_NO_SMB=""
    local instances=()
    local log_dir="" max_concurrent=8 reporter="terminal" dialog_log="" title="Processing instances"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --recipe) shift; _AP_RECIPE="$1" ;;
        --instance) shift; instances+=("$1") ;;
        --key) shift; _AP_KEYS+=("$1") ;;
        --id | --client-id | --user | --username) shift; _AP_ID="$1" ;;
        --verbosity) shift; _AP_VERBOSITY="$1" ;;
        --no-smb) _AP_NO_SMB=1 ;;
        --log-dir) shift; log_dir="$1" ;;
        --max-concurrent) shift; max_concurrent="$1" ;;
        --reporter) shift; reporter="$1" ;;
        --dialog-log) shift; dialog_log="$1" ;;
        --title) shift; title="$1" ;;
        *) echo "run_autopkg_parallel: unknown argument '$1'" >&2; return 2 ;;
        esac
        shift
    done

    if [[ -z "$_AP_RECIPE" ]]; then
        echo "run_autopkg_parallel: --recipe is required" >&2; return 2
    fi
    if [[ ${#instances[@]} -eq 0 ]]; then
        echo "run_autopkg_parallel: at least one --instance is required" >&2; return 2
    fi

    # Build the run_parallel_jobs argument list.
    local rpj_args=(--worker _run_autopkg_worker --log-dir "$log_dir"
        --max-concurrent "$max_concurrent" --reporter "$reporter" --title "$title")
    [[ -n "$dialog_log" ]] && rpj_args+=(--dialog-log "$dialog_log")
    local url
    for url in "${instances[@]}"; do
        rpj_args+=(--job "$url")
    done

    run_parallel_jobs "${rpj_args[@]}"
}

# Worker used by run_autopkg_parallel. Reads recipe/keys/id/verbosity from the
# _AP_* globals (a backgrounded subshell inherits them at fork time). autopkg-run.sh
# performs its own per-instance credential lookup, so no set_credentials here.
_run_autopkg_worker() {
    local instance="$1"
    local args=(-r "$_AP_RECIPE" --instance "$instance" --nointeraction)
    [[ -n "$_AP_ID" ]] && args+=(--user "$_AP_ID")
    local k caller_set_cache_dir=""
    for k in "${_AP_KEYS[@]}"; do
        args+=(--key "$k")
        [[ "$k" == RECIPE_CACHE_DIR=* ]] && caller_set_cache_dir=1
    done
    # Every instance runs the SAME recipe, so autopkg computes the SAME default
    # RECIPE_CACHE_DIR for all of them. Concurrent runs then race on autopkg's
    # check-then-makedirs of that shared directory, and whichever workers lose
    # the race die with "[Errno 17] File exists". Give each instance its own
    # cache dir (unique leaf keyed by instance shortname) so there is no shared
    # path to race on. Skip if the caller already supplied a RECIPE_CACHE_DIR.
    if [[ -z "$caller_set_cache_dir" ]]; then
        local short
        short=$(parallel_instance_shortname "$instance")
        args+=(--key "RECIPE_CACHE_DIR=${HOME}/Library/AutoPkg/Cache/${_AP_RECIPE}/parallel-${short}")
    fi
    [[ -n "$_AP_NO_SMB" ]] && args+=(--no-smb)
    [[ -n "$_AP_VERBOSITY" ]] && args+=("$_AP_VERBOSITY")
    "$this_script_dir/autopkg-run.sh" "${args[@]}"
}
