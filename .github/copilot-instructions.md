# Copilot Instructions

## Project Overview

This is a collection of Bash scripts for managing multiple Jamf Pro instances simultaneously. The tools allow performing API operations (copy, delete, configure) across one, several, or all Jamf Pro servers defined in instance lists.

## Architecture

### Common Framework Pattern

All scripts source `_common-framework.sh` at the top using:

```bash
DIR=$(dirname "$0")
source "$DIR/_common-framework.sh"
```

This shared framework provides:
- Credential management (macOS Keychain-based via `set_credentials`)
- Instance list discovery and selection (`get_instance_list_files`, `get_instance_list`, `choose_instance_list`)
- API token handling (bearer tokens for Jamf Pro API)
- Slack webhook integration
- URL stripping/normalization (`strip_url`)
- Common curl request patterns

### Key Scripts

- **`jocads.sh`** — Copy/delete Jamf API objects between instances (source → one or many destinations)
- **`migration-tool.sh`** — Full instance migration using endpoint template files in `migration-tool-templates/`
- **`jamf-api-tool.sh`** — Wrapper around the external `jamf_api_tool.py` Python script
- **`set-credentials.sh`** — Store API credentials in macOS Keychain
- **`send-api-request.sh`** / **`send-platformapi-request.sh`** — Generic API request tools

### Instance Lists

Text files in `instance-lists/` define groups of Jamf Pro server URLs (one per line). The default list is configured via `instance-lists/default-instance-list.txt`. Lists are selected interactively or via `-il` flag. Instance list files are gitignored; only `.example` files are committed.

### Script Conventions

- Scripts support both interactive mode (no arguments) and CLI mode with flags
- Common flags: `-il` (instance list), `-i` (single instance URL), `-ai`/`--all-instances`, `-v` (verbosity)
- Temp files go to `/tmp/mjt/`
- Logs go to `$HOME/Library/Logs/JAMF/`
- XML templates are in `templates/` (for object creation) and `migration-tool-templates/` (for migration endpoints)
- `instance_list_type` variable controls whether iOS-only instances are included (`"ios"` includes all, `"mac"` excludes iOS-noted instances)

## Testing

Run the keychain lookup test:
```bash
bash _tests/test.sh <jamf-instance-url>
```

## Linting

Use [ShellCheck](https://www.shellcheck.net/) for linting:
```bash
shellcheck <script.sh>
```

Note: `_common-framework.sh` uses `# shellcheck disable=SC2154` for variables set by sourcing scripts.

## Style Conventions

- Use `echo "   [function_name] message"` for prefixed log output within functions
- Variables use `snake_case`
- Functions use `snake_case`
- Each script defines a `usage()` function for help text
- Guard against running as root with `root_check()` where needed
- macOS-specific: relies on `security` CLI for Keychain, `defaults` for plist reading
