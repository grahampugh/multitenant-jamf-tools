#!/bin/bash

# --------------------------------------------------------------------------------
# Script for extracting a single key value from downloaded Jamf Pro object files
# and compiling the results into a CSV.
#
# This is designed to be used after running:
#   ./jamfuploader-run.sh read --type <object_type> --name <object_name> \
#       --output /path/to/folder
#
# That produces files with the naming convention:
#   <jamf_instance_shortname>-<object_type>-<object_name>.(xml|json)
#
# This script extracts a specified key from each matching file and writes a CSV:
#   <object_type>-<object_name>-<key_name>.csv
# containing columns: jamf_instance_shortname, key_value
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
  ./extract-key-from-objects.sh --folder /path/to/folder --key KEY [options]

Required:
  --folder PATH         Path to folder containing downloaded object files
  --key KEY             Key name to extract from each file.
                        For XML: a simple element name (e.g. "enabled") or an
                        XPath expression (e.g. "general/enabled").
                        For JSON: a jq-compatible key path (e.g. ".enabled" or
                        ".general.enabled").

Optional:
  --type OBJECT_TYPE    Filter files by object type (e.g. "policies", "computer_groups").
                        If omitted, all object files are considered.
  --name OBJECT_NAME    Filter files by object name (e.g. "Install - JSDE").
                        If omitted, all object names are considered.
  --output FILENAME     Custom output CSV filename (default: auto-generated in
                        the same folder as <type>-<name>-<key>.csv).
  -h | --help           Show this help message.

Examples:
  # Extract "enabled" from all policy files in a folder
  ./extract-key-from-objects.sh --folder /Users/Shared/Jamf/JamfUploader \
      --type policies --key general/enabled

  # Extract a key from a specific named object
  ./extract-key-from-objects.sh --folder /Users/Shared/Jamf/JamfUploader \
      --type policies --name "Install - JSDE" --key general/enabled

  # Extract a JSON key
  ./extract-key-from-objects.sh --folder /Users/Shared/Jamf/JamfUploader \
      --type smart_computer_group_membership --name "My Group" --key .members
USAGE
}

# --------------------------------------------------------------------------------
# ARGUMENT PARSING
# --------------------------------------------------------------------------------

folder=""
key=""
object_type=""
object_name=""
output_file=""

while test $# -gt 0; do
    case "$1" in
    --folder)
        shift
        folder="$1"
        ;;
    --key)
        shift
        key="$1"
        ;;
    --type)
        shift
        object_type="$1"
        ;;
    --name)
        shift
        object_name="$1"
        ;;
    --output)
        shift
        output_file="$1"
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "ERROR: Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
done

# --------------------------------------------------------------------------------
# VALIDATION
# --------------------------------------------------------------------------------

if [[ -z "$folder" ]]; then
    echo "ERROR: --folder is required."
    usage
    exit 1
fi

if [[ ! -d "$folder" ]]; then
    echo "ERROR: Folder does not exist: $folder"
    exit 1
fi

if [[ -z "$key" ]]; then
    echo "ERROR: --key is required."
    usage
    exit 1
fi

# --------------------------------------------------------------------------------
# BUILD FILE PATTERN
# --------------------------------------------------------------------------------

# Build a glob pattern to match relevant files
# Filename format: <shortname>-<object_type>-<object_name>.(xml|json)
if [[ -n "$object_type" && -n "$object_name" ]]; then
    pattern_prefix="*-${object_type}-${object_name}."
elif [[ -n "$object_type" ]]; then
    pattern_prefix="*-${object_type}-*."
elif [[ -n "$object_name" ]]; then
    pattern_prefix="*-*-${object_name}."
else
    pattern_prefix="*-*-*."
fi

# Collect matching XML and JSON files (exclude list files which have no object name)
matching_files=()
while IFS= read -r -d '' f; do
    matching_files+=("$f")
done < <(find "$folder" -maxdepth 1 \( -name "${pattern_prefix}xml" -o -name "${pattern_prefix}json" \) -print0 2>/dev/null)

if [[ ${#matching_files[@]} -eq 0 ]]; then
    echo "ERROR: No matching files found in $folder"
    echo "Pattern: ${pattern_prefix}(xml|json)"
    exit 1
fi

echo "Found ${#matching_files[@]} matching file(s)."

# --------------------------------------------------------------------------------
# DETERMINE OUTPUT FILENAME
# --------------------------------------------------------------------------------

if [[ -z "$output_file" ]]; then
    # Auto-generate: <type>-<name>-<key_safe>.csv
    # Sanitize key for filename (replace / and . with _)
    key_safe="${key//\//_}"
    key_safe="${key_safe//./_}"
    key_safe="${key_safe#_}" # remove leading underscore from jq paths like ".enabled"

    if [[ -n "$object_type" && -n "$object_name" ]]; then
        output_file="${folder}/${object_type}-${object_name}-${key_safe}.csv"
    elif [[ -n "$object_type" ]]; then
        output_file="${folder}/${object_type}-all-${key_safe}.csv"
    elif [[ -n "$object_name" ]]; then
        output_file="${folder}/all-${object_name}-${key_safe}.csv"
    else
        output_file="${folder}/all-all-${key_safe}.csv"
    fi
fi

# --------------------------------------------------------------------------------
# EXTRACT KEY VALUES
# --------------------------------------------------------------------------------

# Write CSV header
echo "jamf_instance_shortname,key_value" > "$output_file"

count=0
errors=0

for file in "${matching_files[@]}"; do
    filename="$(basename "$file")"

    # Extract the instance shortname from the filename
    # Format: <shortname>-<object_type>-<object_name>.(xml|json)
    # The shortname is everything before the first occurrence of -<object_type>-
    # We need to parse carefully since shortnames can contain hyphens

    extension="${filename##*.}"

    # Remove extension
    name_part="${filename%.*}"

    # Extract shortname: it's the part before the first -<type>- segment
    # We determine the type from the filename by matching known patterns
    # Strategy: split on the pattern <shortname>-<type>-<objectname>
    # The type is the second segment when we know it, otherwise we find it
    if [[ -n "$object_type" ]]; then
        # We know the type, so extract shortname as everything before -<type>-
        shortname="${name_part%%-"${object_type}"-*}"
    else
        # We don't know the type; extract by finding the pattern
        # The type is between the first and second meaningful hyphen-delimited segment
        # Since shortnames can have hyphens (e.g. "acs-cob"), we match from the
        # object name end if known, otherwise use a heuristic
        if [[ -n "$object_name" ]]; then
            # Remove -<object_name> from the end, then the type is the last segment
            without_name="${name_part%-"${object_name}"}"
            # Now it's <shortname>-<type>; type is the last hyphen-delimited segment
            detected_type="${without_name##*-}"
            shortname="${without_name%-"${detected_type}"}"
        else
            # Neither type nor name known — skip if we can't reliably parse
            # Attempt: the second field is usually the type (may contain underscores)
            # Use a pattern: type fields typically contain underscores or are known words
            # Best effort: find the first segment that contains an underscore
            IFS='-' read -ra parts <<< "$name_part"
            shortname=""
            found_type=0
            for i in "${!parts[@]}"; do
                part="${parts[$i]}"
                if [[ $found_type -eq 0 && "$part" == *_* ]]; then
                    found_type=1
                    # Everything before this index is the shortname
                    shortname="${name_part%%-"${part}"-*}"
                    break
                fi
            done
            if [[ $found_type -eq 0 ]]; then
                # Fallback: first segment is shortname
                shortname="${parts[0]}"
            fi
        fi
    fi

    if [[ -z "$shortname" ]]; then
        echo "  WARNING: Could not determine shortname for $filename, skipping."
        ((errors++))
        continue
    fi

    # Extract the key value based on file type
    value=""
    if [[ "$extension" == "xml" ]]; then
        # For XML files, use xmllint with xpath
        # If the key contains /, treat as a full xpath relative to the root
        # Otherwise, search for the element anywhere with //
        if [[ "$key" == */* ]]; then
            xpath_expr="//${key}"
        else
            xpath_expr="//${key}"
        fi
        # xmllint --xpath returns the element with tags; extract text content
        raw=$(xmllint --xpath "${xpath_expr}/text()" "$file" 2>/dev/null)
        if [[ $? -eq 0 && -n "$raw" ]]; then
            value="$raw"
        else
            value="NOT FOUND"
        fi
    elif [[ "$extension" == "json" ]]; then
        # For JSON files, use jq
        # If the key doesn't start with ., add it
        if [[ "$key" != .* ]]; then
            jq_key=".${key}"
        else
            jq_key="$key"
        fi
        # Convert xpath-style slashes to jq dots
        jq_key="${jq_key//\//.}"
        # Use jq to extract; for arrays/objects output compact JSON, for scalars output raw
        raw=$(jq "($jq_key) // \"NOT FOUND\" | if type == \"array\" or type == \"object\" then tojson else tostring end" -r "$file" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            value="$raw"
        else
            value="NOT FOUND"
        fi
    else
        echo "  WARNING: Unknown file type for $filename, skipping."
        ((errors++))
        continue
    fi

    # Escape commas and quotes in the value for CSV
    if [[ "$value" == *,* || "$value" == *\"* || "$value" == *$'\n'* ]]; then
        value="${value//\"/\"\"}"
        value="\"${value}\""
    fi

    echo "${shortname},${value}" >> "$output_file"
    ((count++))
done

# Sort the CSV (keep header at top)
if [[ $count -gt 0 ]]; then
    {
        head -1 "$output_file"
        tail -n +2 "$output_file" | sort
    } > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
fi

echo
echo "Extracted key '${key}' from ${count} file(s) (${errors} error(s))."
echo "Output: ${output_file}"
