#!/usr/bin/env bash
# Shared helpers for the eval build scripts. Sourced, not run.

# Prints a grader file's regex: its body, after the frontmatter.
grader_pattern() { awk 'n >= 2 { print } /^---$/ { n++ }' "$1"; }
