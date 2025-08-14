#!/usr/bin/env bash

# Script to get a list of public repos within biobricks-ai with a dvc.lock

if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed" >&2
    exit 1
fi

mkdir -p "list"

OWNER="biobricks-ai"

# Get list of repos as owner/name lines
repos=$(gh repo list "$OWNER" --visibility=public --limit "1000" --json name,owner --jq '.[] | "\(.owner.login)/\(.name)"')

# For each repo, check if root-level dvc.lock exists using the contents API
export TMPFILE
# shellcheck disable=SC2016
echo "$repos" | parallel --bar '
    repo="{}"
    if [ -n "$repo" ]; then
        if gh api -X GET -H "Accept: application/vnd.github.v3+json" "repos/$repo/contents/dvc.lock" >/dev/null 2>&1; then
            echo "$repo" >> "list/bricks.txt"
        fi
    fi
'
