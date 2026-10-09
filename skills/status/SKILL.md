---
name: status
description: Show whether the nag summaries of the user's CLAUDE.md, rules and output style are fresh, stale or missing, and which source files changed. Read-only.
argument-hint: "[global|project]"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/nag status*)
---

Run `${CLAUDE_PLUGIN_ROOT}/scripts/nag status $ARGUMENTS` and report each scope's state in one line. For stale scopes, add the source files that changed. Leave out fingerprints and the `source:` list.

Each state means:

- `fresh`: the summary matches its sources.
- `stale`: sources changed since the summary was approved. The hook keeps sending the old summary and notes that it's out of date.
- `missing`: there are sources but no approved summary.
- `none`: the scope has no source files.

If a scope is stale, or global is missing, mention `/nag:refresh`. A missing project summary is optional; mention `/nag:refresh project` only in passing. Don't run it.
