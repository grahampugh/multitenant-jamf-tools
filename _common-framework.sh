#!/bin/bash
# shellcheck disable=SC2154

: <<'DOC'
This script is meant to be sourced in order to supply credentials and a token to Jamf Pro API scripts

You should only need lines like this before each send_curl_request:

    # Set the source server
    set_credentials "${source_instance}"
    # determine jss_url
    jss_url="${source_instance}"

    # send request
    curl_url="$jss_url/JSSResource/SOME-URL"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request
DOC

# remove history expansion
set +H

# Path to here
this_script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# variables

# temp files for tokens, cookies and headers
output_location="/tmp/jamf_pro_api"
mkdir -p "$output_location"

# token_file="$output_location/jamf_api_token.txt"
# server_check_file="$output_location/jamf_server_check.txt"
# user_check_file="$output_location/jamf_user_check.txt"

# cookie_jar="$output_location/jamf_cookie_jar.txt"
curl_output_file="$output_location/output.txt"
curl_headers_file="$output_location/headers.txt"

root_check() {
    # Check that the script is NOT running as root
    if [[ $EUID -eq 0 ]]; then
        echo "This script is NOT MEANT to run as root."
        echo "Please run without sudo."
        echo
        exit 4 # Running as root.
    else 
        # check that user is an admin
        if ! /usr/sbin/dseditgroup -o checkmember -m "$USER" admin ; then
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
        done < "$slack_webhook_file"
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
        done < <(find "$instance_lists_folder" -type f -name "*.txt" -not -name "default-instance-list.txt" -not -name "display-name-prefix-list.txt" -not -name "script-name-prefix-list.txt" -print0)
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
            if [[ $match -eq 0 ]] ; then
                if [[ $filename == "$chosen_instance_list_file" ]]; then
                    chosen_instance_list_filepath="$file"
                fi
                instance_list_files+=("$file")
                echo "[$i] $filename"
                ((i++))
            fi
        done < <(find "$default_instance_lists_folder" -type f -name "*.txt" -not -name "default-instance-list.txt" -not -name "display-name-prefix-list.txt" -not -name "script-name-prefix-list.txt" -print0)
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

        done < "$instance_list_file"
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
    else
        echo "Choose the instance list from the list above"
        if [[ -f "$default_instance_list" ]]; then
            echo "or press ENTER to choose list $default_instance_list_for_dialogs"
        fi
        read -r -p "Instance list : " instance_list
        echo
        if [[ $instance_list && -f "${instance_list_files[$instance_list]}" ]]; then
            instance_list_file="${instance_list_files[$instance_list]}"
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
        if grep -qe "[A-Za-z]" <<< "$instance_selection"; then
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
        elif grep -qe "[A-Za-z]" <<< "$instance_selection"; then
            for instance in "${working_instances_list[@]}"; do
                if [[ "$instance" == *"${instance_selection}."* || "$instance" == *"${instance_selection}-"* ]]; then
                    instance_choice_array+=("$instance")
                    break
                fi
            done
            if [[ ${#instance_choice_array[@]} -eq 0  ]]; then
                echo "ERROR: could not find matching instance"
                exit 1
            fi
        elif [[ "$instance_selection" ]]; then
            for instance in $instance_selection; do
                if [[ $instance == *"-"* ]]; then
                    list_first=$(echo "$instance" | cut -d'-' -f1)
                    list_last=$(echo "$instance" | cut -d'-' -f2)
                    for (( i=list_first; i<=list_last; i++ )); do
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
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"

    # Check for DPs
    # send request
    curl_url="$jss_url/JSSResource/distributionpoints"
    curl_args=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # get the results array, find out if there are more than one
    dp_count=$(xmllint --xpath "//distribution_points/size/text()" "$curl_output_file" 2>/dev/null)
    # if 0
    if [[ $dp_count -eq 0 ]]; then
        echo "No DP found - assuming JCDS"
        smb_url=""
    else
        # check if dp_url_filter has been written to the autopkg prefs
        if [[ -f "$autopkg_prefs" ]]; then
            dp_key=$(defaults read "$autopkg_prefs" dp_url_filter 2>/dev/null)
            if [[ "$dp_key" && ! "$dp_url_filter" ]]; then
                dp_url_filter="$dp_key"
            fi
        fi
        dp_names_list=$(xmllint --xpath "//distribution_points/distribution_point/name" "$curl_output_file" 2>/dev/null | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n")
        # loop through the DPs and check that we have credentials for them - only check the first one for now
        while read -r dp; do
            # echo "Distribution Point: $dp" # TEMP
            if [[ $dp_url_filter ]]; then
                if [[ $dp != *"$dp_url_filter"* ]]; then
                    echo "Skipping $dp"
                    continue
                fi
            fi
            # url encode the dp name
            url_encoded_dp=$(encode_name "$dp")
            # send request
            curl_url="$jss_url/JSSResource/distributionpoints/name/$url_encoded_dp"
            curl_args=("--header")
            curl_args+=("Accept: application/xml")
            send_curl_request
            # get settings
            dp_type=$(xmllint --xpath "//distribution_point/connection_type/text()" "$curl_output_file" 2>/dev/null)
            if [[ "$dp_type" == "AFP" ]]; then
                dp_protocol="afp"
            elif [[ "$dp_type" == "SMB" ]]; then
                dp_protocol="smb"
            fi
            dp_server=$(xmllint --xpath "//distribution_point/ip_address/text()" "$curl_output_file" 2>/dev/null)
            dp_share=$(xmllint --xpath "//distribution_point/share_name/text()" "$curl_output_file" 2>/dev/null)
            user_rw=$(xmllint --xpath "//distribution_point/read_write_username/text()" "$curl_output_file" 2>/dev/null)
            # pass_rw_sha256=$(xmllint --xpath "//distribution_point/read_write_password_sha256/text()" "$curl_output_file" 2>/dev/null)
            # we are only handling one right now, so exit the loop
            break
        done <<< "$dp_names_list"
        # smb url
        smb_url="$dp_protocol://$dp_server/$dp_share"
        smb_uri="$dp_server/$dp_share"
        # echo "SMB_URL: $smb_url" # TEMP
        # echo "SMB_USER: $user_rw" # TEMP
    # if > 1 # TODO
    fi
}

get_instance_distribution_point_new_api() {
    # find out if there is a file share distribution point in this instance
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="${jss_instance}"

    # Check for DPs
    # send request
    curl_url="$jss_url/v1/distribution-points"
    curl_args=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # get the results array, find out if there are more than one
    dp_count=$(plutil -extract totalCount raw "$curl_output_file")
    # if 0
    if [[ $dp_count -eq 0 ]]; then
        echo "No DP found - assuming JCDS"
        smb_url=""
    # if 1
    elif [[ $dp_count -eq 1 ]]; then
        dp_server=$(plutil -extract results.0.serverName raw "$curl_output_file")
        dp_type=$(plutil -extract results.0.fileSharingConnectionType raw "$curl_output_file")
        if [[ "$dp_type" == "AFP" ]]; then
            dp_protocol="afp"
            dp_share=$(plutil -extract results.0.AFPFileShare.shareName raw "$curl_output_file")
            user_rw=$(plutil -extract results.0.AFPFileShare.readWriteUsername raw "$curl_output_file")
            pass_rw=$(plutil -extract results.0.AFPFileShare.readWritePassword raw "$curl_output_file")
        elif [[ "$dp_type" == "SMB" ]]; then
            dp_protocol="smb"
            dp_share=$(plutil -extract results.0.SMBFileShare.shareName raw "$curl_output_file")
            # shellcheck disable=SC2034
            user_rw=$(plutil -extract results.0.SMBFileShare.readWriteUsername raw "$curl_output_file")
            # shellcheck disable=SC2034
            pass_rw=$(plutil -extract results.0.SMBFileShare.readWritePassword raw "$curl_output_file")
        fi
    # if > 1 # TODO
    fi
    # smb url
    smb_url="$dp_protocol://$dp_server/$dp_share"
    # shellcheck disable=SC2034
    smb_uri="$dp_server/$dp_share"
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
            smb_user=$(/usr/bin/grep "acct" <<< "$dp_check" | /usr/bin/cut -d \" -f 4)
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

    if get_slack_webhook "$instance_list_file"; then
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
    local jss_url="$1"
    if [[ $verbose -gt 0 ]]; then
        echo "Setting credentials for $jss_url"
    fi

    # check for username entry in login keychain
    # jss_api_user=$("${this_script_dir}/keychain.sh" -t internet -u -s "$jss_url")
    jss_api_user=$(/usr/bin/security find-internet-password -s "$jss_url" -g 2>/dev/null | /usr/bin/grep "acct" | /usr/bin/cut -d \" -f 4 )

    if [[ ! $jss_api_user ]]; then
        echo "No keychain entry for $jss_url found. Please run the set_credentials.sh script to add the user to your keychain"
        exit 1
    fi

    # check for password entry in login keychain
    # jss_api_password=$("${this_script_dir}/keychain.sh" -t internet -p -s "$jss_url")
    jss_api_password=$(/usr/bin/security find-internet-password -s "$jss_url" -a "$jss_api_user" -w -g 2>&1 )

    if [[ ! $jss_api_password ]]; then
        echo "No password/Client ID for $jss_api_user found. Please run the set_credentials.sh script to add the password/Client ID to your keychain"
        exit 1
    fi

    # encode the credentials so we are not sending in plain text
    b64_credentials=$(printf "%s:%s" "$jss_api_user" "$jss_api_password" | iconv -t ISO-8859-1 | base64 -i -)

    # echo "$jss_api_user:$jss_api_password"  # UNCOMMENT-TO-DEBUG
}

get_new_token() {
    # check if the user is a UUID (therefore implying a Client ID)
    if [[ $cred_type == "client-id" ]]; then
        http_response=$(
            curl --request POST \
            --silent \
            --url "$jss_url/api/oauth/token" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode "client_id=$jss_api_user" \
            --data-urlencode "grant_type=client_credentials" \
            --data-urlencode "client_secret=$jss_api_password" \
            --write-out "%{http_code}" \
            --header 'Accept: application/json' \
            --cookie-jar "$cookie_jar" \
            --output "$token_file"
        )
        if [[ $verbose -gt 0 ]]; then
            echo "Token request HTTP response: $http_response"
        fi
        if [[ $http_response -lt 400 ]]; then
            token=$(plutil -extract access_token raw "$token_file")
        else
            echo "Token download failed"
            exit 1
        fi
    else
        http_response=$(
            curl --request POST \
            --silent \
            --url "$jss_url/api/v1/auth/token" \
            --header "authorization: Basic $b64_credentials" \
            --write-out "%{http_code}" \
            --header 'Accept: application/json' \
            --cookie-jar "$cookie_jar" \
            --output "$token_file"
        )
        if [[ $verbose -gt 0 ]]; then
            echo "Token request HTTP response: $http_response"
        fi
        if [[ $http_response -lt 400 ]]; then
            token=$(plutil -extract token raw "$token_file")
        else
            echo "Token download failed"
            exit 1
        fi
    fi

    echo "${jss_url}" > "$server_check_file"
    echo "$jss_api_user" > "$user_check_file"

    if [[ $verbose -gt 0 ]]; then
        echo "Token for $jss_api_user on ${jss_url} written to $token_file"
    fi
}

check_token() {
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
        if [[ "$server_check" == "${jss_url}" && "$user_check" == "$jss_api_user" ]]; then
            if [[ $cred_type == "client-id" ]]; then
                if plutil -extract access_token raw "$token_file" >/dev/null; then
                    token=$(plutil -extract access_token raw "$token_file")
                else
                    token=""
                fi
                if plutil -extract expires_in raw "$token_file" >/dev/null; then
                    expires=$(plutil -extract expires_in raw "$token_file")
                    current_time_epoch=$(/bin/date +%s)
                    expiration_epoch=$(($current_epoch + $token_expires_in - 1))
                else
                    expiration_epoch="0"
                fi
                if [[ $expiration_epoch -gt $current_time_epoch ]]; then
                    echo "Token valid until the following epoch time: $expiration_epoch"
                else
                    if [[ $verbose -gt 0 ]]; then
                        echo "token expired or invalid ($expiration_epoch v $cutoff_epoch). Grabbing a new one"
                    fi
                    sleep 1
                    get_new_token "${jss_url}"
                fi
            else
                if plutil -extract token raw "$token_file" >/dev/null; then
                    token=$(plutil -extract token raw "$token_file")
                else
                    token=""
                fi
                if plutil -extract expires raw "$token_file" >/dev/null; then
                    expires=$(plutil -extract expires raw "$token_file" | awk -F . '{print $1}')
                    expiration_epoch=$(date -j -f "%Y-%m-%dT%T" "$expires" +"%s")
                else
                    expiration_epoch="0"
                fi
                # set a cutoff of one minute in the future to prevent problems with mismatched expiration
                # cutoff=$(date -v +1M -u +"%Y-%m-%dT%H:%M:%S")
                cutoff_epoch=$(date -j -f "%Y-%m-%dT%T" "$(date -u +"%Y-%m-%dT%T")" +"%s")

                if [[ $expiration_epoch -lt $cutoff_epoch ]]; then
                    if [[ $verbose -gt 0 ]]; then
                        echo "token expired or invalid ($expiration_epoch v $cutoff_epoch). Grabbing a new one"
                    fi
                    sleep 1
                    get_new_token "${jss_url}"
                else
                    if [[ $verbose -gt 0 ]]; then
                        echo "Existing token still valid"
                    fi
                fi
            fi
        elif [[ "$server_check" == "${jss_url}" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "'$user_check' does not match '$jss_api_user'. Grabbing a new token"
            fi
            sleep 1
            get_new_token "$1"
        elif [[ "$user_check" == "$jss_api_user" ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "'$server_check' does not match '${jss_url}'. Grabbing a new token"
            fi
            sleep 1
            get_new_token "$1"
        else
            if [[ $verbose -gt 0 ]]; then
                echo "'$user_check' does not match '$jss_api_user', and '$server_check' does not match '${jss_url}'. Grabbing a new token."
            fi
            sleep 1
            get_new_token "$1"
        fi
    else
        if [[ $verbose -gt 0 ]]; then
            echo "No token found. Grabbing a new one"
        fi
        get_new_token "$1"
    fi
    export token
}

handle_jpapi_get_request() {
    # handle Jamf Pro API GET requests that may require looping through multiple pages

    # local variables to pass in
    local endpoint="$1"
    local sort_filter="$2"

    if [[ -z $endpoint ]]; then
        echo "   [handle_jpapi_get_request] No endpoint provided for handle_jpapi_get_request"
        return 1
    fi

    if [[ -z $sort_filter ]]; then
        echo "   [handle_jpapi_get_request] No sort_filter provided for handle_jpapi_get_request, using id as default"
        sort_filter="id"
    fi

    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    url_filter="?page=0&page-size=1"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how many items are in the list?
    total_count=$(/usr/bin/plutil -extract totalCount raw "$curl_output_file")
    if [[ $total_count -eq 0 ]]; then
        echo "   [handle_jpapi_get_request] No items found"
        combined_output=""
        return
    fi

    echo "   [handle_jpapi_get_request] Total items found: $total_count"

    # we need to run multiple loops to get all the devices if there are more than 1000
    # calculate how many loops we need
    loop_count=$(( total_count / 100 ))
    if (( total_count % 100 > 0 )); then
        loop_count=$(( loop_count + 1 ))
    fi
    echo "   [handle_jpapi_get_request] Will loop through $loop_count times to get all items."

    # now loop through
    i=0
    combined_output=""
    while [[ $i -lt $loop_count ]]; do
        echo "   [handle_jpapi_get_request] Processing page $i of $loop_count..."
        # set the page number

        url_filter="?page=$i&page-size=100&sort=$sort_filter%3Aasc"
        curl_url="$jss_url/$endpoint/$url_filter"
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
}

send_curl_request() {
    # use separate config files for each instance
    instance_id=$(echo "$jss_url" | sed 's|https://||' | sed 's|:|_|g' | sed 's|/|_|g' | sed 's|\.|_|g')
    token_file="$output_location/jamf_api_token_$instance_id.txt"
    server_check_file="$output_location/jamf_server_check_$instance_id.txt"
    user_check_file="$output_location/jamf_user_check_$instance_id.txt"
    cookie_jar="$output_location/jamf_cookie_jar_$instance_id.txt"

    max_tries=20
    if [[ -n $max_tries_override ]]; then
        max_tries=$max_tries_override
    fi
    
    if [[ $verbose -gt 0 ]]; then
        echo "Supplied URL: $curl_url"
    fi

    try=1
    echo "" > "$curl_output_file"

    while [[ $try -le $max_tries ]]; do
        check_token "$jss_url"
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
            echo "Complete curl command sent:"
            echo "curl ${final_args[*]}"
        fi

        http_response="$curl_request"

        # These lines can be commented out if we need to see what the request was and what the response is 
        # echo "    REQUEST:" # TEMP
        # echo "curl ${final_args[*]}" # TEMP
        # echo "    RESPONSE:" # TEMP
        # cat "$curl_output_file" # TEMP

        if [[ "$http_response" == "10"* || "$http_response" == "20"* || "$http_response" == "30"* ]]; then
            if [[ $verbose -gt 0 ]]; then
                echo "Success response ($http_response)"
                echo "Output file: $curl_output_file"
            fi
            break
        elif [[ "$http_response" == "400" ]]; then
            echo "Fail response ($http_response) - aborting"
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
            echo "Fail response ($http_response) - attempt #$try."
            get_new_token
        fi
        sleep $try
        (( try++ ))
    done
    if [[ $try -gt $max_tries ]]; then
        echo "ERROR: fail response ($http_response) - maximum attempts reached - cannot continue."
        # TODO - create a report of failed items
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
        echo "No template files found. To choose from a list, add a text file into the $templates_folder folder"
        exit 1
    fi
}

choose_template_file() {
    # get template files
    echo
    echo "Available templates:"
    echo
    get_template_files
    echo

    # set template
    if [[ $template ]]; then
        echo "Template $template chosen"
        if [[ $template != "/"* ]]; then
            template_file="$templates_folder/$template"
        fi
        if [[ ! -f "$template_file" ]]; then
            echo "Chosen template $template not found"
            exit 1
        fi
    else
        echo "Choose the template from the list above"
        read -r -p "Template : " template
        echo
        if [[ $template && -f "$templates_folder/${template_files[$template]}" ]]; then
            template_file="$templates_folder/${template_files[$template]}"
        else
            echo "Template not found"
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
    # instance_args+=("--user")
    # instance_args+=("$jss_api_user")
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
    # echo "$jamf_upload_path" "${args[@]}" "${instance_args[@]}" # TEMP
    "$jamf_upload_path" "${args[@]}" "${instance_args[@]}" 

    # Send Slack notification
    slack_text="{'username': '$jss_instance', 'text': '*jamfuploader_run.sh*\nUser: $jss_api_user\nInstance: $jss_instance\nArguments: ${args[*]}'}"
    send_slack_notification "$slack_text"
}

encode_name() {
    url_encoded_name="$( echo "$1" | sed -e 's| |%20|g' | sed -e 's|&amp;|%26|g' )"
    echo "$url_encoded_name"
}

get_object_id_from_name() {
    set_credentials "$jss_instance"
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
    set_credentials "$jss_instance"
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
        computers_count=$(/usr/bin/plutil -extract computer_group.computers raw "$curl_output_file" 2>/dev/null)
        if [[ $computers_count -gt 0 ]]; then
            echo "   [get_computers_in_group] Restricting list to members of the group '$group_name'"
            computer_names_in_group=()
            computer_ids_in_group=()
            i=0
            while [[ $i -lt $computers_count ]]; do
                computer_id_in_group=$(/usr/bin/plutil -extract computer_group.computers.$i.id raw "$curl_output_file" 2>/dev/null)
                computer_name_in_group=$(/usr/bin/plutil -extract computer_group.computers.$i.name raw "$curl_output_file" 2>/dev/null)
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
    set_credentials "$jss_instance"
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
        mobile_device_count=$(/usr/bin/plutil -extract mobile_device_group.mobile_devices raw "$curl_output_file" 2>/dev/null)
        if [[ $mobile_device_count -gt 0 ]]; then
            echo "   [get_mobile_devices_in_group] Restricting list to members of the group '$group_name'"
            mobile_device_names_in_group=()
            mobile_device_ids_in_group=()
            i=0
            while [[ $i -lt $mobile_device_count ]]; do
                mobile_device_id_in_group=$(/usr/bin/plutil -extract mobile_device_group.mobile_devices.$i.id raw "$curl_output_file" 2>/dev/null)
                mobile_device_name_in_group=$(/usr/bin/plutil -extract mobile_device_group.mobile_devices.$i.name raw "$curl_output_file" 2>/dev/null)
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
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/preview/computers"
    url_filter="?page=0&page-size=10"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how many devices are there?
    total_count=$(/usr/bin/plutil -extract totalCount raw "$curl_output_file")
    if [[ $total_count -eq 0 ]]; then
        echo "No computers found"
        exit 1
    fi
    echo "Total computers found: $total_count"

    # we need to run multiple loops to get all the devices if there are more than 1000
    # calculate how many loops we need
    loop_count=$(( total_count / 1000 ))
    if (( total_count % 1000 > 0 )); then
        loop_count=$(( loop_count + 1 ))
    fi
    echo "Will loop through $loop_count times to get all computers."

    # now loop through
    i=0
    while [[ $i -lt $loop_count ]]; do
        # set the page number
        page_number=$(( i * 1000 ))
        url_filter="?page=$page_number&page-size=1000&sort=id"
        curl_url="$jss_url/$endpoint/$url_filter"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
        # append the results to the output file, ensuring only to append the results
        # if this is the first loop, we need to create the file
        combined_output_file="$output_location/jamf_computer_list_combined.json"
        if [[ ! -f "$combined_output_file" ]]; then
            touch "$combined_output_file"
        fi
        # extract the results and append them to the combined output file
        if [[ $i -eq 0 ]]; then
            /usr/bin/plutil -extract results raw "$curl_output_file" > "$combined_output_file"
        else
            /usr/bin/plutil -extract results raw "$curl_output_file" >> "$combined_output_file"
        fi
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
    while [[ $i -lt $loopsize ]]; do
        id_in_list=$(/usr/bin/plutil -extract results.$i.id raw "$combined_output_file")
        computer_name_in_list=$(/usr/bin/plutil -extract results.$i.name raw "$combined_output_file")
        management_id_in_list=$(/usr/bin/plutil -extract results.$i.managementId raw "$combined_output_file")
        serial_in_list=$(/usr/bin/plutil -extract results.$i.serialNumber raw "$combined_output_file")

        computer_ids+=("$id_in_list")
        computer_names+=("$computer_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            computer_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<< "$serial" | wc -l)
                serial_count=$(( count + 1 ))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$( cut -d, -f$j <<< "$serial" )
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
        read -r -p "Enter the ID(s) of the computer(s) above : " computer_input
        # computers chosen
        for computer in $computer_input; do
            computer_choice+=("$computer")
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
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    endpoint="api/v2/mobile-devices"
    url_filter="?page=0&page-size=10"
    curl_url="$jss_url/$endpoint/$url_filter"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/json")
    send_curl_request

    # how many devices are there?
    total_count=$(/usr/bin/plutil -extract totalCount raw "$curl_output_file")
    if [[ $total_count -eq 0 ]]; then
        echo "No mobile devices found"
        exit 1
    fi
    echo "Total mobile devices found: $total_count"

    # we need to run multiple loops to get all the devices if there are more than 1000
    # calculate how many loops we need
    loop_count=$(( total_count / 1000 ))
    if (( total_count % 1000 > 0 )); then
        loop_count=$(( loop_count + 1 ))
    fi
    echo "Will loop through $loop_count times to get all devices."

    # now loop through
    i=0
    while [[ $i -lt $loop_count ]]; do
        # set the page number
        page_number=$(( i * 1000 ))
        url_filter="?page=$page_number&page-size=1000&sort=id"
        curl_url="$jss_url/$endpoint/$url_filter"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/json")
        send_curl_request
        # append the results to the output file, ensuring only to append the results
        # if this is the first loop, we need to create the file
        combined_output_file="$output_location/jamf_mobile_device_list_combined.json"
        if [[ ! -f "$combined_output_file" ]]; then
            touch "$combined_output_file"
        fi
        # extract the results and append them to the combined output file
        if [[ $i -eq 0 ]]; then
            /usr/bin/plutil -extract results raw "$curl_output_file" > "$combined_output_file"
        else
            /usr/bin/plutil -extract results raw "$curl_output_file" >> "$combined_output_file"
        fi
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
        id_in_list=$(/usr/bin/plutil -extract results.$i.id raw "$combined_output_file")
        mobile_device_name_in_list=$(/usr/bin/plutil -extract results.$i.name raw "$combined_output_file")
        management_id_in_list=$(/usr/bin/plutil -extract results.$i.managementId raw "$combined_output_file")
        serial_in_list=$(/usr/bin/plutil -extract results.$i.serialNumber raw "$combined_output_file")

        mobile_device_ids+=("$id_in_list")
        mobile_device_names+=("$mobile_device_name_in_list")
        management_ids+=("$management_id_in_list")
        serials+=("$serial_in_list")
        if [[ $id && $id_in_list -eq $id ]]; then
            mobile_device_choice+=("$i")
        elif [[ $serial ]]; then
            # allow for CSV list of serials
            if [[ $serial =~ "," ]]; then
                count=$(grep -o "," <<< "$serial" | wc -l)
                serial_count=$(( count + 1 ))
                j=1
                while [[ $j -le $serial_count ]]; do
                    serial_in_csv=$( cut -d, -f$j <<< "$serial" )
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
        read -r -p "Enter the ID(s) of the mobile_device(s) above : " mobile_device_input
        # mobile_devices chosen
        for mobile_device in $mobile_device_input; do
            mobile_device_choice+=("$mobile_device")
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
        advanced_computer_search)        api_object_type="advancedcomputersearches";;
        advanced_mobile_device_search)   api_object_type="advancedmobiledevicesearches";;
        category)                        api_object_type="categories";;
        configuration_profile)           api_object_type="mobiledeviceconfigurationprofiles";;
        group|user)                      api_object_type="accounts";;
        policy)                          api_object_type="policies";;
        restricted_software_title)       api_object_type="restrictedsoftware";;
        *)                               api_object_type=$( echo "${api_xml_object}s" | sed 's|_||g' );;

    esac
    echo "$api_object_type"
}

get_plural_from_api_xml_object() {
    local api_xml_object=$1

    case "$api_xml_object" in
        advanced_computer_search)        api_xml_object_plural="advanced_computer_searches";;
        advanced_mobile_device_search)   api_xml_object_plural="advanced_mobile_device_searches";;
        category)                        api_xml_object_plural="categories";;
        policy)                          api_xml_object_plural="policies";;
        restricted_software_title)       api_xml_object_plural="restricted_software";;
        *)                               api_xml_object_plural="${api_xml_object}s"
    esac
    echo "$api_xml_object_plural"
}

get_api_object_from_type() {
    local api_object_type=$1

    # shellcheck disable=SC2001
    case "$api_object_type" in
        advancedcomputersearches)           api_xml_object="advanced_computer_search";;
        advancedmobiledevicesearches)       api_xml_object="advanced_mobile_device_search";;
        categories)                         api_xml_object="category";;
        computerextensionattributes)        api_xml_object="computer_extension_attribute";;
        computergroups)                     api_xml_object="computer_group";;
        distributionpoints)                 api_xml_object="distribution_point";;
        dockitems)                          api_xml_object="dock_item";;
        ldapservers)                        api_xml_object="ldap_server";;
        macapplications)                    api_xml_object="mac_application";;
        mobiledeviceapplications)           api_xml_object="mobile_device_application";;
        mobiledeviceconfigurationprofiles)  api_xml_object="configuration_profile";;
        mobiledeviceextensionattributes)    api_xml_object="mobile_device_extension_attribute";;
        mobiledevicegroups)                 api_xml_object="mobile_device_group";;
        osxconfigurationprofiles)           api_xml_object="os_x_configuration_profile";;
        policies)                           api_xml_object="policy";;
        restrictedsoftware)                 api_xml_object="restricted_software_title";;
        smtpserver)                         api_xml_object="smtp_server";;
        *)                                  api_xml_object=$(sed 's|s$||' <<< "$api_object_type") ;; 
    esac
    echo "$api_xml_object"
}



# ljt section
: <<-LICENSE_BLOCK
ljt.min - Little JSON Tool (https://github.com/brunerd/ljt) Copyright (c) 2022 Joel Bruner (https://github.com/brunerd). Licensed under the MIT License. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
LICENSE_BLOCK

#v1.0.3 - use the minified function below to embed ljt into your shell script
ljt() ( 
	[ -n "${-//[^x]/}" ] && set +x; read -r -d '' JSCode <<-'EOT'
	try {var query=decodeURIComponent(escape(arguments[0]));var file=decodeURIComponent(escape(arguments[1]));if (query[0]==='/'){ query = query.split('/').slice(1).map(function (f){return "["+JSON.stringify(f)+"]"}).join('')}if(/[^A-Za-z_$\d\.\[\]'"]/.test(query.split('').reverse().join('').replace(/(["'])(.*?)\1(?!\\)/g, ""))){throw new Error("Invalid path: "+ query)};if(query[0]==="$"){query=query.slice(1,query.length)};var data=JSON.parse(readFile(file));var result=eval("(data)"+query)}catch(e){printErr(e);quit()};if(result !==undefined){result!==null&&result.constructor===String?print(result): print(JSON.stringify(result,null,2))}else{printErr("Node not found.")}
	EOT
	queryArg="${1}"; fileArg="${2}";jsc=$(find "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/" -name 'jsc');[ -z "${jsc}" ] && jsc=$(which jsc);{ [ -f "${queryArg}" ] && [ -z "${fileArg}" ]; } && fileArg="${queryArg}" && unset queryArg;if [ -f "${fileArg:=/dev/stdin}" ]; then { errOut=$( { { "${jsc}" -e "${JSCode}" -- "${queryArg}" "${fileArg}"; } 1>&3 ; } 2>&1); } 3>&1;else { errOut=$( { { "${jsc}" -e "${JSCode}" -- "${queryArg}" "/dev/stdin" <<< "$(cat)"; } 1>&3 ; } 2>&1); } 3>&1; fi;if [ -n "${errOut}" ]; then /bin/echo "$errOut" >&2; return 1; fi
)


