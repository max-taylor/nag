# nag

A Claude Code plugin that injects an approved, hash-checked summary of the user's instructions on every prompt and after compaction. `README.md` covers usage.

## Spec

`spec.md` is the design source of truth: goals, non-goals, source discovery, the summary file format, hook behaviour, risks, the benchmark plan and open questions. Read it before changing behaviour. If a change conflicts with it, update the spec in the same change, or ask first when the change contradicts a goal or non-goal.

## Keep docs in sync

Every behaviour change updates, in the same change:

- `spec.md`: what changed and why, plus any decided open question or resolved risk (move it out of the open list)
- `README.md`: user-facing behaviour, config options, limits and the layout line under Develop
- `tests/run.sh`: a case for the new or changed behaviour
- `plugin.json` `userConfig` and the README Config table, together, when an option changes
- the skills, when the CLI's commands or output change, since they call it

Bump `version` in `.claude-plugin/plugin.json` for any user-visible change.

## Layout

- `scripts/nag`: the CLI (`status`, `write`, `inject`), used by both the hooks and the skills
- `scripts/lib.sh`: options, source discovery, hashing, summary-file parsing
- `hooks/hooks.json`: `UserPromptSubmit` and `SessionStart:compact` hooks, both running `inject`
- `skills/refresh`, `skills/status`
- `tests/run.sh`: CLI tests run against fixture home and project directories
- `scripts/check`: every check (shellcheck, tests, grader tests, plugin validation)
- `evals/`: the `claude plugin eval` suite (design in `docs/eval-spec.md`). Edit `evals/src/` and re-run `evals/src/build.sh`; the case dirs are build output. Eval runs cost money, so don't run them unasked
- `.claude-plugin/`: `plugin.json` and `marketplace.json`

## Constraints

- Bash 3.2 (macOS `/bin/bash`): no associative arrays, `mapfile` or `${var,,}`. Dependencies are `jq`, `shasum` and `realpath` only. The eval tooling under `evals/` may also use `node` (grader tests) and `claude`; the plugin itself may not.
- `inject` runs on every prompt. It never calls a model, it handles all files in one process per step rather than forking per file, and it always exits 0, sending errors to `$CLAUDE_PLUGIN_DATA/error.log`. Re-time it after changing the hot path; the current figures are in the spec.
- Hashes and staleness are computed by scripts, never by the model.
- Injected text is phrased as facts, not commands.
- Nothing is written to the summary file without the user's approval in `/nag:refresh`.

## Check

```bash
scripts/check
```

It runs shellcheck (configured in `.shellcheckrc`), `tests/run.sh` and strict validation of the plugin and marketplace manifests. Run it before reporting work done. CI runs the same script on macOS under `/bin/bash` 3.2 (`.github/workflows/check.yml`). This file lives in `.claude/` because strict validation rejects a `CLAUDE.md` at the plugin root.

To confirm the hooks still deliver context end to end, run `claude -p --plugin-dir .` in a project whose summary contains a unique token, and check that Claude can quote the token.
