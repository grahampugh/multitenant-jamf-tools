#!/bin/bash

# --------------------------------------------------------------------------------
# Script for finding downloaded Jamf Pro object files whose "criteria" array
# contains an entry matching a set of field conditions.
#
# This is designed to be used after running:
#   ./jamfuploader-run.sh read --type <object_type> --name <object_name> \
#       --output /path/to/folder
#
# That produces files with the naming convention:
#   <jamf_instance_shortname>-<object_type>-<object_name>.(xml|json)
#
# This script checks the "criteria" array in each file for an entry where all
# supplied --match KEY=VALUE conditions are true within a single criteria object,
# and writes a CSV of the matching files.
# --------------------------------------------------------------------------------

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
  ./find-matching-criteria-pattern.sh --folder /path/to/folder --match KEY=VALUE [options]

Required:
  --folder PATH         Path to folder containing downloaded object files.
  --match KEY=VALUE     A field condition that must match within a single criteria
                        object. Can be specified multiple times; all conditions must
                        be satisfied by the same criteria entry.
                        Use an empty value to match empty/blank fields (e.g.
                        --match "value=").

Optional:
  --type OBJECT_TYPE    Filter files by object type (e.g. "smart_groups").
                        If omitted, all object files are considered.
  --name OBJECT_NAME    Filter files by object name.
                        If omitted, all object names are considered.
  --output FILENAME     Custom output CSV filename (default: auto-generated in
                        the same folder).
  -h | --help           Show this help message.

Examples:
  # Find smart groups where a criteria has name "Application Bundle ID" with an
  # empty value
  ./find-matching-criteria-pattern.sh \
      --folder /Users/Shared/Jamf/JamfUploader \
      --type smart_groups \
      --match "name=Application Bundle ID" \
      --match "value="

  # Find any object with a criteria whose searchType is "matches regex"
  ./find-matching-criteria-pattern.sh \
      --folder /Users/Shared/Jamf/JamfUploader \
      --match "searchType=matches regex"
USAGE
}

# --------------------------------------------------------------------------------
# ARGUMENT PARSING
# --------------------------------------------------------------------------------

folder=""
object_type=""
object_name=""
output_file=""
match_conditions=()

while test $# -gt 0; do
    case "$1" in
    --folder)
        shift
        folder="$1"
        ;;
    --match)
        shift
        match_conditions+=("$1")
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

if [[ ${#match_conditions[@]} -eq 0 ]]; then
    echo "ERROR: At least one --match KEY=VALUE is required."
    usage
    exit 1
fi

# Validate each match condition has the KEY=VALUE form
for cond in "${match_conditions[@]}"; do
    if [[ "$cond" != *=* ]]; then
        echo "ERROR: Invalid --match format: '$cond' (expected KEY=VALUE)"
        exit 1
    fi
done

# Check for jq (required for JSON) and xmllint (required for XML)
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not found in PATH."
    exit 1
fi

# --------------------------------------------------------------------------------
# BUILD JQ FILTER FROM MATCH CONDITIONS
# --------------------------------------------------------------------------------

# Build a jq filter that checks .criteria[] for an entry matching all conditions.
# Each --match KEY=VALUE becomes: .KEY == "VALUE"
# They are ANDed together inside a select().
jq_tests=()
for cond in "${match_conditions[@]}"; do
    match_key="${cond%%=*}"
    match_val="${cond#*=}"
    # Escape backslashes and double quotes in value for embedding in jq string
    match_val_escaped="${match_val//\\/\\\\}"
    match_val_escaped="${match_val_escaped//\"/\\\"}"
    jq_tests+=(".${match_key} == \"${match_val_escaped}\"")
done

# Join tests with " and "
jq_condition=""
for i in "${!jq_tests[@]}"; do
    if [[ $i -eq 0 ]]; then
        jq_condition="${jq_tests[$i]}"
    else
        jq_condition="${jq_condition} and ${jq_tests[$i]}"
    fi
done

# Final jq filter: returns true if any criteria entry matches all conditions
jq_filter="[.criteria[] | select(${jq_condition})] | length > 0"

echo "Criteria filter: ${jq_condition}"

# --------------------------------------------------------------------------------
# BUILD XPATH FILTER FROM MATCH CONDITIONS (for XML files)
# --------------------------------------------------------------------------------

# Build an XPath predicate for criteria elements.
# Structure varies, but a common Jamf XML layout is:
#   <criteria><criterion><name>...</name><value>...</value></criterion></criteria>
# We build: //criterion[name="X" and value="Y"]
xpath_predicates=()
for cond in "${match_conditions[@]}"; do
    match_key="${cond%%=*}"
    match_val="${cond#*=}"
    if [[ -z "$match_val" ]]; then
        # Match empty element: either missing text content or empty string
        xpath_predicates+=("(${match_key}='' or not(${match_key}/text()))")
    else
        xpath_predicates+=("${match_key}='${match_val}'")
    fi
done

xpath_predicate=""
for i in "${!xpath_predicates[@]}"; do
    if [[ $i -eq 0 ]]; then
        xpath_predicate="${xpath_predicates[$i]}"
    else
        xpath_predicate="${xpath_predicate} and ${xpath_predicates[$i]}"
    fi
done

xpath_filter="//criterion[${xpath_predicate}]"

# --------------------------------------------------------------------------------
# BUILD FILE PATTERN
# --------------------------------------------------------------------------------

if [[ -n "$object_type" && -n "$object_name" ]]; then
    pattern_prefix="*-${object_type}-${object_name}."
elif [[ -n "$object_type" ]]; then
    pattern_prefix="*-${object_type}-*."
elif [[ -n "$object_name" ]]; then
    pattern_prefix="*-*-${object_name}."
else
    pattern_prefix="*-*-*."
fi

# Collect matching XML and JSON files
matching_files=()
while IFS= read -r -d '' f; do
    matching_files+=("$f")
done < <(find "$folder" -maxdepth 1 \( -name "${pattern_prefix}xml" -o -name "${pattern_prefix}json" \) -print0 2>/dev/null)

if [[ ${#matching_files[@]} -eq 0 ]]; then
    echo "ERROR: No matching files found in $folder"
    echo "Pattern: ${pattern_prefix}(xml|json)"
    exit 1
fi

echo "Found ${#matching_files[@]} file(s) to check."

# --------------------------------------------------------------------------------
# DETERMINE OUTPUT FILENAME
# --------------------------------------------------------------------------------

if [[ -z "$output_file" ]]; then
    # Build a short label from the match conditions
    label=""
    for cond in "${match_conditions[@]}"; do
        match_key="${cond%%=*}"
        match_val="${cond#*=}"
        # Truncate long values for the filename
        if [[ ${#match_val} -gt 20 ]]; then
            match_val="${match_val:0:20}"
        fi
        # Sanitize for filename
        safe="${match_key}-${match_val}"
        safe="${safe// /_}"
        safe="${safe//\//_}"
        if [[ -n "$label" ]]; then
            label="${label}_${safe}"
        else
            label="$safe"
        fi
    done

    if [[ -n "$object_type" ]]; then
        output_file="${folder}/${object_type}-criteria-${label}.csv"
    else
        output_file="${folder}/all-criteria-${label}.csv"
    fi
fi

# --------------------------------------------------------------------------------
# CHECK EACH FILE FOR MATCHING CRITERIA
# --------------------------------------------------------------------------------

# Write CSV header
echo "jamf_instance_shortname,filename,object_name,matched_criteria" > "$output_file"

hits=0
checked=0
errors=0

for file in "${matching_files[@]}"; do
    filename="$(basename "$file")"
    extension="${filename##*.}"
    name_part="${filename%.*}"

    # ---- Extract shortname (same logic as extract-key-from-objects.sh) ----
    if [[ -n "$object_type" ]]; then
        shortname="${name_part%%-"${object_type}"-*}"
        obj_name="${name_part#"${shortname}-${object_type}-"}"
    else
        if [[ -n "$object_name" ]]; then
            without_name="${name_part%-"${object_name}"}"
            detected_type="${without_name##*-}"
            shortname="${without_name%-"${detected_type}"}"
            obj_name="$object_name"
        else
            IFS='-' read -ra parts <<< "$name_part"
            shortname=""
            found_type=0
            for i in "${!parts[@]}"; do
                part="${parts[$i]}"
                if [[ $found_type -eq 0 && "$part" == *_* ]]; then
                    found_type=1
                    shortname="${name_part%%-"${part}"-*}"
                    remaining="${name_part#"${shortname}-"}"
                    detected_type="${remaining%%-*}"
                    obj_name="${remaining#"${detected_type}-"}"
                    break
                fi
            done
            if [[ $found_type -eq 0 ]]; then
                shortname="${parts[0]}"
                obj_name="$name_part"
            fi
        fi
    fi

    if [[ -z "$shortname" ]]; then
        echo "  WARNING: Could not determine shortname for $filename, skipping."
        ((errors++))
        continue
    fi

    # ---- Check criteria ----
    matched=0
    matched_detail=""

    if [[ "$extension" == "json" ]]; then
        # Check if the file has a criteria array at all
        has_criteria=$(jq 'has("criteria")' "$file" 2>/dev/null)
        if [[ "$has_criteria" != "true" ]]; then
            ((checked++))
            continue
        fi

        # Run the filter
        result=$(jq "$jq_filter" "$file" 2>/dev/null)
        if [[ "$result" == "true" ]]; then
            matched=1
            # Extract a compact summary of the matching criteria entry/entries
            matched_detail=$(jq -r "[.criteria[] | select(${jq_condition})] | map(.name + \" \" + .searchType + \" '\" + .value + \"'\") | join(\"; \")" "$file" 2>/dev/null)
        fi

    elif [[ "$extension" == "xml" ]]; then
        if ! command -v xmllint &>/dev/null; then
            echo "  WARNING: xmllint not available, skipping XML file $filename."
            ((errors++))
            continue
        fi

        # Check if criteria element exists
        has_criteria=$(xmllint --xpath '//criteria' "$file" 2>/dev/null)
        if [[ -z "$has_criteria" ]]; then
            ((checked++))
            continue
        fi

        # Run the XPath filter
        result=$(xmllint --xpath "${xpath_filter}" "$file" 2>/dev/null)
        if [[ -n "$result" ]]; then
            matched=1
            # Extract a readable summary from the matched XML
            matched_detail=$(xmllint --xpath "${xpath_filter}/name/text()" "$file" 2>/dev/null)
            search_type=$(xmllint --xpath "${xpath_filter}/searchType/text()" "$file" 2>/dev/null)
            match_value=$(xmllint --xpath "${xpath_filter}/value/text()" "$file" 2>/dev/null)
            matched_detail="${matched_detail} ${search_type} '${match_value}'"
        fi
    else
        echo "  WARNING: Unknown file type for $filename, skipping."
        ((errors++))
        continue
    fi

    ((checked++))

    if [[ $matched -eq 1 ]]; then
        ((hits++))

        # Escape fields for CSV
        for var in obj_name matched_detail; do
            val="${!var}"
            if [[ "$val" == *,* || "$val" == *\"* || "$val" == *$'\n'* ]]; then
                val="${val//\"/\"\"}"
                val="\"${val}\""
                printf -v "$var" '%s' "$val"
            fi
        done

        echo "${shortname},${filename},${obj_name},${matched_detail}" >> "$output_file"
    fi
done

# Sort the CSV (keep header at top)
if [[ $hits -gt 0 ]]; then
    {
        head -1 "$output_file"
        tail -n +2 "$output_file" | sort
    } > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
fi

echo
echo "Checked ${checked} file(s), found ${hits} match(es) (${errors} error(s))."
echo "Output: ${output_file}"
