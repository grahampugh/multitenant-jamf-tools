# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A collection of Bash scripts for managing multiple Jamf Pro instances simultaneously. The tools perform API operations (copy, delete, configure, report) across one, several, or all Jamf Pro servers defined in instance lists.

Full installation and usage details: <https://github.com/grahampugh/multitenant-jamf-tools/wiki>

## Linting and Testing

```bash
# Lint a script
shellcheck <script.sh>

# Test keychain credential lookup
bash _tests/test.sh <jamf-instance-url>
```

`_common-framework.sh` uses `# shellcheck disable=SC2154` for variables that are set by sourcing scripts — this is expected.

## Architecture

### Common Framework Pattern

Every script sources `_common-framework.sh` as its foundation:

```bash
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"
```

`_common-framework.sh` (~84KB) provides credential management, instance list discovery and selection, bearer token handling, curl request wrappers with retry logic, paginated Jamf Pro API requests, Slack webhook integration, and URL normalization. New scripts must source this file rather than re-implementing these functions.

### Parallel Job Runner (reuse before hand-rolling `&`)

`_common-framework.sh` provides a generic, bash-3.2-safe parallel runner. Use it instead of writing per-script background-job/`wait`/`tail -f` loops. Because msp-toolkit tools source this framework via `source_mjt_repo`, these functions are available to msp-toolkit `.command` tools too.

- **`run_autopkg_parallel`** — run ONE recipe across many instances concurrently. Flags: `--recipe <id>`, `--instance <url>` (repeatable), `--key "K=V"` (repeatable, applied to every run), `--id <client-id/user>`, `--verbosity <-v...>`, `--log-dir <dir>` (required), `--max-concurrent <n>` (default 8), `--reporter terminal|dialog|none`, `--dialog-log <file>` (swiftDialog command file, for `--reporter dialog`), `--title <text>`. autopkg-run.sh does its own per-instance credential lookup, so no `set_credentials` is needed.
- **`run_parallel_jobs`** — generic core for anything else (multi-step per-instance pipelines, N recipes on one instance, etc.). Supply `--job <token>` (repeatable, opaque string) + `--worker <fn>` (called as `<fn> <token> <idx>`, stdout/stderr captured to a per-job log). Same `--log-dir`/`--max-concurrent`/`--reporter`/`--label-fn` options.
- Both return results in globals: `PARALLEL_PASS_LABELS[]`, `PARALLEL_FAIL_LABELS[]`, `PARALLEL_JOB_STATUS[idx]` (exit code per job, in launch order); return code is 0 only if every job passed.
- Handles concurrency throttling (poll-based; bash 3.2 has no `wait -n`), completion sentinels, and a `kill_tree` INT/TERM teardown trap that restores any pre-existing traps.
- Reference callers: `managed-device-counter.command` (msp-toolkit, dialog reporter); the `_Playground/jamf-auto-update-titles-batch-update.sh` pattern is what this generalises.

### Key Scripts

- **`jocads.sh`** — Copy/delete API objects between instances (source → one or many destinations); handles policies, computer and mobile device groups, scripts, packages, computer and mobile device configuration profiles, EAs, categories, icons, computer and mobile device App Store apps, computer and mobile device advanced searches.
- **`migration-tool.sh`** — Full instance migration using endpoint template files in `migration-tool-templates/`; supports archiving and git integration
- **`mdm-commands.sh`** — Sends MDM commands (erase, redeploy, recovery lock, unmanage, restart, etc.) to devices across instances
- **`set-credentials.sh`** — Stores API credentials (username/password or Client ID/Client Secret) in macOS Keychain
- **`send-api-request.sh`** / **`send-platformapi-request.sh`** — Generic API request tools for Classic API (XML) and Jamf Pro API (JSON)

### Instance Lists

Text files in `instance-lists/` define groups of Jamf Pro server URLs, one URL per line. A line may have an optional `, iOS` suffix to mark iOS-only instances. The default list is configured via `instance-lists/default-instance-list.txt`. Instance list `.txt` files are gitignored; only `.example` files are committed.

The `instance_list_type` variable in a script controls iOS filtering: `"ios"` includes all instances, `"mac"` excludes iOS-noted instances.

### Script Conventions

- Scripts support both **interactive mode** (no arguments — prompts user) and **CLI mode** with flags
- Common CLI flags: `-il FILENAME` (instance list name without `.txt`), `-i JSS_URL` (single instance), `-a`/`--all-instances`, `-v`/`--verbose`, `-h`/`--help`
- Temp files go to `/tmp/mjt/`; logs go to `$HOME/Library/Logs/JAMF/`
- Each script defines a `usage()` function
- Variables and functions use `snake_case`
- Log output within functions uses `echo "   [function_name] message"` (3-space indent + bracketed name)
- The main execution loop iterates: `for instance in "${instance_choice_array[@]}"; do`

### Templates and Configuration

- `templates/` — XML templates for object creation (LDAP groups, profiles, smart groups); JSON settings templates
- `migration-tool-templates/` — API endpoint lists controlling what `migration-tool.sh` reads/writes/wipes; file order matters for dependency resolution
- `recipes/` — AutoPkg YAML recipe files for Jamf operations
- `instance-lists/` — Instance URL lists (gitignored `.txt` files; `.example` templates committed)
- `slack-webhooks/` - Slack webhooks stored in filenames that match those in the instance-lists folder (gitignored `.txt` files; `.example` templates committed).
- `exclusion-lists/` - Lists of patterns for API objects that should be excluded from overwriting when using Copy-and-Overwrite modes (`Cd`, `Cn`) in `jocads.sh`.

### Platform Requirements

macOS only — scripts rely on:

- `security` CLI for Keychain credential storage/retrieval
- `defaults` for plist reading (AutoPkg preferences)
- `curl`, `jq`, `xmllint`, `sed`, `awk`, `grep`
- Bash 3 (native bash for macOS)
- AutoPkg (required for some scripts)
- `jamf-api-tool.py` (separate repo: <https://github.com/grahampugh/jamf-api-tool>) (required for `jamf-api-tool.sh`)
