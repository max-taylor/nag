#!/usr/bin/env bash
# Scaffold for every eval case (build.sh copies it into each case dir). Seeds the sandbox home with the test rules as
# ~/.claude/CLAUDE.md and their approved nag summary, so the live hook injects a fresh summary with no stale or missing
# note. Claude Code doesn't load the seeded CLAUDE.md in eval runs; the history's instructions entry carries the rules.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
nag=$repo/scripts/nag

mkdir -p "$HOME/.claude"
cp "$repo/evals/src/rules.md" "$HOME/.claude/CLAUDE.md"
fingerprint=$("$nag" status global | awk '/fingerprint:/ { print $2 }')
[ -n "$fingerprint" ] || { echo "seed: no fingerprint from nag status" >&2; exit 1; }
"$nag" write global --expect "$fingerprint" <"$repo/evals/src/summary.md"
