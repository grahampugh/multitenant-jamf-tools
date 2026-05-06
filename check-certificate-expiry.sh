#!/bin/bash

# --------------------------------------------------------------------------------
# Script for identifying certificates in configuration profiles and extracting
# their names and expiry dates across multiple Jamf Pro instances.
#
# This script:
# 1. Downloads the list of computer and mobile device configuration profiles
# 2. Filters profiles containing "Certificate" in the name
# 3. Downloads each matching profile
# 4. Removes the signature from the .mobileconfig file
# 5. Extracts the certificate data and decodes it to get name and expiry date
# 6. Outputs JSON, CSV, and a markdown report (for certs expiring within 90 days)
# --------------------------------------------------------------------------------

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

# define autopkg_prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

# define autopkg binary
autopkg_binary="/usr/local/bin/autopkg"

# output directory
output_dir_default="/Users/Shared/Jamf/CertificateExpiry"

# expiry threshold in days
expiry_threshold=90

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

# check if autopkg is installed
if [[ ! -x "$autopkg_binary" ]]; then
    echo "ERROR: AutoPkg not found at $autopkg_binary. Aborting."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
./set_credentials.sh               - set the Keychain credentials

[no arguments]                     - interactive mode
-il FILENAME (without .txt)        - provide an instance list filename
                                     (must exist in the instance-lists folder)
-i JSS_URL                         - perform action on a single instance
                                     (must exist in the relevant instance list)
-ai | --all-instances              - perform action on ALL instances in the instance list
--user | --client-id CLIENT_ID     - use the specified client ID or username
-o | --output DIR                  - output directory
                                     (default: /Users/Shared/Jamf/CertificateExpiry)
--threshold DAYS                   - expiry threshold in days for the report (default: 90)
-v[vvv]                            - add verbose output

USAGE
}

download_object_list() {
    local object_type="$1"
    echo "   [download_object_list] Downloading list of $object_type..."
    if ! "$autopkg_binary" run "$verbosity_mode" \
        "$this_script_dir/recipes/DownloadObjectList.jamf.recipe.yaml" \
        --key "OBJECT_TYPE=$object_type" \
        --key "JSS_URL=$jss_instance" \
        --key "OUTPUT_DIR=$instance_output_dir" \
        --key "CLIENT_ID=" \
        --key "CLIENT_SECRET="; then
        echo "   [download_object_list] ERROR: AutoPkg run failed for $object_type"
        return 1
    fi
}

download_object() {
    local object_type="$1"
    local object_name="$2"
    echo "   [download_object] Downloading profile: $object_name..."
    if ! "$autopkg_binary" run "$verbosity_mode" \
        "$this_script_dir/recipes/DownloadObject.jamf.recipe.yaml" \
        --key "OBJECT_TYPE=$object_type" \
        --key "OBJECT_NAME=$object_name" \
        --key "JSS_URL=$jss_instance" \
        --key "OUTPUT_DIR=$instance_output_dir" \
        --key "CLIENT_ID=" \
        --key "CLIENT_SECRET="; then
        echo "   [download_object] ERROR: AutoPkg run failed for $object_name"
        return 1
    fi
}

unsign_profile() {
    local input_file="$1"
    local output_file="$2"
    # Try to remove the signature; if it fails, the profile may not be signed
    if ! security cms -D -i "$input_file" -o "$output_file" 2>/dev/null; then
        # If unsigning fails, try using the file directly (it may not be signed)
        cp "$input_file" "$output_file"
    fi
}

extract_certificates_from_profile() {
    local profile_file="$1"
    local profile_name="$2"
    local object_type="$3"

    # The profile file is a plist (mobileconfig). Use PlistBuddy to read it directly.
    # PayloadContent is an array of payload dicts; certs have PayloadType "com.apple.security.*"

    local payload_count
    payload_count=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent" "$profile_file" 2>/dev/null | grep -c "Dict {")

    if [[ "$payload_count" -eq 0 ]]; then
        echo "   [extract_certificates] No PayloadContent found in $profile_name"
        return 1
    fi

    local idx=0
    while [[ $idx -lt $payload_count ]]; do
        local payload_type
        payload_type=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:${idx}:PayloadType" "$profile_file" 2>/dev/null)

        if [[ "$payload_type" == *"com.apple.security"* ]]; then
            # PlistBuddy outputs data keys as raw binary bytes
            local cert_data_file
            cert_data_file=$(mktemp "${TMPDIR:-/tmp}/cert_data_XXXXXX.der")

            /usr/libexec/PlistBuddy -c "Print :PayloadContent:${idx}:PayloadContent" "$profile_file" > "$cert_data_file" 2>/dev/null

            if [[ -s "$cert_data_file" ]]; then
                # Try to parse as DER certificate
                local cert_info
                cert_info=$(openssl x509 -inform DER -in "$cert_data_file" -noout -subject -enddate 2>/dev/null)

                if [[ -z "$cert_info" ]]; then
                    # Try PEM format
                    cert_info=$(openssl x509 -inform PEM -in "$cert_data_file" -noout -subject -enddate 2>/dev/null)
                fi

                if [[ -n "$cert_info" ]]; then
                    local cert_subject cert_enddate
                    cert_subject=$(echo "$cert_info" | grep "subject=" | sed 's/subject=//' | sed 's/.*CN *= *//' | sed 's/,.*//')
                    cert_enddate=$(echo "$cert_info" | grep "notAfter=" | sed 's/notAfter=//')

                    if [[ -n "$cert_enddate" ]]; then
                        # Get the PayloadDisplayName as the cert name if available
                        local payload_display_name
                        payload_display_name=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:${idx}:PayloadDisplayName" "$profile_file" 2>/dev/null)
                        if [[ -z "$payload_display_name" ]]; then
                            payload_display_name="$cert_subject"
                        fi

                        # Convert expiry date to epoch for comparison
                        local expiry_epoch
                        expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$cert_enddate" "+%s" 2>/dev/null)
                        if [[ -z "$expiry_epoch" ]]; then
                            expiry_epoch=$(date -j -f "%b  %d %T %Y %Z" "$cert_enddate" "+%s" 2>/dev/null)
                        fi

                        local expiry_date_formatted
                        expiry_date_formatted=$(date -j -f "%b %d %T %Y %Z" "$cert_enddate" "+%Y-%m-%d" 2>/dev/null)
                        if [[ -z "$expiry_date_formatted" ]]; then
                            expiry_date_formatted=$(date -j -f "%b  %d %T %Y %Z" "$cert_enddate" "+%Y-%m-%d" 2>/dev/null)
                        fi
                        if [[ -z "$expiry_date_formatted" ]]; then
                            expiry_date_formatted="$cert_enddate"
                        fi

                        # Calculate days until expiry
                        local now_epoch days_until_expiry
                        now_epoch=$(date "+%s")
                        if [[ -n "$expiry_epoch" ]]; then
                            days_until_expiry=$(( (expiry_epoch - now_epoch) / 86400 ))
                        else
                            days_until_expiry="unknown"
                        fi

                        # Determine profile type label
                        local profile_type_label
                        if [[ "$object_type" == "os_x_configuration_profile" ]]; then
                            profile_type_label="Computer"
                        else
                            profile_type_label="Mobile Device"
                        fi

                        # Add to results
                        local cert_entry
                        cert_entry=$(jq -n \
                            --arg instance "$jss_instance" \
                            --arg profile_name "$profile_name" \
                            --arg profile_type "$profile_type_label" \
                            --arg cert_name "$payload_display_name" \
                            --arg cert_subject "$cert_subject" \
                            --arg expiry_date "$expiry_date_formatted" \
                            --arg days_until_expiry "$days_until_expiry" \
                            '{instance: $instance, profile_name: $profile_name, profile_type: $profile_type, cert_name: $cert_name, cert_subject: $cert_subject, expiry_date: $expiry_date, days_until_expiry: ($days_until_expiry | tonumber? // $days_until_expiry)}')

                        # Append to the combined JSON
                        jq --argjson entry "$cert_entry" '. += [$entry]' "$combined_json_file" > "${combined_json_file}.tmp" \
                            && mv "${combined_json_file}.tmp" "$combined_json_file"

                        echo "   [extract_certificates] Found: $payload_display_name (expires: $expiry_date_formatted, $days_until_expiry days)"
                    fi
                else
                    echo "   [extract_certificates] Could not parse certificate data in payload $idx of $profile_name"
                fi
            fi
            rm -f "$cert_data_file"
        fi
        ((idx++))
    done
}

process_profiles() {
    local object_type="$1"

    # Find the object list JSON file
    local subdomain
    subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    local list_file="$instance_output_dir/${subdomain}-${object_type}s.json"

    if [[ ! -f "$list_file" ]]; then
        echo "   [process_profiles] No object list file found at $list_file"
        return 1
    fi

    # Filter to only profiles containing "Certificate" in the name
    local cert_profiles
    cert_profiles=$(jq -r '.[] | select(.name | test("Certificate"; "i")) | .name' "$list_file" 2>/dev/null)

    if [[ -z "$cert_profiles" ]]; then
        echo "   [process_profiles] No certificate profiles found for $object_type"
        return 0
    fi

    echo "   [process_profiles] Found certificate profiles:"
    echo "$cert_profiles" | while IFS= read -r name; do
        echo "      - $name"
    done

    # Download and process each certificate profile
    while IFS= read -r profile_name; do
        if [[ -z "$profile_name" ]]; then
            continue
        fi

        download_object "$object_type" "$profile_name"

        # Find the downloaded mobileconfig file
        local safe_name
        safe_name=$(echo "$profile_name" | sed 's/[^a-zA-Z0-9._-]/_/g')
        local mobileconfig_file
        mobileconfig_file=$(find "$instance_output_dir" -name "*.mobileconfig" -newer "$list_file" -print -quit 2>/dev/null)

        local profile_to_parse=""
        if [[ -n "$mobileconfig_file" && -f "$mobileconfig_file" ]]; then
            # Unsign the profile
            local unsigned_file="${mobileconfig_file%.mobileconfig}_unsigned.mobileconfig"
            unsign_profile "$mobileconfig_file" "$unsigned_file"
            profile_to_parse="$unsigned_file"
        fi

        if [[ -n "$profile_to_parse" && -f "$profile_to_parse" ]]; then
            extract_certificates_from_profile "$profile_to_parse" "$profile_name" "$object_type"
        else
            echo "   [process_profiles] WARNING: Could not find downloaded file for $profile_name"
        fi

    done <<< "$cert_profiles"
}

generate_csv() {
    local json_file="$1"
    local csv_file="$2"

    echo "Instance,Profile Name,Profile Type,Certificate Name,Certificate Subject,Expiry Date,Days Until Expiry" > "$csv_file"
    jq -r '.[] | [.instance, .profile_name, .profile_type, .cert_name, .cert_subject, .expiry_date, (.days_until_expiry | tostring)] | @csv' "$json_file" >> "$csv_file"
}

generate_markdown_report() {
    local json_file="$1"
    local md_file="$2"
    local threshold="$3"

    # Filter to only certs expiring within threshold
    local expiring
    expiring=$(jq --argjson threshold "$threshold" '[.[] | select(.days_until_expiry != "unknown" and (.days_until_expiry | tonumber) < $threshold)]' "$json_file")

    local count
    count=$(echo "$expiring" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "No certificates expiring within $threshold days." > "$md_file"
        return 0
    fi

    {
        echo "# Certificate Expiry Report"
        echo ""
        echo "Certificates expiring within $threshold days (generated: $(date '+%Y-%m-%d %H:%M:%S'))"
        echo ""
    } > "$md_file"

    # Group by instance
    local instances
    instances=$(echo "$expiring" | jq -r '.[].instance' | sort -u)

    while IFS= read -r instance_url; do
        local instance_display="${instance_url#https://}"
        echo "## $instance_display" >> "$md_file"
        echo "" >> "$md_file"

        # Get certs for this instance, sorted by days_until_expiry
        local instance_certs
        instance_certs=$(echo "$expiring" | jq --arg inst "$instance_url" '[.[] | select(.instance == $inst)] | sort_by(.days_until_expiry)')

        local cert_count
        cert_count=$(echo "$instance_certs" | jq 'length')

        for ((c=0; c<cert_count; c++)); do
            local cert_name profile_name profile_type expiry_date days
            cert_name=$(echo "$instance_certs" | jq -r ".[$c].cert_name")
            profile_name=$(echo "$instance_certs" | jq -r ".[$c].profile_name")
            profile_type=$(echo "$instance_certs" | jq -r ".[$c].profile_type")
            expiry_date=$(echo "$instance_certs" | jq -r ".[$c].expiry_date")
            days=$(echo "$instance_certs" | jq -r ".[$c].days_until_expiry")

            echo "- **$cert_name** — expires $expiry_date ($days days)" >> "$md_file"
            echo "    - Profile: $profile_name ($profile_type)" >> "$md_file"
        done
        echo "" >> "$md_file"
    done <<< "$instances"
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
    -il | --instance-list)
        shift
        chosen_instance_list_file="$1"
        ;;
    -i | --instance)
        shift
        chosen_instances+=("$1")
        ;;
    -a | -ai | --all | --all-instances)
        all_instances=1
        ;;
    --id | --client-id | --user | --username)
        shift
        chosen_id="$1"
        ;;
    -x | --nointeraction)
        no_interaction=1
        ;;
    -o | --output)
        shift
        output_dir="$1"
        ;;
    --threshold)
        shift
        expiry_threshold="$1"
        ;;
    -v*)
        verbosity_mode="$1"
        ;;
    -h | --help)
        usage
        exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if [[ ! $verbosity_mode ]]; then
    verbosity_mode="-v"
fi

echo
echo "This script will check certificate expiry dates in configuration profiles"
echo "across the chosen Jamf Pro instance(s)."
echo

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances
choose_destination_instances

# set output directory
if [[ ! "$output_dir" ]]; then
    output_dir="$output_dir_default"
fi
mkdir -p "$output_dir"

# set output file paths
timestamp=$(date '+%Y-%m-%d_%H%M%S')
combined_json_file="$output_dir/certificate_expiry_${timestamp}.json"
csv_file="$output_dir/certificate_expiry_${timestamp}.csv"
report_file="$output_dir/certificate_expiry_${timestamp}.md"

# initialize the combined JSON array
echo "[]" > "$combined_json_file"

echo
echo "Checking certificate profiles..."
echo

for jss_instance in "${instance_choice_array[@]}"; do
    echo "   [main] Processing $jss_instance..."

    # set credentials
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [main] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [main] Using stored credentials for $jss_instance ($jss_api_user)"
    fi

    # Create instance-specific output directory
    local_subdomain=$(echo "$jss_instance" | awk -F[/:] '{print $4}' | cut -d'.' -f1)
    instance_output_dir="$output_dir/$local_subdomain"
    mkdir -p "$instance_output_dir"

    # Process computer configuration profiles
    echo "   [main] Checking computer configuration profiles..."
    download_object_list "os_x_configuration_profile"
    process_profiles "os_x_configuration_profile"

    # Process mobile device configuration profiles
    echo "   [main] Checking mobile device configuration profiles..."
    download_object_list "configuration_profile"
    process_profiles "configuration_profile"

    echo "   [main] Done with $jss_instance"
    echo
done

# Generate CSV
generate_csv "$combined_json_file" "$csv_file"

# Generate markdown report (only certs expiring within threshold)
generate_markdown_report "$combined_json_file" "$report_file" "$expiry_threshold"

echo
echo "Results:"
echo
if [[ -f "$report_file" ]]; then
    cat "$report_file"
fi
echo
echo "Files saved to:"
echo "   JSON: $combined_json_file"
echo "   CSV:  $csv_file"
echo "   Report (expiring within ${expiry_threshold} days): $report_file"
echo
echo "Finished"
echo
