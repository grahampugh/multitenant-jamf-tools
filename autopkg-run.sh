#!/bin/bash

# --------------------------------------------------------------------------------
# A script for running an autopkg recipe or recipe list on multiple instances
# --------------------------------------------------------------------------------

# set the maximum number of the curl requests to try until success
max_tries_override=2

# set instance list type
instance_list_type="mac"

# define autopkg_prefs
autopkg_prefs="${HOME}/Library/Preferences/com.github.autopkg.plist"

# define autopkg binary
autopkg_binary="/usr/local/bin/autopkg"

# --------------------------------------------------------------------------------
# ENVIRONMENT CHECKS
# --------------------------------------------------------------------------------

# source the _common-framework.sh file
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"

# Check if the script directory is set
if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

# check for autopkg
if [[ ! -f "$autopkg_binary" ]]; then
    echo "ERROR: AutoPkg is not installed on this device"
    exit 1
fi

# ensure pillow module is installed, this is required for recipes that use IconGenerator
if ! /usr/local/autopkg/python -m pip show pillow &>/dev/null; then
    echo "Installing Pillow module..."
    /usr/local/autopkg/python -m pip install --upgrade pillow
fi

# --------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------

usage() {
    cat <<'USAGE'

# AutoPkg-Run
A script for running AutoPkg recipes on one or more Jamf Pro instances.

# Requirements
- AutoPkg must be installed and configured
- Credentials for the Jamf Pro instance(s) must be set in the AutoPkg preferences or in the Keychain (the script will prompt you to run the set_credentials.sh script if not found)

Usage:
./set_credentials.sh               - set the Keychain credentials

-r | --recipe RECIPE               - recipe to run (e.g. Firefox.jamf, /path/to/recipe)
                                     (multiple values can be provided)
-l | --recipe-list LIST            - recipe-list to run (must be path to a .txt file)
-il | --instance-list FILENAME     - provide an instance list filename (without .txt)
                                     (must exist in the instance-lists folder)
-i | --instance JSS_URL            - perform action on a specific instance
                                     (must exist in the relevant instance list)
                                     (multiple values can be provided)
-a | --all | --all-instances       - perform action on ALL instances in the instance list
-x | --nointeraction               - run without checking instance is in an instance list 
                                     (prevents interactive choosing of instances)
--user | --client-id CLIENT_ID     - use the specified client ID or username
--report-plist                     - pass through the report-plist value
--dp                               - filter DPs on DP name
-e | --enabled                     - Force policy to enabled (--key POLICY_ENABLED=True)
-p | --replace                     - Replace existing pkg in Jamf Pro (for pkg uploads)
--dry-run                          - Run the processor in dry run mode.
                                     No changes will be made to the Jamf Pro server.
--no-smb | --skip-dp               - Skip the distribution point (SMB share) lookup.
                                     Use for recipes with no package upload step to
                                     speed up the run.
--analyse                          - Analyse a recipe and show its Input keys, indicating
                                     which are required or optional. Does not run the recipe.
--show-all                         - When used with --analyse, also show Other Input keys
                                     that are not in RequiredInputs or OptionalInputs.
-v[vvv]                            - add verbose output

--[args]                           - Pass through any arguments for AutoPkg
USAGE
}

analyse_recipe() {
    local recipe="$1"
    local temp_dir
    temp_dir=$(mktemp -d)
    local recipe_json_file="$temp_dir/recipe.json"
    local autopkg_info_file="$temp_dir/autopkg_info.txt"

    echo
    echo "Analysing recipe: $recipe"

    # Resolve full path to recipe file — if it's already a file path, use it directly
    local recipe_path
    if [[ -f "$recipe" ]]; then
        recipe_path="$recipe"
    else
        recipe_path=$("$autopkg_binary" info "$recipe" 2>/dev/null | grep "^Recipe file:" | sed 's/^Recipe file:[[:space:]]*//')
    fi

    # Parse RequiredInputs and OptionalInputs directly from recipe file
    local required_inputs=()
    local optional_inputs=()
    local optional_inputs_present=false

    if [[ -n "$recipe_path" && -f "$recipe_path" ]]; then
        case "$recipe_path" in
            *.recipe.yaml)
                /usr/local/autopkg/python -c "
import sys, yaml, json
with open(sys.argv[1], 'r') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
" "$recipe_path" >"$recipe_json_file" 2>/dev/null
                ;;
            *.recipe | *.recipe.plist)
                plutil -convert json -o "$recipe_json_file" "$recipe_path" 2>/dev/null
                ;;
        esac

        if [[ -s "$recipe_json_file" ]]; then
            while IFS= read -r item; do
                [[ -n "$item" ]] && required_inputs+=("$item")
            done < <(jq -r '.RequiredInputs[]? // empty' "$recipe_json_file" 2>/dev/null)

            if jq -e 'has("OptionalInputs")' "$recipe_json_file" &>/dev/null; then
                optional_inputs_present=true
                while IFS= read -r item; do
                    [[ -n "$item" ]] && optional_inputs+=("$item")
                done < <(jq -r '.OptionalInputs[]? // empty' "$recipe_json_file" 2>/dev/null)
            fi
        fi
    fi

    # Get Input keys/values from autopkg info
    "$autopkg_binary" info "$recipe" >"$autopkg_info_file" 2>/dev/null

    if [[ ! -s "$autopkg_info_file" ]]; then
        echo "ERROR: Failed to run 'autopkg info' for recipe: $recipe"
        rm -rf "$temp_dir"
        return 1
    fi

    local input_pairs_file="$temp_dir/input_pairs.txt"
    /usr/local/autopkg/python -c "
import sys, re
text = open(sys.argv[1]).read()
match = re.search(r'Input values:\s*\n(.*?)(?:\n\S|\Z)', text, re.DOTALL)
if not match:
    sys.exit(0)
block = match.group(1)
for m in re.finditer(r\"'([^']+)':\s*'([^']*)',?\", block):
    key, value = m.group(1), m.group(2)
    sys.stdout.write(key + '\t' + value + '\n')
" "$autopkg_info_file" >"$input_pairs_file" 2>/dev/null

    declare -a input_keys=()
    declare -a input_values=()
    while IFS=$'\t' read -r key value; do
        [[ -z "$key" ]] && continue
        input_keys+=("$key")
        input_values+=("$value")
    done <"$input_pairs_file"

    echo
    if [[ ${#required_inputs[@]} -gt 0 ]]; then
        echo "Required inputs (no default value — must be supplied):"
        for key in "${required_inputs[@]}"; do
            echo "  [REQUIRED] $key"
        done
        echo
    fi

    if [[ ${#input_keys[@]} -gt 0 ]]; then
        if [[ ${#required_inputs[@]} -eq 0 && "$optional_inputs_present" == "false" ]]; then
            echo "Input keys (no RequiredInputs/OptionalInputs defined — all listed):"
            for i in "${!input_keys[@]}"; do
                echo "  ${input_keys[$i]}: ${input_values[$i]}"
            done
        else
            # Show optional inputs (those in OptionalInputs list, or all non-required if no OptionalInputs)
            local optional_label="Optional inputs:"
            [[ "$optional_inputs_present" == "true" ]] && optional_label="Optional inputs (defined in OptionalInputs):"
            local has_optional=0
            local other_keys=()
            local other_values=()
            for i in "${!input_keys[@]}"; do
                local key="${input_keys[$i]}"
                local value="${input_values[$i]}"
                local is_required=0
                for req in "${required_inputs[@]}"; do
                    [[ "$req" == "$key" ]] && is_required=1 && break
                done
                [[ $is_required -eq 1 ]] && continue
                if [[ "$optional_inputs_present" == "true" ]]; then
                    local in_optional=0
                    for opt in "${optional_inputs[@]}"; do
                        [[ "$opt" == "$key" ]] && in_optional=1 && break
                    done
                    if [[ $in_optional -eq 1 ]]; then
                        [[ $has_optional -eq 0 ]] && echo "$optional_label" && has_optional=1
                        echo "  $key: $value"
                    else
                        other_keys+=("$key")
                        other_values+=("$value")
                    fi
                else
                    [[ $has_optional -eq 0 ]] && echo "$optional_label" && has_optional=1
                    echo "  $key: $value"
                fi
            done
            if [[ ${#other_keys[@]} -gt 0 && $show_all -eq 1 ]]; then
                echo
                echo "Other inputs:"
                for i in "${!other_keys[@]}"; do
                    echo "  ${other_keys[$i]}: ${other_values[$i]}"
                done
            fi
        fi
    else
        echo "No Input keys found."
    fi

    echo
    rm -rf "$temp_dir"
}

run_autopkg() {
    # run an AutoPkg recipe or recipe list. Some options may be added
    autopkg_run_options=()

    # specify the URL
    autopkg_run_options+=("--key")
    autopkg_run_options+=("JSS_URL=$jss_instance")

    # add the credentials
    # autopkg_run_options+=("--key")
    # autopkg_run_options+=("API_USERNAME=$jss_api_user")
    # autopkg_run_options+=("--key")
    # autopkg_run_options+=("API_PASSWORD=$jss_api_password")

    # temporarily clear any API clients in the AutoPkg prefs
    autopkg_run_options+=("--key")
    autopkg_run_options+=("CLIENT_ID=")
    autopkg_run_options+=("--key")
    autopkg_run_options+=("CLIENT_SECRET=")

    # echo verbosity
    echo "AutoPkg verbosity mode: $verbosity_mode"

    # determine the share (unless the caller has opted out). Looking up the
    # distribution point is only needed for recipes that upload a package
    # (JamfPackageUploader/SMB_URL). Tools that know no package upload is
    # involved can pass --no-smb to skip this lookup for speed.
    if [[ $skip_smb -eq 1 ]]; then
        echo "Skipping distribution point lookup (--no-smb)"
        smb_url=""
    else
        get_instance_distribution_point
    fi
    if [[ "$smb_url" ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("SMB_URL=$smb_url")
        # we need the new endpoints for the password. For now use the keychain
        if [[ "$dp_server" ]]; then
            get_smb_credentials
            if [[ $smb_url && $smb_user && $smb_pass ]]; then
                echo "Username and password for $dp_server found in keychain - URL=$smb_url"
                # dp_found=1
                pass_rw="$smb_pass"
            fi
        else
            echo "DP not determined. Trying AutoPkg prefs"
            pass_rw=$(defaults read "$autopkg_prefs" SMB_PASSWORD 2>/dev/null)
            if [[ ! "$pass_rw" ]]; then
                echo "ERROR: DP not determined. Cannot continue"
                return 1
            fi
        fi
        autopkg_run_options+=("--key")
        autopkg_run_options+=("SMB_USERNAME=$smb_user")
        if [[ $pass_rw ]]; then
            autopkg_run_options+=("--key")
            autopkg_run_options+=("SMB_PASSWORD=$pass_rw")
        else
            echo "ERROR: Password not found for $dp_server"
            return 1
        fi

    else
        defaults delete "$autopkg_prefs" SMB_URL 2>/dev/null
        # defaults delete "$autopkg_prefs" SMB_USERNAME 2>/dev/null
        # defaults delete "$autopkg_prefs" SMB_PASSWORD 2>/dev/null
        # autopkg_run_options+=("--key")
        # autopkg_run_options+=("jcds2_mode=True")
    fi

    # option to replace pkg
    if [[ $replace_pkg -eq 1 ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("replace_pkg=True")
    fi

    if [[ $policy_enabled -eq 1 ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("POLICY_ENABLED=True")
    fi

    # option to specify the autopkg report plist file to write to
    if [[ $report_plist ]]; then
        autopkg_run_options+=("--report-plist")
        autopkg_run_options+=("$report_plist")
    fi

    # option to run in dry run mode
    if [[ $dry_run -eq 1 ]]; then
        autopkg_run_options+=("--key")
        autopkg_run_options+=("dry_run=True")
    fi

    # add additional args
    if [[ ${#args[@]} -gt 0 ]]; then
        autopkg_run_options+=("${args[@]}")
    fi
    
    # report to Slack
    if [[ "$instance_list_file" ]]; then
        if get_slack_webhook "$instance_list_file"; then
            if [[ $slack_webhook_url ]]; then
                autopkg_run_options+=(
                    "--key"
                    "slack_webhook_url=${slack_webhook_url}"
                    "--post"
                    "com.github.grahampugh.jamf-upload.processors/JamfUploaderSlacker"
                )
            fi
        else
            echo "No Slack webhook found for $instance_list_file"
        fi
    fi

    echo

    if [[ $recipe_list ]]; then
        if ! "$autopkg_binary" run "$verbosity_mode" --recipe-list "$recipe_list" "${autopkg_run_options[@]}"; then
            echo "ERROR: AutoPkg run failed"
            return 1
        else
            echo "AutoPkg run completed for recipe-list '$recipe_list'"
        fi
    elif  [[ $recipe ]]; then
        if ! "$autopkg_binary" run "$verbosity_mode" "$recipe" "${autopkg_run_options[@]}"; then
            echo "ERROR: AutoPkg run failed"
            return 1
        else
            echo "AutoPkg run completed for recipe '$recipe'"
        fi
    else
        echo "ERROR: no recipe or recipe list supplied"
        exit 1
    fi
}


# --------------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------------

# Command line override for the above settings
args=()
chosen_instances=()
recipes=()
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -il|--instance-list)
            shift
            chosen_instance_list_file="$1"
            ;;
        -i|--instance)
            shift
            chosen_instances+=("$1")
            ;;
        -a|-ai|--all|--all-instances)
            all_instances=1
            ;;
        --id|--client-id|--user|--username)
            shift
            chosen_id="$1"
        ;;
        -x|--nointeraction)
            no_interaction=1
            ;;
        -r|--recipe)
            shift
            recipes+=("$1")
            ;;
        -l|--recipe-list)
            shift
            recipe_list="$1"
            ;;
        -p|--replace)
            replace_pkg=1
            ;;
        -d|--dp)
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
        --report-plist)
            shift
            report_plist="$1"
            ;;
        -e|--enabled)
            policy_enabled=1
            ;;
        -q)
            quiet_mode="yes"
            ;;
        -v*)
            verbosity_mode="$1"
            ;;
        --dry-run)
            dry_run=1
            ;;
        --no-smb|--skip-dp)
            skip_smb=1
            ;;
        --analyse|--analyze)
            analyse_mode=1
            ;;
        --show-all)
            show_all=1
            ;;
        -h|--help)
            usage
            exit
            ;;
        *)
            args+=("$1")
            ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if [[ ! $verbosity_mode && ! $quiet_mode ]]; then
    # default verbosity
    verbosity_mode="-v"
elif [[ $verbosity_mode == "-vvvvv"* ]]; then
    verbosity_mode="-vvvv"
elif [[ $quiet_mode ]]; then
    verbosity_mode=""
fi

# If --analyse mode, show recipe info and exit without running
if [[ $analyse_mode -eq 1 ]]; then
    if [[ ${#recipes[@]} -eq 0 ]]; then
        echo "ERROR: no recipe supplied (use -r/--recipe)"
        exit 1
    fi
    for recipe in "${recipes[@]}"; do
        analyse_recipe "$recipe"
    done
    exit 0
fi

# Ask for the instance list, show list, ask to apply to one, multiple or all

echo
echo "This script will run autopkg recipes on the instance(s) you choose."

if [[ ${#chosen_instances[@]} -eq 1 ]]; then
    chosen_instance="${chosen_instances[0]}"
    echo "Running on instance: $chosen_instance"
elif [[ ${#chosen_instances[@]} -gt 1 ]]; then
    echo "Running on instances: ${chosen_instances[*]}"
fi

# select the instances that will be changed
choose_destination_instances

if [[ ${#recipes[@]} -ge 1 ]]; then
    echo "Running recipes: ${recipes[*]}"
elif [[ "$recipe" == "" && "$recipe_list" == "" ]]; then
    printf "Enter Recipe or Recipe List to run (e.g. Firefox.jamf or /path/to/recipes.txt) : "
    read -r recipe_choice
    if [[ $recipe_choice == *".txt" ]]; then
        recipe_list="$recipe_choice"
    elif [[ $recipe_choice ]]; then
        recipe_list=""
        recipes+=("$recipe_choice")
    else
        echo "ERROR: no recipe or recipe list supplied"
        exit 1
    fi
fi

# run on specified instances
returncode=0
for instance in "${instance_choice_array[@]}"; do
    jss_instance="$instance"
    # get token
    if [[ "$chosen_id" ]]; then
        set_credentials "$jss_instance" "$chosen_id"
        echo "   [request] Using provided Client ID and stored secret for $jss_instance ($jss_api_user)"
    else
        set_credentials "$jss_instance"
        echo "   [request] Using stored credentials for $jss_instance ($jss_api_user)"
    fi
    echo "Running AutoPkg on $jss_instance..."
    if [[ $recipe_list ]]; then
        if ! run_autopkg; then
            echo "ERROR: AutoPkg run failed for $jss_instance with recipe list $recipe_list"
            returncode=1
        else
            echo "AutoPkg run completed for $jss_instance with recipe list $recipe_list"
        fi

    elif [[ ${#recipes[@]} -gt 0 ]]; then
        for recipe in "${recipes[@]}"; do
            if ! run_autopkg; then
                echo "ERROR: AutoPkg run failed for $jss_instance with recipe $recipe"
                returncode=1
            else
                echo "AutoPkg run completed for $jss_instance with recipe $recipe"
            fi
        done
    else
        echo "No recipes or recipe lists supplied"
        exit 1
    fi
done

echo 
echo "Finished"
echo
exit $returncode
