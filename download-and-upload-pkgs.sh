#!/bin/bash

# --------------------------------------------------------------------------------
# Script for downloading files from an HTTPS file share (with basic HTTP auth)
# and uploading them to a Jamf Pro instance as packages.
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
    cat <<'USAGE'
download-and-upload-pkgs.sh

A script for downloading files from an HTTPS file share (with HTTP Basic Auth)
and uploading them to a Jamf Pro instance as packages using jamfuploader-run.sh.

Usage:
./download-and-upload-pkgs.sh [OPTIONS]

Options:
--url | -u URL                     - URL of the file share (or set SHARE_URL in AutoPkg prefs)
--share-user USER                  - Username for HTTP Basic Auth (or set SHARE_USER in AutoPkg prefs)
--share-pass PASS                  - Password for HTTP Basic Auth (or set SHARE_PASS in AutoPkg prefs)
--download-dir | -o DIR            - Directory to download files to 
                                     (default: /tmp/pkg-downloads)
--file-extension | -e EXT          - File extension filter (default: all)
                                     'all' = pkg, mpkg, zip, dmg only
                                     Or specify a single extension (e.g., pkg)
--pattern | -p PATTERN             - Filename pattern to match (optional, regex)
--il | --instance-list FILENAME    - Provide an instance list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - Perform action on a specific instance
                                     (must exist in the relevant instance list)
-a | -ai | --all-instances         - Perform action on ALL instances in the instance list
-x | --nointeraction               - Run without checking instance is in an instance list
--user | --client-id CLIENT_ID     - Use the specified client ID or username for Jamf Pro
--category CATEGORY                - Category to assign to uploaded packages
--dp                               - Filter fileshare distribution points on DP name
--prefs <path>                     - Inherit AutoPkg prefs file provided by the full path
-v[vvv]                            - Set value of verbosity (default is -v)
-q                                 - Quiet mode (verbosity 0)
-j <path>                          - Alternative path to jamf-upload.sh script
--skip-download                    - Skip download, only upload existing files in download dir
--skip-upload                      - Skip upload, only download files
--skip-orphans                     - Only download files that exist as packages on the destination server
--migrate                          - Get URL from a distribution point on the source instance
                                     (alternative to --url)
--replace                          - Replace existing package if it exists
--dry-run                          - Show what would be done without actually doing it
-h | --help                        - Show this help message

Examples:
# Download and upload with interactive prompts:
./download-and-upload-pkgs.sh --url https://files.example.com/packages/

# Download and upload with all options specified:
./download-and-upload-pkgs.sh --url https://files.example.com/packages/ \\
    --share-user myuser --share-pass mypass \\
    --download-dir /tmp/pkgs --file-extension pkg \\
    -i https://mycompany.jamfcloud.com --category "Apps"

# Migrate packages from a distribution point to JCDS on the source instance, ignoring any packages in the DP that don't have matching metadata on the server:
./download-and-upload-pkgs.sh --migrate --skip-orphans --skip-dp

USAGE
}

prompt_for_share_credentials() {
    # Prompt for file share credentials if not provided
    # First check if values can be obtained from AutoPkg prefs
    if [[ -z "$share_url" ]]; then
        share_url=$(defaults read com.github.autopkg SHARE_URL 2>/dev/null)
    fi
    if [[ -z "$share_user" ]]; then
        share_user=$(defaults read com.github.autopkg SHARE_USER 2>/dev/null)
    fi
    if [[ -z "$share_pass" ]]; then
        share_pass=$(defaults read com.github.autopkg SHARE_PASS 2>/dev/null)
    fi

    # Prompt for any values not found
    if [[ -z "$share_url" ]]; then
        echo "Enter the HTTPS URL of the file share:"
        read -r -p "   URL: " share_url
        if [[ -z "$share_url" ]]; then
            echo "ERROR: URL is required."
            exit 1
        fi
    fi

    if [[ -z "$share_user" ]]; then
        echo "Enter the username for HTTP Basic Auth (leave blank if none required):"
        read -r -p "   Username: " share_user
    fi

    if [[ -z "$share_pass" && -n "$share_user" ]]; then
        echo "Enter the password for HTTP Basic Auth:"
        read -r -s -p "   Password: " share_pass
        echo
    fi
}

get_distribution_point_url() {
    # Get distribution point details and extract HTTP URL for downloading
    # This is used with the --migrate option

    local jamfuploader_script="$this_script_dir/jamfuploader-run.sh"
    if [[ ! -f "$jamfuploader_script" ]]; then
        echo "ERROR: jamfuploader-run.sh not found at $jamfuploader_script"
        exit 1
    fi

    # Use the first selected instance to get the distribution point list
    local source_instance="${instance_choice_array[0]}"
    echo "Fetching distribution points from $source_instance..."

    # Extract subdomain from URL
    local subdomain
    subdomain=$(echo "$source_instance" | sed -E 's|https?://([^.]+)\..+|\1|')
    local dp_list_file="/tmp/${subdomain}-distribution_points.json"

    # Get the list of distribution points
    local read_args=()
    read_args+=("read")
    read_args+=("--type")
    read_args+=("distribution_point")
    read_args+=("--list")
    read_args+=("--output")
    read_args+=("/tmp")
    read_args+=("--instance")
    read_args+=("$source_instance")
    read_args+=("--nointeraction")

    if [[ -n "$chosen_id" ]]; then
        read_args+=("--user")
        read_args+=("$chosen_id")
    fi

    read_args+=("-q")

    "$jamfuploader_script" "${read_args[@]}" >/dev/null 2>&1

    if [[ ! -f "$dp_list_file" ]]; then
        echo "ERROR: Could not retrieve distribution point list from $source_instance"
        exit 1
    fi

    # Extract distribution point names
    local dp_names=()
    while IFS= read -r dp_name; do
        if [[ -n "$dp_name" ]]; then
            dp_names+=("$dp_name")
        fi
    done < <(jq -r '.[].name' "$dp_list_file" 2>/dev/null)

    if [[ ${#dp_names[@]} -eq 0 ]]; then
        echo "ERROR: No distribution points found on $source_instance"
        exit 1
    fi

    echo "Found ${#dp_names[@]} distribution point(s)"

    # Select distribution point
    local selected_dp=""

    if [[ -n "$dp_url_filter" ]]; then
        # Auto-select based on --dp filter
        for dp in "${dp_names[@]}"; do
            if [[ "$dp" == *"$dp_url_filter"* ]]; then
                selected_dp="$dp"
                echo "Auto-selected distribution point matching '$dp_url_filter': $selected_dp"
                break
            fi
        done
        if [[ -z "$selected_dp" ]]; then
            echo "ERROR: No distribution point matches '$dp_url_filter'"
            echo "Available distribution points:"
            for dp in "${dp_names[@]}"; do
                echo "   - $dp"
            done
            exit 1
        fi
    elif [[ ${#dp_names[@]} -eq 1 ]]; then
        selected_dp="${dp_names[0]}"
        echo "Using distribution point: $selected_dp"
    else
        # Show menu to select
        echo
        echo "Select a distribution point:"
        local i=0
        for dp in "${dp_names[@]}"; do
            echo "   [$i] $dp"
            ((i++))
        done
        echo
        read -r -p "Enter number: " dp_selection
        if [[ "$dp_selection" =~ ^[0-9]+$ ]] && [[ $dp_selection -lt ${#dp_names[@]} ]]; then
            selected_dp="${dp_names[$dp_selection]}"
        else
            echo "ERROR: Invalid selection"
            exit 1
        fi
        echo "Selected: $selected_dp"
    fi

    # Get the details of the selected distribution point
    echo "Fetching details for distribution point: $selected_dp"
    local dp_detail_file="/tmp/${subdomain}-distribution_points-${selected_dp}.xml"

    local detail_args=()
    detail_args+=("read")
    detail_args+=("--type")
    detail_args+=("distribution_point")
    detail_args+=("--name")
    detail_args+=("$selected_dp")
    detail_args+=("--output")
    detail_args+=("/tmp")
    detail_args+=("--instance")
    detail_args+=("$source_instance")
    detail_args+=("--nointeraction")

    if [[ -n "$chosen_id" ]]; then
        detail_args+=("--user")
        detail_args+=("$chosen_id")
    fi

    detail_args+=("-q")

    "$jamfuploader_script" "${detail_args[@]}" >/dev/null 2>&1

    if [[ ! -f "$dp_detail_file" ]]; then
        echo "ERROR: Could not retrieve distribution point details for $selected_dp"
        exit 1
    fi

    # Extract http_url and http_username from the XML
    local dp_http_url
    local dp_http_username
    dp_http_url=$(xmllint --xpath 'string(//http_url)' "$dp_detail_file" 2>/dev/null)
    dp_http_username=$(xmllint --xpath 'string(//http_username)' "$dp_detail_file" 2>/dev/null)

    if [[ -z "$dp_http_url" ]]; then
        echo "ERROR: No HTTP URL found for distribution point $selected_dp"
        echo "HTTP downloads may not be enabled for this distribution point."
        exit 1
    fi

    # add /Packages subfolder to HTTP URL
    dp_http_url="${dp_http_url%/}/Packages"

    echo "   HTTP URL: $dp_http_url"
    echo "   HTTP Username: $dp_http_username"

    # Set the share_url
    share_url="$dp_http_url"

    # Handle username and password
    if [[ -n "$dp_http_username" ]]; then
        if [[ -z "$share_user" ]]; then
            # No user provided, use the one from DP
            share_user="$dp_http_username"
            # Check if we have a password from prefs
            if [[ -z "$share_pass" ]]; then
                share_pass=$(defaults read com.github.autopkg SHARE_PASS 2>/dev/null)
            fi
            if [[ -z "$share_pass" ]]; then
                echo "Enter the password for HTTP user '$share_user':"
                read -r -s -p "   Password: " share_pass
                echo
            fi
        elif [[ "$share_user" == "$dp_http_username" ]]; then
            # User matches, use existing password or prompt
            if [[ -z "$share_pass" ]]; then
                share_pass=$(defaults read com.github.autopkg SHARE_PASS 2>/dev/null)
            fi
            if [[ -z "$share_pass" ]]; then
                echo "Enter the password for HTTP user '$share_user':"
                read -r -s -p "   Password: " share_pass
                echo
            fi
        else
            # User doesn't match, need to prompt for correct password
            echo "WARNING: Provided SHARE_USER ('$share_user') does not match DP HTTP username ('$dp_http_username')"
            echo "Using DP HTTP username: $dp_http_username"
            share_user="$dp_http_username"
            echo "Enter the password for HTTP user '$share_user':"
            read -r -s -p "   Password: " share_pass
            echo
        fi
    fi

    echo
    echo "Distribution point configured:"
    echo "   URL: $share_url"
    echo "   User: $share_user"
    echo
}

get_existing_packages() {
    # Get list of existing packages from the Jamf server for each selected instance
    # This populates the existing_packages array with package names
    existing_packages=()

    local jamfuploader_script="$this_script_dir/jamfuploader-run.sh"
    if [[ ! -f "$jamfuploader_script" ]]; then
        echo "ERROR: jamfuploader-run.sh not found at $jamfuploader_script"
        exit 1
    fi

    for instance in "${instance_choice_array[@]}"; do
        echo "Fetching existing packages from $instance..."

        # Extract subdomain from URL (e.g., https://test.jamfcloud.com -> test)
        local subdomain
        subdomain=$(echo "$instance" | sed -E 's|https?://([^.]+)\..+|\1|')
        local pkg_list_file="/tmp/${subdomain}-packages.json"

        # Run jamfuploader-run.sh to get the package list
        local read_args=()
        read_args+=("read")
        read_args+=("--type")
        read_args+=("package")
        read_args+=("--list")
        read_args+=("--output")
        read_args+=("/tmp")
        read_args+=("--instance")
        read_args+=("$instance")
        read_args+=("--nointeraction")

        if [[ -n "$chosen_id" ]]; then
            read_args+=("--user")
            read_args+=("$chosen_id")
        fi

        read_args+=("-q")

        "$jamfuploader_script" "${read_args[@]}" >/dev/null 2>&1

        if [[ -f "$pkg_list_file" ]]; then
            # Extract package names from the JSON file
            while IFS= read -r pkg_name; do
                if [[ -n "$pkg_name" ]]; then
                    existing_packages+=("$pkg_name")
                fi
            done < <(jq -r '.[].name' "$pkg_list_file" 2>/dev/null)
            echo "   Found ${#existing_packages[@]} packages on $instance"
        else
            echo "   WARNING: Could not retrieve package list from $instance"
        fi
    done

    if [[ ${#existing_packages[@]} -eq 0 ]]; then
        echo "WARNING: No existing packages found on any instance. --skip-orphans will have no effect."
    fi
}

get_file_list() {
    # Get the list of files from the HTTPS share
    echo
    echo "Fetching file list from $share_url..."

    local curl_opts=()
    curl_opts+=("--silent")
    curl_opts+=("--location")
    curl_opts+=("--fail")

    if [[ -n "$share_user" && -n "$share_pass" ]]; then
        curl_opts+=("--user")
        curl_opts+=("${share_user}:${share_pass}")
    fi

    local response
    response=$(curl "${curl_opts[@]}" "$share_url" 2>&1)
    local curl_exit=$?

    if [[ $curl_exit -ne 0 ]]; then
        echo "ERROR: Failed to connect to $share_url (exit code: $curl_exit)"
        echo "Response: $response"
        exit 1
    fi

    # Parse the HTML response to extract file names
    # This handles common directory listing formats (Apache, nginx, etc.)
    # Look for href attributes that point to files
    file_list=()

    # Extract hrefs and filter for files with the desired extension
    while IFS= read -r line; do
        # Skip empty lines and parent directory links
        if [[ -z "$line" || "$line" == ".." || "$line" == "../" || "$line" == "." || "$line" == "./" ]]; then
            continue
        fi

        # Skip directory entries (ending with /)
        if [[ "$line" == */ ]]; then
            continue
        fi

        # Apply extension filter
        if [[ "$file_extension" == "all" ]]; then
            # When 'all', restrict to supported package types
            if [[ "$line" != *.pkg && "$line" != *.mpkg && "$line" != *.zip && "$line" != *.dmg ]]; then
                continue
            fi
        else
            if [[ "$line" != *."$file_extension" ]]; then
                continue
            fi
        fi

        # Apply pattern filter if specified
        if [[ -n "$file_pattern" ]]; then
            if ! echo "$line" | grep -qE "$file_pattern"; then
                continue
            fi
        fi

        file_list+=("$line")
    done < <(echo "$response" | grep -oE 'href="[^"]*"' | sed 's/href="//g' | sed 's/"//g' | sort -u)

    # If --skip-orphans is enabled, filter out files not on the server
    if [[ "$skip_orphans" -eq 1 && ${#existing_packages[@]} -gt 0 ]]; then
        local filtered_list=()
        for file in "${file_list[@]}"; do
            for pkg in "${existing_packages[@]}"; do
                if [[ "$file" == "$pkg" ]]; then
                    filtered_list+=("$file")
                    break
                fi
            done
        done
        file_list=("${filtered_list[@]}")
        echo "After filtering for existing packages: ${#file_list[@]} file(s) remain"
    fi

    if [[ ${#file_list[@]} -eq 0 ]]; then
        echo "No files found matching criteria at $share_url"
        echo
        echo "Raw response (first 500 chars):"
        echo "${response:0:500}"
        exit 1
    fi

    echo "Found ${#file_list[@]} file(s):"
    for f in "${file_list[@]}"; do
        echo "   - $f"
    done
    echo
}

download_files() {
    # Download all files from the list
    echo "Downloading files to $download_dir..."

    # Clear the download directory to avoid uploading stale files
    if [[ -d "$download_dir" ]]; then
        echo "Clearing existing download directory..."
        rm -rf "$download_dir"
    fi
    mkdir -p "$download_dir"

    downloaded_files=()
    failed_downloads=()

    for file in "${file_list[@]}"; do
        # Construct the full URL
        local file_url
        if [[ "$share_url" == */ ]]; then
            file_url="${share_url}${file}"
        else
            file_url="${share_url}/${file}"
        fi

        local dest_file="$download_dir/$file"

        echo "   Downloading: $file"

        if [[ "$dry_run" -eq 1 ]]; then
            echo "      [DRY RUN] Would download from: $file_url"
            echo "      [DRY RUN] Would save to: $dest_file"
            downloaded_files+=("$dest_file")
            continue
        fi

        local curl_opts=()
        curl_opts+=("--silent")
        curl_opts+=("--location")
        curl_opts+=("--fail")
        curl_opts+=("--output")
        curl_opts+=("$dest_file")
        curl_opts+=("--progress-bar")

        if [[ -n "$share_user" && -n "$share_pass" ]]; then
            curl_opts+=("--user")
            curl_opts+=("${share_user}:${share_pass}")
        fi

        if curl "${curl_opts[@]}" "$file_url"; then
            echo "      Downloaded successfully: $dest_file"
            downloaded_files+=("$dest_file")
        else
            echo "      ERROR: Failed to download $file"
            failed_downloads+=("$file")
        fi
    done

    echo
    echo "Download complete: ${#downloaded_files[@]} succeeded, ${#failed_downloads[@]} failed"

    if [[ ${#failed_downloads[@]} -gt 0 ]]; then
        echo "Failed downloads:"
        for f in "${failed_downloads[@]}"; do
            echo "   - $f"
        done
    fi
    echo
}

collect_existing_files() {
    # Collect existing files in download directory for upload
    downloaded_files=()

    if [[ ! -d "$download_dir" ]]; then
        echo "ERROR: Download directory does not exist: $download_dir"
        exit 1
    fi

    echo "Collecting existing files from $download_dir..."

    while IFS= read -r -d '' file; do
        local filename
        filename=$(basename "$file")

        # Apply extension filter
        if [[ "$file_extension" == "all" ]]; then
            # When 'all', restrict to supported package types
            if [[ "$filename" != *.pkg && "$filename" != *.mpkg && "$filename" != *.zip && "$filename" != *.dmg ]]; then
                continue
            fi
        else
            if [[ "$filename" != *."$file_extension" ]]; then
                continue
            fi
        fi

        # Apply pattern filter if specified
        if [[ -n "$file_pattern" ]]; then
            if ! echo "$filename" | grep -qE "$file_pattern"; then
                continue
            fi
        fi

        downloaded_files+=("$file")
    done < <(find "$download_dir" -maxdepth 1 -type f -print0)

    echo "Found ${#downloaded_files[@]} file(s) to upload:"
    for f in "${downloaded_files[@]}"; do
        echo "   - $(basename "$f")"
    done
    echo
}

upload_packages() {
    # Upload packages using jamfuploader-run.sh
    if [[ ${#downloaded_files[@]} -eq 0 ]]; then
        echo "No files to upload."
        return
    fi

    echo "Uploading packages to Jamf Pro instance(s)..."
    echo

    # Build the jamfuploader-run.sh path
    local jamfuploader_script="$this_script_dir/jamfuploader-run.sh"
    if [[ ! -f "$jamfuploader_script" ]]; then
        echo "ERROR: jamfuploader-run.sh not found at $jamfuploader_script"
        exit 1
    fi

    # Loop through each selected instance
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Processing instance: $jss_instance"
        echo

        # Loop through each package file
        for pkg_file in "${downloaded_files[@]}"; do
            local pkg_name
            pkg_name=$(basename "$pkg_file")

            echo "   Uploading: $pkg_name"

            # Build the command arguments
            local upload_args=()
            upload_args+=("pkg")
            upload_args+=("--pkg")
            upload_args+=("$pkg_file")

            # Always specify instance and nointeraction to avoid prompts
            upload_args+=("--instance")
            upload_args+=("$jss_instance")
            upload_args+=("--nointeraction")

            if [[ -n "$pkg_category" ]]; then
                upload_args+=("--category")
                upload_args+=("$pkg_category")
            fi

            if [[ -n "$chosen_id" ]]; then
                upload_args+=("--user")
                upload_args+=("$chosen_id")
            fi

            if [[ -n "$dp_url_filter" ]]; then
                upload_args+=("--dp")
                upload_args+=("$dp_url_filter")
            fi

            if [[ "$skip_dp_check" -eq 1 ]]; then
                upload_args+=("--skip-dp")
            fi

            if [[ -n "$autopkg_prefs" && -f "$autopkg_prefs" ]]; then
                upload_args+=("--prefs")
                upload_args+=("$autopkg_prefs")
            fi

            if [[ -n "$verbosity_mode" ]]; then
                upload_args+=("$verbosity_mode")
            elif [[ "$quiet_mode" == "yes" ]]; then
                upload_args+=("-q")
            else
                upload_args+=("-v")
            fi

            if [[ "$replace_pkg" -eq 1 ]]; then
                upload_args+=("--replace")
            fi

            if [[ "$dry_run" -eq 1 ]]; then
                echo "      [DRY RUN] Would run: $jamfuploader_script ${upload_args[*]}"
            else
                echo "      Running: $jamfuploader_script ${upload_args[*]}"
                "$jamfuploader_script" "${upload_args[@]}"
                local upload_exit=$?
                if [[ $upload_exit -eq 0 ]]; then
                    echo "      Upload completed for: $pkg_name"
                else
                    echo "      ERROR: Upload failed for $pkg_name (exit code: $upload_exit)"
                fi
            fi
            echo
        done
        echo "Finished uploads to $jss_instance"
        echo
    done
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Default values
download_dir="/tmp/pkg-downloads"
file_extension="all"
file_pattern=""
skip_download=0
skip_upload=0
skip_orphans=0
migrate_mode=0
replace_pkg=0
dry_run=0
chosen_instances=()

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
    --url | -u)
        shift
        share_url="$1"
        ;;
    --share-user)
        shift
        share_user="$1"
        ;;
    --share-pass)
        shift
        share_pass="$1"
        ;;
    --download-dir | -o)
        shift
        download_dir="$1"
        ;;
    --file-extension | -e)
        shift
        file_extension="$1"
        ;;
    --pattern | -p)
        shift
        file_pattern="$1"
        ;;
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
    --category)
        shift
        pkg_category="$1"
        ;;
    -d | --dp)
        shift
        dp_url_filter="$1"
        ;;
    --skip-dp)
        skip_dp_check=1
        ;;
    --prefs)
        shift
        autopkg_prefs="$1"
        if [[ ! -f "$autopkg_prefs" ]]; then
            echo "ERROR: prefs file not found"
            exit 1
        fi
        ;;
    -q)
        quiet_mode="yes"
        ;;
    -v*)
        verbosity_mode="$1"
        ;;
    -j | --jamf-upload-path)
        shift
        jamf_upload_path="$1"
        ;;
    --skip-download)
        skip_download=1
        ;;
    --skip-upload)
        skip_upload=1
        ;;
    --skip-orphans)
        skip_orphans=1
        ;;
    --migrate)
        migrate_mode=1
        ;;
    --replace)
        replace_pkg=1
        ;;
    --dry-run)
        dry_run=1
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
done

echo
echo "=========================================="
echo "Download and Upload Packages Script"
echo "=========================================="
echo

# Select instances first (if uploading, using --skip-orphans, or using --migrate) so user completes all prompts upfront
if [[ "$skip_upload" -eq 0 || "$skip_orphans" -eq 1 || "$migrate_mode" -eq 1 ]]; then
    if [[ ${#chosen_instances[@]} -eq 1 ]]; then
        chosen_instance="${chosen_instances[0]}"
        echo "Running on instance: $chosen_instance"
    elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
        echo "Running on instances: ${chosen_instances[*]}"
    fi
    choose_destination_instances
fi

# If --migrate is enabled, get the distribution point URL
if [[ "$migrate_mode" -eq 1 && "$skip_download" -eq 0 ]]; then
    get_distribution_point_url
fi

# Prompt for share credentials if not provided via command line and not skipping download
# (skip if --migrate was used as credentials are already set)
if [[ "$skip_download" -eq 0 && "$migrate_mode" -eq 0 ]]; then
    prompt_for_share_credentials
fi

# If --skip-orphans is enabled, get the list of existing packages first
if [[ "$skip_orphans" -eq 1 && "$skip_download" -eq 0 ]]; then
    get_existing_packages
fi

# Download phase
if [[ "$skip_download" -eq 0 ]]; then
    get_file_list
    download_files
else
    echo "Skipping download phase..."
    collect_existing_files
fi

# Upload phase
if [[ "$skip_upload" -eq 0 ]]; then
    upload_packages
else
    echo "Skipping upload phase..."
fi

echo
echo "=========================================="
echo "Finished"
echo "=========================================="
echo
