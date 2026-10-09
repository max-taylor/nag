---
name: status
description: Show whether the rule-anchor summaries of the user's CLAUDE.md, rules and output style are fresh, stale or missing, and which source files changed. Read-only.
argument-hint: "[global|project]"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor status*)
---

Run `${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor status $ARGUMENTS` and report each scope's state in one line. For stale scopes, add the source files that changed. Leave out fingerprints.

Each state means:

- `fresh`: the summary matches its sources.
- `stale`: sources changed since the summary was approved. The hook keeps sending the old summary and notes that it's out of date.
- `missing`: there are sources but no approved summary.
- `none`: the scope has no source files.

If a scope is stale or missing, mention `/rule-anchor:refresh`. Don't run it.
