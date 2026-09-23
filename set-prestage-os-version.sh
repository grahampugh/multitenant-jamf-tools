#!/bin/bash

# --------------------------------------------------------------------------------
# Check and (optionally) set the "Minimum Required macOS Version" enforcement on
# Computer PreStage enrollments, across one or more Jamf Pro instances.
#
# Two modes:
#   report (default) - read-only. Lists every enforced Computer PreStage with its
#                      enforcement type, specific version and a clickable URL.
#   set  (--set)     - changes the enforcement type/version. Because it re-reads
#                      each prestage afterwards, a --set run is inherently a
#                      check-and-change (it logs the before and after values).
#
# The Jamf Pro PUT /v3/computer-prestages/{id} endpoint currently returns HTTP 500
# (empty errors array) even when the write succeeds, so set mode does NOT trust the
# update's exit code -- it re-reads each prestage and confirms the stored value.
#
# Output (in /tmp):
#   report : prestage-minimum-os-report.xlsx (URLs hyperlinked) / .csv fallback
#   set    : prestage-minimum-os-update.xlsx / .csv fallback
# --------------------------------------------------------------------------------

# set instance list type (Computer PreStages = mac)
instance_list_type="mac"

# defaults
mode="report"
mode_explicit=0
target_type="MINIMUM_OS_SPECIFIC_VERSION"
target_version=""
prestage_id=""
prestage_name=""
prestage_keyword=""
only_enforced=0
dry_run=0
from_file=""
use_file_values=0
type_explicit=0

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

if [[ ! -f "$jamf_cli_path" ]]; then
    jamf_cli_path=$(which jamf-cli)
fi
if [[ ! -f "$jamf_cli_path" ]]; then
    echo "ERROR: jamf-cli not found. Please ensure jamf-cli is installed and in your PATH."
    exit 1
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Check and optionally set the minimum required macOS version on Computer PreStages.

Run with no mode flag (and interactively) to get a guided menu that walks you
through report vs set, scope, enforcement type, version and preview/apply.
Flags below skip the menu and are intended for automation.

Mode (default is report):
--report                           - read-only; list enforced prestages + URLs (default)
--set                              - change the enforcement type/version

Value (set mode):
--version X.Y.Z                    - specific macOS version (e.g. 15.7.7 or 26.5.2).
                                     If omitted (and interactive), you are prompted.
--type TYPE                        - enforcement type. If omitted (and interactive),
                                     you are prompted with a numbered menu.
                                     NO_ENFORCEMENT | MINIMUM_OS_LATEST_VERSION |
                                     MINIMUM_OS_LATEST_MAJOR_VERSION |
                                     MINIMUM_OS_LATEST_MINOR_VERSION |
                                     MINIMUM_OS_SPECIFIC_VERSION
                                     (version is cleared for non-SPECIFIC types)

Scope (set mode - default is every prestage on the instance):
--only-enforced                    - only touch prestages already != NO_ENFORCEMENT
--prestage-name "NAME"             - only the prestage exactly matching this display name
--prestage-keyword "KW"            - every prestage whose display name contains KW
                                     (case-insensitive), e.g. "shar" -> "... - Shared"
--prestage-id ID                   - only the prestage with this id (per-instance)

Bulk from a file (set mode):
--from-file FILE.csv               - apply to the instance+prestage targets in a CSV.
                                     Instance is read from column 1 and the prestage id
                                     from the computerPrestages.html?id=N URL, so column
                                     order/spacing/name typos do not matter.
--use-file-values                  - with --from-file, take EnforcementType and
                                     SpecificVersion from each row, so a mixed file can
                                     set a different value per prestage. Overrides
                                     --version / --type.

Instances:
-il | --instance-list FILENAME     - instance-list filename (without .txt)
-i  | --instance JSS_URL           - a single instance (repeatable)
-a  | --all                        - all instances in the list
--user | --client-id CLIENT_ID     - client ID / username to use

Other:
-n  | --dry-run                    - (set mode) preview changes; do not write
-x  | --nointeraction              - run without interaction
-v                                 - verbose jamf-cli output
-h  | --help                       - this help

Examples:
# Report enforced prestages across a list (read-only, default)
./set-prestage-os-version.sh -il my-mac-list --all

# Preview setting 15.7.7 on every prestage across a list
./set-prestage-os-version.sh --set --version 15.7.7 -il my-mac-list --all --dry-run

# Apply values per-row from a file
./set-prestage-os-version.sh --set --from-file targets.csv --use-file-values
USAGE
}

# run jamf-cli for the current instance ($jss_url + token already set)
jc() {
    "$jamf_cli_path" "$@" --url "$jss_url" --token-file "$token_file_for_jamfcli"
}

# friendly "Label version" for display / logs (drops empty version)
fmt_val() {
    local t="$1" v="$2" l
    l="$(label_for_type "$t")"
    if [[ -n "$v" ]]; then echo "$l $v"; else echo "$l"; fi
}

# human-readable label for an enforcement enum value
label_for_type() {
    case "$1" in
        NO_ENFORCEMENT)                  echo "No enforcement" ;;
        MINIMUM_OS_LATEST_VERSION)       echo "Latest version" ;;
        MINIMUM_OS_LATEST_MAJOR_VERSION) echo "Latest major" ;;
        MINIMUM_OS_LATEST_MINOR_VERSION) echo "Latest minor" ;;
        MINIMUM_OS_SPECIFIC_VERSION)     echo "Specific version" ;;
        *)                               echo "$1" ;;
    esac
}

# obtain a bearer token for a given instance (sets jss_instance/jss_url/token_file_for_jamfcli)
token_for_instance() {
    jss_instance="$1"
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    jss_url="$jss_instance"
    check_token || return 1
    token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_jamfcli"
}

# ---- report mode ---------------------------------------------------------------

# emit enforced prestages for the current $jss_instance:
#   name <US> enforcement-type <US> specific-version <US> full URL
report_prestages_for_instance() {
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    jss_url="${jss_instance}"

    if ! check_token; then
        echo "   [report] Could not obtain a token for $jss_url. Skipping." >&2
        return 1
    fi

    token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_jamfcli"

    local verbose_args=()
    [[ $verbose -eq 1 ]] && verbose_args+=("-v")

    local prestage_json
    prestage_json=$("$jamf_cli_path" pro computer-prestages list -o json \
        --url "$jss_url" --token-file "$token_file_for_jamfcli" "${verbose_args[@]}")

    rm -f "$token_file_for_jamfcli"

    echo "$prestage_json" | jq -r --arg base "$jss_url" '
        (if type=="object" then .results else . end)[]
        | select(.prestageMinimumOsTargetVersionType != "NO_ENFORCEMENT")
        | "\(.displayName)\(.prestageMinimumOsTargetVersionType)\(.minimumOsSpecificVersion // "")\($base)/computerPrestages.html?id=\(.id)&o=r"
    '
}

# ---- set mode: interactive pickers ---------------------------------------------

# present a numbered menu of the enforcement types and set target_type
choose_enforcement_type() {
    local types=(NO_ENFORCEMENT MINIMUM_OS_LATEST_VERSION MINIMUM_OS_LATEST_MAJOR_VERSION MINIMUM_OS_LATEST_MINOR_VERSION MINIMUM_OS_SPECIFIC_VERSION)
    local labels=("No enforcement" "Latest version" "Latest major version" "Latest minor version" "Specific version")
    local i sel
    echo
    echo "Minimum required macOS version enforcement type:"
    for i in "${!types[@]}"; do
        printf "   [%s] %s\n" "$i" "${labels[$i]}"
    done
    echo
    read -r -p "   Choose the enforcement type by number: " sel
    echo
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ -n "${types[$sel]:-}" ]]; then
        target_type="${types[$sel]}"
        echo "   Selected enforcement type: ${labels[$sel]} ($target_type)"
    else
        echo "ERROR: invalid selection. Aborting."
        exit 1
    fi
}

# offer the enforcement type menu when interactive and no --type was given
resolve_target_type() {
    [[ $type_explicit -eq 1 ]] && return 0
    [[ $use_file_values -eq 1 ]] && return 0
    [[ $no_interaction -eq 1 ]] && return 0
    choose_enforcement_type
}

# present a numbered menu of the macOS versions this instance offers and set
# target_version (requires jss_url + token_file_for_jamfcli already set)
choose_macos_version() {
    local json v i sel
    local options=()
    json=$(jc pro managed-software-updates available-updates -o json 2>/dev/null)
    while IFS= read -r v; do
        [[ -n "$v" ]] && options+=("$v")
    done < <(echo "$json" | jq -r '.availableUpdates.macOS[]?' 2>/dev/null)

    if [[ ${#options[@]} -eq 0 ]]; then
        echo "ERROR: could not retrieve available macOS versions from $jss_url." >&2
        exit 1
    fi

    echo
    echo "Available macOS versions (from $jss_url):"
    for i in "${!options[@]}"; do
        printf "   [%s] %s\n" "$i" "${options[$i]}"
    done
    echo
    read -r -p "   Choose the macOS version by number: " sel
    echo
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ -n "${options[$sel]:-}" ]]; then
        target_version="${options[$sel]}"
        echo "   Selected macOS version: $target_version"
        echo
    else
        echo "ERROR: invalid selection. Aborting."
        exit 1
    fi
}

# resolve target_version via numbered menu if a specific version is needed but
# none was supplied; $1 = an instance to source the version list from
resolve_target_version() {
    [[ "$target_type" != "MINIMUM_OS_SPECIFIC_VERSION" ]] && return 0
    [[ -n "$target_version" ]] && return 0
    [[ $use_file_values -eq 1 ]] && return 0

    if [[ $no_interaction -eq 1 ]]; then
        echo "ERROR: --version is required with MINIMUM_OS_SPECIFIC_VERSION in non-interactive mode."
        exit 1
    fi

    local qi="$1"
    if [[ -z "$qi" ]]; then
        echo "ERROR: no instance available from which to list macOS versions."
        exit 1
    fi
    if ! token_for_instance "$qi"; then
        echo "ERROR: could not authenticate to $qi to list available macOS versions."
        exit 1
    fi
    choose_macos_version
    [[ -n "$token_file_for_jamfcli" ]] && rm -f "$token_file_for_jamfcli"
    token_file_for_jamfcli=""
}

# ---- set mode: apply -----------------------------------------------------------

# collect one summary row (parallel arrays, grouped/printed at the end)
sum_add() {
    SUM_INST+=("$jss_instance"); SUM_NAME+=("$1")
    SUM_BEFORE+=("$2"); SUM_AFTER+=("$3"); SUM_RESULT+=("$4")
}

# print the set-mode summary as aligned tables, grouped by instance
print_set_summary() {
    [[ ${#SUM_NAME[@]} -eq 0 ]] && { echo; echo "   (no prestages processed)"; return; }
    local nw=8 bw=6 aw=5 i
    for i in "${!SUM_NAME[@]}"; do
        [[ ${#SUM_NAME[$i]}   -gt $nw ]] && nw=${#SUM_NAME[$i]}
        [[ ${#SUM_BEFORE[$i]} -gt $bw ]] && bw=${#SUM_BEFORE[$i]}
        [[ ${#SUM_AFTER[$i]}  -gt $aw ]] && aw=${#SUM_AFTER[$i]}
    done
    [[ $nw -gt 40 ]] && nw=40
    [[ $bw -gt 30 ]] && bw=30
    [[ $aw -gt 30 ]] && aw=30

    local verb="Results"
    [[ $dry_run -eq 1 ]] && verb="Planned changes (dry-run, nothing written)"

    # distinct instances, in first-seen order
    local insts=() inst seen x
    for i in "${!SUM_INST[@]}"; do
        seen=0
        for x in "${insts[@]}"; do [[ "$x" == "${SUM_INST[$i]}" ]] && { seen=1; break; }; done
        [[ $seen -eq 0 ]] && insts+=("${SUM_INST[$i]}")
    done

    for inst in "${insts[@]}"; do
        echo
        echo "$verb on $inst:"
        printf "   %-*s  %-*s  %-*s  %s\n" "$nw" "PreStage" "$bw" "Before" "$aw" "After" "Result"
        printf "   %-*s  %-*s  %-*s  %s\n" \
            "$nw" "$(printf '%.0s-' $(seq 1 "$nw"))" \
            "$bw" "$(printf '%.0s-' $(seq 1 "$bw"))" \
            "$aw" "$(printf '%.0s-' $(seq 1 "$aw"))" "------"
        for i in "${!SUM_NAME[@]}"; do
            [[ "${SUM_INST[$i]}" == "$inst" ]] || continue
            printf "   %-*.*s  %-*.*s  %-*.*s  %s\n" \
                "$nw" "$nw" "${SUM_NAME[$i]}" \
                "$bw" "$bw" "${SUM_BEFORE[$i]}" \
                "$aw" "$aw" "${SUM_AFTER[$i]}" "${SUM_RESULT[$i]}"
        done
    done
}

# process a single prestage id on the current instance; logs one CSV row
process_prestage() {
    local pid="$1"
    local current before_val updated after after_type after_ver after_val label want_ver status cur_type

    current=$(jc pro computer-prestages get "$pid" -o json 2>/dev/null)
    if [[ -z "$current" ]] || ! echo "$current" | jq -e '.id' >/dev/null 2>&1; then
        echo "   [$jss_instance] id $pid: could not read prestage. Skipping." >&2
        echo "$jss_instance,\"id:$pid\",\"-\",\"-\",READ_ERROR" >> "$output_csv"
        sum_add "id:$pid" "-" "-" "READ_ERROR"
        (( fail_count++ ))
        return
    fi

    label=$(echo "$current" | jq -r '.displayName // .id')
    cur_type=$(echo "$current" | jq -r '.prestageMinimumOsTargetVersionType // ""')
    before_val=$(fmt_val "$cur_type" "$(echo "$current" | jq -r '.minimumOsSpecificVersion // ""')")

    if [[ $only_enforced -eq 1 && "$cur_type" == "NO_ENFORCEMENT" ]]; then
        echo "$jss_instance,\"$label\",\"$before_val\",\"$before_val\",SKIPPED" >> "$output_csv"
        sum_add "$label" "$before_val" "$before_val" "SKIPPED"
        (( skip_count++ ))
        return
    fi

    updated=$(echo "$current" | jq --arg t "$target_type" --arg v "$target_version" '
        .prestageMinimumOsTargetVersionType = $t
        | .minimumOsSpecificVersion = (if $t == "MINIMUM_OS_SPECIFIC_VERSION" then $v else "" end)')

    want_ver=""
    [[ "$target_type" == "MINIMUM_OS_SPECIFIC_VERSION" ]] && want_ver="$target_version"

    if [[ $dry_run -eq 1 ]]; then
        after_val=$(fmt_val "$target_type" "$want_ver")
        echo "$jss_instance,\"$label\",\"$before_val\",\"$after_val\",DRY-RUN" >> "$output_csv"
        sum_add "$label" "$before_val" "$after_val" "DRY-RUN"
        (( dryrun_count++ ))
        return
    fi

    # PUT (endpoint may 500 on success, so ignore exit) then verify by re-read
    echo "$updated" | jc pro computer-prestages update "$pid" >/dev/null 2>&1 || true

    after=$(jc pro computer-prestages get "$pid" -o json 2>/dev/null)
    after_type=$(echo "$after" | jq -r '.prestageMinimumOsTargetVersionType // ""')
    after_ver=$(echo "$after" | jq -r '.minimumOsSpecificVersion // ""')
    after_val=$(fmt_val "$after_type" "$after_ver")

    if [[ "$after_type" == "$target_type" && "$after_ver" == "$want_ver" ]]; then
        status="SUCCESS"; (( success_count++ ))
    else
        status="FAILED"; (( fail_count++ ))
    fi
    echo "$jss_instance,\"$label\",\"$before_val\",\"$after_val\",$status" >> "$output_csv"
    sum_add "$label" "$before_val" "$after_val" "$status"
}

# process one instance: obtain token, enumerate prestages, apply to each
process_instance() {
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
    else
        set_credentials "$jss_instance"
    fi
    jss_url="${jss_instance}"

    if ! check_token; then
        echo "   [$jss_instance] could not obtain a token. Skipping instance." >&2
        echo "$jss_instance,\"-\",\"-\",\"-\",NO_TOKEN" >> "$output_csv"
        (( fail_count++ ))
        return
    fi
    token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
    echo "$token" > "$token_file_for_jamfcli"

    local ids=()
    if [[ -n "$prestage_id" ]]; then
        ids=("$prestage_id")
    elif [[ -n "$prestage_name" ]]; then
        local found
        found=$(jc pro computer-prestages get --name "$prestage_name" -o json 2>/dev/null | jq -r '.id // empty')
        if [[ -z "$found" ]]; then
            echo "   [$jss_instance] prestage named '$prestage_name' not found. Skipping." >&2
            echo "$jss_instance,\"$prestage_name\",\"-\",\"-\",NOT_FOUND" >> "$output_csv"
            (( fail_count++ ))
            rm -f "$token_file_for_jamfcli"
            return
        fi
        ids=("$found")
    elif [[ -n "$prestage_keyword" ]]; then
        # every prestage whose display name contains the keyword (case-insensitive)
        while IFS= read -r one; do
            [[ -n "$one" ]] && ids+=("$one")
        done < <(jc pro computer-prestages list -o json 2>/dev/null \
                 | jq -r --arg kw "$prestage_keyword" '
                     (if type=="object" then .results else . end)[]
                     | select(((.displayName // "") | ascii_downcase) | contains($kw | ascii_downcase))
                     | .id')
        if [[ ${#ids[@]} -eq 0 ]]; then
            echo "   [$jss_instance] no prestages matching keyword '$prestage_keyword'."
            echo "$jss_instance,\"keyword:$prestage_keyword\",\"-\",\"-\",NO_MATCH" >> "$output_csv"
            rm -f "$token_file_for_jamfcli"
            return
        fi
        echo "   [$jss_instance] ${#ids[@]} prestage(s) match keyword '$prestage_keyword'."
    else
        while IFS= read -r one; do
            [[ -n "$one" ]] && ids+=("$one")
        done < <(jc pro computer-prestages list -o json 2>/dev/null \
                 | jq -r '(if type=="object" then .results else . end)[] | .id')
    fi

    if [[ ${#ids[@]} -eq 0 ]]; then
        echo "   [$jss_instance] no matching prestages found."
        rm -f "$token_file_for_jamfcli"
        return
    fi

    echo "   [$jss_instance] processing ${#ids[@]} prestage(s)..."
    local pid
    for pid in "${ids[@]}"; do
        process_prestage "$pid"
    done

    rm -f "$token_file_for_jamfcli"
}

# process targets listed in a CSV. Instance = column 1; prestage id is parsed
# from the computerPrestages.html?id=<n> URL anywhere in the row.
run_from_file() {
    if [[ ! -f "$from_file" ]]; then
        echo "ERROR: --from-file '$from_file' not found."
        exit 1
    fi

    local pairs
    pairs=$(mktemp /tmp/prestage_targets.XXXXXX)
    awk -F',' -v s=$'\x1f' 'NR>1 && $1!="" {
        line=$0
        idv=""; if (match(line, /id=[0-9]+/)) idv=substr(line, RSTART+3, RLENGTH-3)
        typ=""; ver=""
        for (i=1;i<=NF;i++){
            f=$i; gsub(/\r/,"",f)
            if (f=="NO_ENFORCEMENT"||f=="MINIMUM_OS_LATEST_VERSION"||f=="MINIMUM_OS_LATEST_MAJOR_VERSION"||f=="MINIMUM_OS_LATEST_MINOR_VERSION"||f=="MINIMUM_OS_SPECIFIC_VERSION") typ=f
            else if (f ~ /^[0-9]+\.[0-9.]+$/) ver=f
        }
        if (idv!="") print $1 s idv s typ s ver
    }' "$from_file" | sort -u > "$pairs"

    local total
    total=$(wc -l < "$pairs" | tr -d ' ')
    echo "Loaded $total instance/prestage target(s) from $from_file"
    echo

    # offer the enforcement type menu (interactive, no --type), then if a specific
    # version is needed pick it from a numbered menu sourced from the first target
    # instance's available-updates
    resolve_target_type
    resolve_target_version "$(head -1 "$pairs" | cut -d$'\x1f' -f1)"

    local prev="" have_token=0
    while IFS=$'\x1f' read -r inst pid rtype rversion; do
        [[ -z "$inst" || -z "$pid" ]] && continue
        if [[ "$inst" != "$prev" ]]; then
            if [[ $have_token -eq 1 && -n "$token_file_for_jamfcli" ]]; then
                rm -f "$token_file_for_jamfcli"
            fi
            have_token=0
            jss_instance="$inst"
            if [[ "$chosen_id" ]]; then
                set_credentials "$jss_instance" "$chosen_id"
            else
                set_credentials "$jss_instance"
            fi
            jss_url="$jss_instance"
            if check_token; then
                token_file_for_jamfcli=$(mktemp /tmp/jamfcli_token.XXXXXX)
                echo "$token" > "$token_file_for_jamfcli"
                have_token=1
                echo "Processing $jss_instance..."
            else
                echo "   [$jss_instance] could not obtain a token. Skipping this instance." >&2
                echo "$jss_instance,\"-\",\"-\",\"-\",NO_TOKEN" >> "$output_csv"
                (( fail_count++ ))
            fi
            prev="$inst"
        fi
        [[ $have_token -eq 1 ]] || continue

        if [[ $use_file_values -eq 1 ]]; then
            if [[ -z "$rtype" ]]; then
                echo "   [$jss_instance] id $pid: no enforcement type found in file row. Skipping." >&2
                echo "$jss_instance,\"id:$pid\",\"-\",\"-\",NO_TYPE_IN_FILE" >> "$output_csv"
                (( fail_count++ )); continue
            fi
            if [[ "$rtype" == "MINIMUM_OS_SPECIFIC_VERSION" && -z "$rversion" ]]; then
                echo "   [$jss_instance] id $pid: SPECIFIC type but no version in file row. Skipping." >&2
                echo "$jss_instance,\"id:$pid\",\"-\",\"-\",NO_VERSION_IN_FILE" >> "$output_csv"
                (( fail_count++ )); continue
            fi
            target_type="$rtype"
            if [[ "$rtype" == "MINIMUM_OS_SPECIFIC_VERSION" ]]; then target_version="$rversion"; else target_version=""; fi
        fi

        process_prestage "$pid"
    done < "$pairs"

    [[ $have_token -eq 1 && -n "$token_file_for_jamfcli" ]] && rm -f "$token_file_for_jamfcli"
    rm -f "$pairs"
}

# ---- guided menu (shown when run interactively without --report/--set) ---------

# top-level: choose report vs set
menu_choose_mode() {
    local sel
    echo
    echo "----------------------------------------"
    echo "  PreStage macOS Version Enforcement"
    echo "----------------------------------------"
    echo "Reports and sets macOS version enforcement on Computer PreStage enrollments."
    echo
    echo "   [1] Report  - read-only check of current enforcement"
    echo "   [2] Set     - check and change the enforcement"
    echo
    read -r -p "   Choose by number [1]: " sel
    case "$sel" in
        ""|1) mode="report" ;;
        2)    mode="set" ;;
        *) echo "ERROR: invalid selection. Aborting."; exit 1 ;;
    esac
}

# set mode: choose which prestages to target
menu_choose_scope() {
    local sel
    echo
    echo "Which prestages should be changed?"
    echo "   [1] All prestages on each chosen instance"
    echo "   [2] Only prestages that already enforce a version"
    echo "   [3] Prestages whose name contains a keyword"
    echo
    read -r -p "   Choose by number [1]: " sel
    case "$sel" in
        ""|1) : ;;
        2)    only_enforced=1 ;;
        3)    echo
              echo "   Matches any prestage whose display name contains the keyword"
              echo "   (case-insensitive). e.g. 'shar' matches 'All School Devices - Shared'."
              read -r -p "   Keyword: " prestage_keyword ;;
        *) echo "ERROR: invalid selection. Aborting."; exit 1 ;;
    esac
}

# set mode: preview vs apply
menu_choose_run_mode() {
    local sel
    echo
    echo "Run mode:"
    echo "   [1] Preview only (dry-run, writes nothing)"
    echo "   [2] Apply changes"
    echo
    read -r -p "   Choose by number [1]: " sel
    case "$sel" in
        ""|1) dry_run=1 ;;
        2)    dry_run=0 ;;
        *) echo "ERROR: invalid selection. Aborting."; exit 1 ;;
    esac
}

# drive the guided flow; the enforcement-type and macOS-version pickers are
# handled later by resolve_target_type / resolve_target_version
interactive_menu() {
    menu_choose_mode
    [[ "$mode" == "report" ]] && return 0
    menu_choose_scope
    menu_choose_run_mode
}

# run "$@" in the background while showing an animated progress bar/counter.
# returns the command's exit code.
run_with_progress() {
    local label="$1"; shift
    local logf pid pct hashes rc
    logf=$(mktemp /tmp/optpkg.XXXXXX)
    ( "$@" >"$logf" 2>&1 ) &
    pid=$!
    pct=0
    while kill -0 "$pid" 2>/dev/null; do
        pct=$(( pct < 95 ? pct + 5 : 95 ))
        hashes=$(printf '#%.0s' $(seq 1 $(( pct / 5 ))))
        printf "\r   %s: [%-20s] %3d%%" "$label" "$hashes" "$pct"
        sleep 0.3
    done
    wait "$pid"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "\r   %s: [%-20s] %3d%%\n" "$label" "####################" 100
    else
        printf "\r   %s: failed (continuing; results will be saved as .csv).\n" "$label"
        tail -3 "$logf" | sed 's/^/      /'
    fi
    rm -f "$logf"
    return $rc
}

# pip install / upgrade of openpyxl, matching the JamfCLIToolkit convention
# (lib/jamf-setup.sh: python3 -m pip install --break-system-packages, with a
# plain fallback for older pip that lacks that flag).
_openpyxl_install() {
    python3 -m pip install --break-system-packages openpyxl \
        || python3 -m pip install openpyxl
}
_openpyxl_upgrade() {
    python3 -m pip install --break-system-packages --upgrade openpyxl \
        || python3 -m pip install --upgrade openpyxl
}

# currently installed openpyxl version (empty if not installed)
_openpyxl_current_version() {
    python3 -c 'import openpyxl,sys; sys.stdout.write(getattr(openpyxl,"__version__",""))' 2>/dev/null
}

# if an update is available, echo "<current> <latest>"; otherwise echo nothing
_openpyxl_update_check() {
    python3 - <<'PY' 2>/dev/null
import json, subprocess, sys
try:
    out = subprocess.check_output(
        [sys.executable, "-m", "pip", "list", "--outdated", "--format=json"],
        stderr=subprocess.DEVNULL)
    data = json.loads(out.decode() or "[]")
except Exception:
    sys.exit(0)
for p in data:
    if str(p.get("name", "")).lower() == "openpyxl":
        print(p.get("version", ""), p.get("latest_version", ""))
        break
PY
}

# optional dependency: openpyxl (only needed for formatted .xlsx output).
# - not installed  -> offer to install it (with a short why), yes/no, then continue
# - installed       -> check for an update; if one exists, report from->to and ask
#                      whether to update (you can decline and continue)
# skipped entirely in non-interactive (-x) runs.
# (The toolkit's Setup menu also manages this centrally; this is the standalone path.)
optional_openpyxl_step() {
    [[ $no_interaction -eq 1 ]] && return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -m pip --version >/dev/null 2>&1 || return 0

    local cur ov nv ans newv
    if python3 -c "import openpyxl" >/dev/null 2>&1; then
        cur=$(_openpyxl_current_version)
        echo
        echo "   Checking openpyxl for updates (currently ${cur:-unknown})..."
        read -r ov nv < <(_openpyxl_update_check)
        if [[ -z "$nv" ]]; then
            echo "   openpyxl is up to date."
            return 0
        fi
        echo "   An update is available: openpyxl $ov -> $nv"
        read -r -p "   Update now? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy] ]]; then
            run_with_progress "Updating openpyxl $ov -> $nv" _openpyxl_upgrade
            newv=$(_openpyxl_current_version)
            echo "   Updated openpyxl from $ov to ${newv:-$nv}."
        else
            echo "   Skipped; continuing with openpyxl ${cur:-$ov}."
        fi
        return 0
    fi

    # not present -> offer the optional install
    echo
    echo "Optional: install openpyxl (Python package)?"
    echo "It lets this tool save results as a formatted .xlsx spreadsheet with"
    echo "clickable prestage links; without it, results are saved as plain .csv."
    echo
    echo "   [1] Continue without it"
    echo "   [2] Install openpyxl now"
    echo
    local sel
    read -r -p "   Choose by number [1]: " sel
    if [[ "$sel" == "2" ]]; then
        run_with_progress "Installing openpyxl" _openpyxl_install
        newv=$(_openpyxl_current_version)
        [[ -n "$newv" ]] && echo "   Installed openpyxl $newv."
    fi
}

# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        --report)          mode="report"; mode_explicit=1 ;;
        --set|--apply)     mode="set"; mode_explicit=1 ;;
        --version)         shift; target_version="$1" ;;
        --type)            shift; target_type="$1"; type_explicit=1 ;;
        --only-enforced)   only_enforced=1 ;;
        --prestage-name)   shift; prestage_name="$1" ;;
        --prestage-keyword) shift; prestage_keyword="$1" ;;
        --prestage-id)     shift; prestage_id="$1" ;;
        --from-file)       shift; from_file="$1" ;;
        --use-file-values) use_file_values=1 ;;
        -il|--instance-list) shift; chosen_instance_list_file="$1" ;;
        -i|--instance)     shift; chosen_instances+=("$1") ;;
        -a|-ai|--all|--all-instances) all_instances=1 ;;
        --id|--client-id|--user|--username) shift; chosen_id="$1" ;;
        -n|--dry-run)      dry_run=1 ;;
        -x|--nointeraction) no_interaction=1 ;;
        -v|--verbose)      verbose=1 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done
echo

# optional dependency check/offer (interactive runs only)
optional_openpyxl_step

# if interactive and no mode was specified on the command line, run the menu
if [[ $no_interaction -ne 1 && $mode_explicit -ne 1 ]]; then
    interactive_menu
fi

success_count=0
fail_count=0
skip_count=0
dryrun_count=0

# ================================ REPORT MODE ===================================
if [[ "$mode" == "report" ]]; then
    output_csv="/tmp/prestage-minimum-os-report.csv"
    output_xlsx="/tmp/prestage-minimum-os-report.xlsx"
    echo "Instance,PreStage,EnforcementType,SpecificVersion,URL" > "$output_csv"

    if [[ ${#chosen_instances[@]} -eq 1 ]]; then
        echo "Running on instance: ${chosen_instances[0]}"
    elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
        echo "Running on instances: ${chosen_instances[*]}"
    fi

    choose_destination_instances

    enforced_count=0
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo
        echo "Checking Computer PreStages on $jss_instance..."

        # collect this instance's rows first, so the table can be aligned
        r_names=(); r_labels=(); r_vers=(); r_links=()
        while IFS=$'\x1f' read -r name etype eversion url; do
            [[ -z "$etype" ]] && continue
            (( enforced_count++ ))
            echo "$jss_instance,\"$name\",$etype,$eversion,$url" >> "$output_csv"
            r_names+=("$name")
            r_labels+=("$(label_for_type "$etype")")
            r_vers+=("${eversion:--}")
            r_links+=("$url")
        done < <(report_prestages_for_instance)

        if [[ ${#r_names[@]} -eq 0 ]]; then
            echo "   (no prestages with macOS version enforcement)"
            continue
        fi

        # width of the PreStage column: widest name, min 8, capped at 44
        nw=8
        for i2 in "${!r_names[@]}"; do
            [[ ${#r_names[$i2]} -gt $nw ]] && nw=${#r_names[$i2]}
        done
        [[ $nw -gt 44 ]] && nw=44

        echo
        printf "   %-*s  %-16s  %-8s  %s\n" "$nw" "PreStage" "Enforcement" "Version" "Link"
        printf "   %-*s  %-16s  %-8s  %s\n" "$nw" \
            "$(printf '%.0s-' $(seq 1 "$nw"))" "----------------" "--------" "------------------------------"
        for i2 in "${!r_names[@]}"; do
            printf "   %-*.*s  %-16s  %-8s  %s\n" "$nw" "$nw" \
                "${r_names[$i2]}" "${r_labels[$i2]}" "${r_vers[$i2]}" "${r_links[$i2]}"
        done
    done

    final_output="$output_csv"
    if command -v python3 >/dev/null 2>&1 && python3 -c "import openpyxl" >/dev/null 2>&1; then
        if python3 - "$output_csv" "$output_xlsx" <<'PY'
import csv, sys
from openpyxl import Workbook
from openpyxl.styles import Font
csv_path, xlsx_path = sys.argv[1], sys.argv[2]
wb = Workbook(); ws = wb.active; ws.title = "PreStage Min OS"
link_font = Font(color="0563C1", underline="single")
header_font = Font(bold=True)
with open(csv_path, newline="") as f:
    rows = list(csv.reader(f))
url_col = 5
for r_idx, row in enumerate(rows, start=1):
    ws.append(row)
    if r_idx == 1:
        for c_idx in range(1, len(row) + 1):
            ws.cell(row=1, column=c_idx).font = header_font
        continue
    if len(row) >= url_col and row[url_col - 1].startswith("http"):
        cell = ws.cell(row=r_idx, column=url_col)
        cell.hyperlink = row[url_col - 1]
        cell.font = link_font
for col, width in {"A": 34, "B": 30, "C": 30, "D": 16, "E": 66}.items():
    ws.column_dimensions[col].width = width
ws.freeze_panes = "A2"
wb.save(xlsx_path)
PY
        then
            rm -f "$output_csv"
            final_output="$output_xlsx"
        fi
    fi

    echo
    echo "Found $enforced_count Computer PreStage(s) with macOS version enforcement."
    echo "Saved to: $final_output"
    echo
    echo "Finished"
    echo
    exit 0
fi

# ================================= SET MODE =====================================
scope_flags=0
[[ -n "$prestage_id" ]] && (( scope_flags++ ))
[[ -n "$prestage_name" ]] && (( scope_flags++ ))
[[ -n "$prestage_keyword" ]] && (( scope_flags++ ))
if [[ $scope_flags -gt 1 ]]; then
    echo "ERROR: use only one of --prestage-name / --prestage-keyword / --prestage-id."
    exit 1
fi
if [[ $use_file_values -eq 1 && -z "$from_file" ]]; then
    echo "ERROR: --use-file-values requires --from-file."
    exit 1
fi

scope_desc="ALL prestages"
[[ -n "$prestage_name" ]] && scope_desc="prestage named '$prestage_name'"
[[ -n "$prestage_keyword" ]] && scope_desc="prestages whose name contains '$prestage_keyword'"
[[ -n "$prestage_id" ]] && scope_desc="prestage id $prestage_id"
[[ $only_enforced -eq 1 ]] && scope_desc="$scope_desc (only those already enforcing)"
[[ -n "$from_file" ]] && scope_desc="targets listed in $from_file"
[[ $use_file_values -eq 1 ]] && scope_desc="$scope_desc (values read per-row from file)"

echo "Mode: set"
echo "Scope: $scope_desc"
[[ $dry_run -eq 1 ]] && echo "(dry-run: no changes will be written)"

output_csv="/tmp/prestage-minimum-os-update.csv"
output_xlsx="/tmp/prestage-minimum-os-update.xlsx"
echo "Instance,PreStage,Before,After,Result" > "$output_csv"

# summary collection (printed as an aligned table once processing is done)
SUM_INST=(); SUM_NAME=(); SUM_BEFORE=(); SUM_AFTER=(); SUM_RESULT=()

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    echo "Running on instance: ${chosen_instances[0]}"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

if [[ -n "$from_file" ]]; then
    run_from_file
else
    choose_destination_instances
    # offer the enforcement type menu (interactive, no --type), then the version
    # menu if a specific version is needed
    resolve_target_type
    resolve_target_version "${instance_choice_array[0]}"

    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Processing $jss_instance..."
        process_instance
    done
fi

# aligned summary of what happened / will happen, grouped by instance
print_set_summary

final_output="$output_csv"
if command -v python3 >/dev/null 2>&1 && python3 -c "import openpyxl" >/dev/null 2>&1; then
    if python3 - "$output_csv" "$output_xlsx" <<'PY'
import csv, sys
from openpyxl import Workbook
from openpyxl.styles import Font
csv_path, xlsx_path = sys.argv[1], sys.argv[2]
wb = Workbook(); ws = wb.active; ws.title = "PreStage Min OS Update"
with open(csv_path, newline="") as f:
    rows = list(csv.reader(f))
for i, row in enumerate(rows, start=1):
    ws.append(row)
    if i == 1:
        for c in range(1, len(row) + 1):
            ws.cell(row=1, column=c).font = Font(bold=True)
for col, width in {"A": 40, "B": 34, "C": 34, "D": 34, "E": 12}.items():
    ws.column_dimensions[col].width = width
ws.freeze_panes = "A2"
wb.save(xlsx_path)
PY
    then
        rm -f "$output_csv"
        final_output="$output_xlsx"
    fi
fi

echo
echo "Done."
echo "   Success: $success_count   Failed/errors: $fail_count   Skipped: $skip_count   Dry-run: $dryrun_count"
echo "Log saved to: $final_output"
echo
echo "Finished"
echo
