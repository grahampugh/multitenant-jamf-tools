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
--url | -u URL                     - URL of the file share (required)
--share-user USER                  - Username for HTTP Basic Auth on the file share
--share-pass PASS                  - Password for HTTP Basic Auth on the file share
--download-dir | -o DIR            - Directory to download files to 
                                     (default: /tmp/pkg-downloads)
--file-extension | -e EXT          - File extension filter (default: all)
                                     Specify an extension (e.g., pkg) to filter
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

USAGE
}

prompt_for_share_credentials() {
    # Prompt for file share credentials if not provided
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
        if [[ "$file_extension" != "all" ]]; then
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
        if [[ "$file_extension" != "all" ]]; then
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

# Prompt for credentials if not provided via command line and not skipping download
if [[ "$skip_download" -eq 0 ]]; then
    prompt_for_share_credentials
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
    # Select the instances that will be used for uploads
    if [[ ${#chosen_instances[@]} -eq 1 ]]; then
        chosen_instance="${chosen_instances[0]}"
        echo "Running on instance: $chosen_instance"
    elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
        echo "Running on instances: ${chosen_instances[*]}"
    fi
    choose_destination_instances
    upload_packages
else
    echo "Skipping upload phase..."
fi

echo
echo "=========================================="
echo "Finished"
echo "=========================================="
echo
