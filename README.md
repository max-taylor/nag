# nag

<p align="center">
  <img src="https://github.com/user-attachments/assets/6e5bf3a0-6bd3-4307-bc0d-06bb9c765739" alt="Marge Simpson at the kitchen laptop, unimpressed" width="420">
</p>

<p align="center"><em>Hrmmmmmmmmmmm</em></p>

Nag Claude into submission.

Claude is Homer. It means well, it agrees with everything in your CLAUDE.md, and forty prompts later it has forgotten the lot. nag is Marge. On every prompt, and again after compaction, she reminds it of the rules: a short summary you approved of your CLAUDE.md, rules and output style. She also notices when that summary no longer matches its sources.

Instruction files load once at session start and get buried as a session grows. A summary re-sent on every prompt keeps the key rules close to the conversation. Hand-written reminder hooks go stale silently. nag hashes the sources each summary was approved against, so a stale one is detected and flagged. Marge doesn't nag with outdated information.

## Install

```bash
# From this directory, as a local marketplace
claude plugin marketplace add ~/Code/nag
claude plugin install nag@nag

# Or for one session, while developing
claude --plugin-dir ~/Code/nag
```

Requires `jq`, `shasum` and `realpath`, all of which ship with macOS.

## Use

| Command | Does |
| --- | --- |
| `/nag:refresh [global\|project]` | Claude reads the sources, drafts a summary and shows it (or a diff against the existing one). After you approve, it saves the summary with the source hashes |
| `/nag:status [global\|project]` | Shows each scope's state, fresh, stale, missing or none, plus which sources changed |

Saving needs your permission each time: the `write` command deliberately isn't in the refresh skill's `allowed-tools`, so it serves as the final confirmation.

## How it works

**Scopes and sources.** Global is the main use: your style and process rules apply in every repo. A project summary is opt-in, for repos whose CLAUDE.md has rules worth repeating; run `/nag:refresh project` there to create one. Each scope has its own summary file, made from these sources:

| Scope | Sources | Summary file |
| --- | --- | --- |
| global | `~/.claude/CLAUDE.md`, `~/.claude/rules/**/*.md`, the active output style in `~/.claude/output-styles/` | `~/.claude/nag.md` (configurable) |
| project (git root of the working directory) | `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/**/*.md`; `AGENTS.md` and `.claude/AGENTS.md` when there is no CLAUDE.md; `CLAUDE.local.md` if enabled | `.claude/nag.md` (optional; commit it if your team runs nag) |

`@path` imports are followed, up to four hops, as Claude Code does. Rules with `paths:` frontmatter are excluded, because they only apply to matching files. Symlinks are followed. A file that is already a global source is left out of the project scope, so a dotfiles repo isn't summarised twice.

**Summary file.** Its frontmatter records the SHA-256 of each source; the body is exactly what gets injected:

```markdown
---
nag: 1
scope: global
approved: 2026-10-09T14:02:00Z
sources:
  - path: "~/.claude/CLAUDE.md"
    sha256: 3f1a…
---

Replies are at most 5 lines unless detail is requested. …
```

**Injection.** A `UserPromptSubmit` hook and a `SessionStart` hook (matcher `compact`) run `scripts/nag inject`. For each scope:

| State | Injected |
| --- | --- |
| fresh | The summary body |
| stale (a source changed, was added or was removed) | The summary body, plus a note that names the changed files and says the sources take precedence. The note is shown once per session and again after compaction |
| missing (sources but no summary) | Global: a one-line note on the first prompt of each session. Project: nothing, since project summaries are opt-in |
| none | Nothing |

The hook always exits 0, so it can never block a prompt. It takes about 200 ms on the first prompt of a session, which runs full discovery, and about 90 ms on later prompts, which only re-hash the files each summary lists.

## Configure

Set these with `/plugin configure nag`. Values are stored under `pluginConfigs` in `~/.claude/settings.json`.

| Option | Default | |
| --- | --- | --- |
| `global_summary_path` | `~/.claude/nag.md` | Point it into a dotfiles repo to version the summary. Don't put it under `~/.claude/rules/`, or it loads twice |
| `max_chars` | 1500 | Maximum length of each summary |
| `include_local` | false | Add `CLAUDE.local.md` to the project sources |

## Limits

- Only the project root is scanned. CLAUDE.md files in parent directories, nested subdirectories, the managed policy file, and project-level output styles are not sources.
- Options are read from user settings only. Hooks get them from Claude Code, but the skills read `pluginConfigs` in `~/.claude/settings.json`, so options set in a project's `.claude/settings.json` reach the hooks but not `/nag:refresh` or `/nag:status`, and the two can disagree (for example on `max_chars`).
- The summary is advisory context, not enforcement. Use Stop or PreToolUse hooks for rules that must hold.

## Develop

```bash
scripts/check    # shellcheck, the CLI tests (tests/run.sh) and strict plugin validation
```

Needs `shellcheck` (`brew install shellcheck`) and the `claude` CLI. CI (`.github/workflows/check.yml`) runs it on macOS under `/bin/bash` 3.2 for every push to `main` and every pull request.

Layout: `.claude-plugin/` (manifest and marketplace), `hooks/hooks.json`, `scripts/nag` (CLI, used by both hooks and skills), `scripts/lib.sh` (discovery, hashing, summary file), `scripts/check` (all checks, also run in CI), `skills/refresh`, `skills/status`, `tests/`. The design rationale is in `spec.md`, and the rules for keeping docs in sync are in `.claude/CLAUDE.md`.
