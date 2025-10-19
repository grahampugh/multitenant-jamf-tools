#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <full-base-url-or-host>"
  exit 2
fi

input="$1"

find_all_internet_passwords() {
    local server="$1"
    local count=0
    local in_inet_entry=false
    local matching_entries=()
    
    echo "Searching for all internet passwords with server: $server"
    
    # Get raw keychain data and process it
    while IFS= read -r line; do
        if [[ "$line" =~ keychain: ]]; then
            current_keychain="$line"
        elif [[ "$line" =~ class:.*inet ]]; then
            in_inet_entry=true
            current_entry=""
        elif [[ "$in_inet_entry" == true ]]; then
            current_entry+="$line"$'\n'
            
            if [[ "$line" =~ srvr.*"$server" ]]; then
                ((count++))
                # echo "Entry #$count found in $current_keychain"
                matching_entries+=("$(echo "$current_entry" | grep -E 'acct.*<blob>=' | sed 's/.*<blob>="\([^"]*\)".*/\1/')")
            fi
            
            if [[ -z "$line" ]]; then
                in_inet_entry=false
                current_entry=""
            fi
        fi
    done < <(/usr/bin/security dump-keychain)
    
    echo "Total entries found: $count"
    if [ $count -gt 0 ]; then
        echo "Accounts associated with server $server:"
        for account in "${matching_entries[@]}"; do
            echo " - $account"
        done
    fi

    # ask user which account to use
    if [ $count -gt 1 ]; then
        echo
        echo "Multiple entries found for server $server."
        echo "Please choose an account to use:"
        select chosen_account in "${matching_entries[@]}"; do
            if [[ -n "$chosen_account" ]]; then
                echo "You selected: $chosen_account"
                break
            else
                echo "Invalid selection. Please try again."
            fi
        done
    fi
}

find_all_internet_passwords "$input"
