#!/usr/bin/env bash

# Script to install the bricks listed in list/list.txt

if ! command -v biobricks &> /dev/null; then
    printf "Error: biobricks is not installed\n\nRun the following: pipx install biobricks" >&2
    exit 1
fi

# Usage: ./02_install.sh [@bricks.txt|list/bricks.txt]
FILE_ARG="${1:-list/bricks.txt}"
# Strip leading '@' if provided
LIST_FILE="${FILE_ARG#@}"

if [ ! -f "$LIST_FILE" ]; then
    printf "Error: list file not found: %s\n" "$LIST_FILE" >&2
    exit 1
fi

# Read each line and install
# Create fail directory if it doesn't exist
mkdir -p fail

# Use GNU parallel to install bricks with a progress bar
# shellcheck disable=SC2016
grep -v '^[[:space:]]*$' "$LIST_FILE" | grep -v '^[[:space:]]*#' | \
    parallel --bar --results fail/info.csv '
        line="{}"
        repo_name="${line##*/}"
        brick="https://github.com/biobricks-ai/$repo_name"
        if ! biobricks install "$brick" &>> list/stdout_install.txt; then
            echo "Install failed: $brick" >&2
            echo "$brick" >> fail/failures.txt
        fi
    '