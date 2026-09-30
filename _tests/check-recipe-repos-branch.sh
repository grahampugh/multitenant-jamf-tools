#!/usr/bin/env bash
set -uo pipefail

# Check that every AutoPkg recipe repo is on its default branch (main or
# master). For each one that isn't, offer to switch to the default branch and
# pull the latest changes.
#
# Usage: check-recipe-repos-branch.sh [recipe-repos-dir]
#   Answer y (yes), n (no) or a (all: yes to this and every remaining repo).

repos_dir="${1:-$HOME/Library/AutoPkg/RecipeRepos}"

if [ ! -d "$repos_dir" ]; then
    echo "ERROR: $repos_dir not found" >&2
    exit 1
fi

# Print the repo's default branch name (main or master), or nothing.
default_branch() {
    local repo="$1"
    local ref branch
    # Prefer the remote's default branch, if known
    if ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
        echo "${ref#origin/}"
        return
    fi
    for branch in main master; do
        if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch" \
            || git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
            echo "$branch"
            return
        fi
    done
}

# Switch the repo to its default branch and pull. Returns non-zero on failure.
switch_and_pull() {
    local repo="$1"
    local branch="$2"
    if ! git -C "$repo" checkout "$branch"; then
        echo "  ERROR: could not switch to $branch (uncommitted changes?)"
        return 1
    fi
    if ! git -C "$repo" pull --ff-only; then
        echo "  ERROR: pull failed on $branch"
        return 1
    fi
    echo "  Now on $branch and up to date"
}

on_default=0
off_default=()
switched=0
skipped=0
failed=0
no_default=0
not_git=0
yes_to_all=false

for repo in "$repos_dir"/*/; do
    repo="${repo%/}"
    name=$(basename "$repo")

    if ! git -C "$repo" rev-parse --is-inside-work-tree &>/dev/null; then
        not_git=$((not_git + 1))
        continue
    fi

    target=$(default_branch "$repo")
    if [ -z "$target" ]; then
        echo "$name: WARNING - no main or master branch found, skipping"
        no_default=$((no_default + 1))
        continue
    fi

    current=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$current" = "$target" ]; then
        on_default=$((on_default + 1))
        continue
    fi

    [ "$current" = "HEAD" ] && current="(detached HEAD)"
    off_default+=("$name")
    echo ""
    echo "$name: on '$current', default branch is '$target'"

    if [ "$yes_to_all" = false ]; then
        while true; do
            if ! read -r -p "  Switch to $target and pull? [y/n/a] " answer; then
                echo ""
                echo "No input; stopping." >&2
                exit 1
            fi
            case "$answer" in
                [Yy]) break ;;
                [Nn]) break ;;
                [Aa]) yes_to_all=true; break ;;
                *) echo "  Please answer y, n or a." ;;
            esac
        done
        if [[ "$answer" == [Nn] ]]; then
            echo "  Skipped"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    if switch_and_pull "$repo" "$target"; then
        switched=$((switched + 1))
    else
        failed=$((failed + 1))
    fi
done

echo ""
echo "========================================="
echo "Repos on default branch:  $on_default"
echo "Repos not on default:     ${#off_default[@]}"
echo "  Switched and pulled:    $switched"
echo "  Skipped:                $skipped"
echo "  Failed:                 $failed"
[ "$no_default" -gt 0 ] && echo "No main/master branch:    $no_default"
[ "$not_git" -gt 0 ] && echo "Non-git folders ignored:  $not_git"
echo "========================================="

[ "$failed" -eq 0 ]
