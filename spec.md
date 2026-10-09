# nag: spec

A Claude Code plugin that keeps a short, approved summary of your rules in front of Claude on every prompt, and notices when that summary no longer matches the rules it was made from.

## Problem

CLAUDE.md, rule files and the output style load once at session start. In long sessions they get buried and Claude drifts from them. The usual workaround is a `UserPromptSubmit` hook that echoes a hand-written summary (as in `dotfiles/.claude/settings.local.json`). That works, but:

- the summary is written and maintained by hand
- nothing notices when a source file changes and the summary goes stale; it relies on a "remember to update the hook" note
- it isn't re-sent after compaction
- it's a one-off in one person's settings, not reusable

## Goals

1. Generate a summary of the always-on rules, which the user approves before it's used.
2. Store it in a file with a hash of each source, so staleness is detected mechanically.
3. Inject it on every prompt and after compaction.
4. When sources have changed, keep injecting the last approved summary, and say once per session that it's stale.
5. Support a global scope, the main use, and an opt-in project scope.

## Non-goals (v1)

- Path-scoped rules (`paths:` frontmatter). They only apply to matching files, so a summary that's always on would misapply them. They're excluded from sources.
- Prompt-triggered injection (remindcc covers that).
- Checking whether rules match the codebase (claude-drift covers that).
- Enforcement. This is advisory context. Blocking belongs in Stop or PreToolUse hooks.

## Prior art

| Project | Overlap | Gap |
| --- | --- | --- |
| [remindcc](https://github.com/JMCodes-Studio/remindcc) | Injects markdown reminders via hook | Prompt-triggered, hand-written, no staleness check |
| [post_compact_reminder](https://github.com/Dicklesworthstone/post_compact_reminder) | Re-anchors after compaction | Only says "re-read AGENTS.md" |
| [karanb192/claude-code-hooks](https://github.com/karanb192/claude-code-hooks) | `rules-injector` listed | Idea only, not built |
| [claude-drift](https://github.com/marky291/claude-drift) | Detects stale CLAUDE.md | Against code, on demand, no injection |
| [anthropics/claude-code#83306](https://github.com/anthropics/claude-code/issues/83306) | Proposes hash staleness for re-injected skills | Open feature request, skills only |

## Concepts

**Scope.** `global` (user-level files) or `project` (files in the repo). Each scope has its own summary file. Both are injected when both exist. Global is the main use, since style and process rules usually live there. Project is opt-in: it's only injected once the user has created a summary with `/nag:refresh project`, and a repo without one gets no note.

**Sources.** The files a scope's summary is made from:

| Scope | Sources (only those that exist) |
| --- | --- |
| global | `~/.claude/CLAUDE.md`, `~/.claude/rules/**/*.md` without `paths:`, the active output style file (`outputStyle` from settings, matched by frontmatter `name` or file name in `~/.claude/output-styles/`) |
| project | `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/**/*.md` without `paths:`. `AGENTS.md` and `.claude/AGENTS.md` only when there is no CLAUDE.md, matching Claude Code's default |

`@path` imports are followed up to four hops, as Claude Code does. Symlinks are followed, so dotfiles setups work. A file that is already a global source is dropped from the project scope, so a dotfiles repo isn't summarised twice. `CLAUDE.local.md` is excluded by default because it's personal and uncommitted. It can be included via config.

**Summary file.** Markdown with frontmatter. The body is exactly what gets injected.

```markdown
---
nag: 1
scope: global
approved: 2026-10-09T14:02:00Z
sources:
  - path: ~/.claude/CLAUDE.md
    sha256: 3f1a…
  - path: ~/.claude/rules/engineering.md
    sha256: 9c4e…
  - path: ~/.claude/output-styles/terse.md
    sha256: 77b0…
---

Replies are short: at most 5 lines unless detail is requested. …
```

Default locations:
- global: `~/.claude/nag.md`, configurable via `userConfig.global_summary_path` so it can live in a dotfiles repo
- project: `.claude/nag.md`. Committing it is optional: it only helps teammates who also run nag, and goes stale for them when CLAUDE.md changes

**Staleness.** A summary is stale when any of the following holds:

- the hash of a listed source differs
- a listed source is gone
- a source exists that isn't listed

All three are computed by a script, never by the model.

## Components

```
nag/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json   # lets the repo be added as a local marketplace
├── hooks/hooks.json
├── scripts/
│   ├── nag                # CLI: status | write | inject
│   └── lib.sh             # discovery, hashing, summary-file parsing
├── skills/
│   ├── refresh/SKILL.md
│   └── status/SKILL.md
└── tests/run.sh
```

Bash 3.2 plus `jq` and `shasum`, matching the existing dotfiles hooks. `inject` runs on every prompt, so it never calls a model and does each step in a single process for all files. It measured about 200 ms on the first prompt (full discovery) and about 90 ms on later prompts, which only re-hash the files each summary already lists. Added files are therefore picked up at the next session start or compaction.

### `/nag:refresh [global|project]`

Defaults to global, plus project when it already has a summary, skipping any that are fresh. A new project summary needs `/nag:refresh project`.

1. `nag status <scope>` gives the state, a fingerprint and the source paths. Claude reads the sources. (A separate `sources` command was folded into `status` in 0.3.0.)
2. Claude drafts a summary:
   - Facts, not commands ("Replies are at most 5 lines unless detail is asked for", not "You MUST…"). The hooks docs say imperative injected text can trip prompt-injection defences.
   - Only the always-on rules that are most likely to drift. Skip anything already enforced by hooks or lint.
   - The body is capped by `max_chars` (default 1,500; the hook limit is 10,000).
   - The last line points to the full sources.
3. If a summary already exists, Claude shows a diff against it. Otherwise it shows the full draft.
4. The user approves, edits or rejects it. Nothing is written without approval.
5. On approval, `nag write <scope> --expect <fingerprint>` takes the body on stdin, hashes the current sources and writes the file. The fingerprint comes from `status` at drafting time, and the write is refused if the sources changed since then. Otherwise it would record hashes of files the summary wasn't drafted from. It also refuses an empty body or one over `max_chars`.

### `/nag:status`

Shows each scope's state (fresh, stale or missing) and lists which sources changed. It doesn't modify anything.

### Hook: `nag inject`

Registered on:
- `UserPromptSubmit`: every prompt
- `SessionStart` with matcher `compact`: after compaction

Behaviour per scope:

| State | Injected |
| --- | --- |
| fresh | the summary body |
| stale | the summary body, plus one line: "nag: <scope> summary is out of date with <files>; the user can run /nag:refresh" (first prompt of each session and after compaction only, tracked in `${CLAUDE_PLUGIN_DATA}/<session_id>`) |
| missing | nothing, except a one-line note on the first prompt of a session for the global scope. A project without a summary gets no note, since project summaries are opt-in |

Global is injected first, then project. Output is a single block prefixed `nag:` so it's identifiable.

## Config (`userConfig`)

| Key | Type | Default |
| --- | --- | --- |
| `global_summary_path` | file | `~/.claude/nag.md` |
| `max_chars` | number | 1500 |
| `include_local` | boolean | false |

Injection on every prompt is not configurable: re-sending the summary each prompt is the point of the plugin. An `inject_on_every_prompt` option was removed in 0.2.0.

Options are read from the hook env, falling back to `pluginConfigs` in `~/.claude/settings.json` for the skills, which don't get the env. Options set in project settings therefore reach the hooks but not the skills. This is documented as a limit rather than handled.

## Risks and spike

1. **Plugin hook output may not reach Claude** ([#16538](https://github.com/anthropics/claude-code/issues/16538)). **Resolved:** on Claude Code 2.1.295, JSON `additionalContext` from the plugin reached Claude on both `UserPromptSubmit` and `SessionStart`. This was checked with `claude -p --plugin-dir` against a token found only in the summary; the run without the plugin returned nothing.
2. **Adherence.** Injected reminders are advisory. Not measured yet; see [Benchmark (planned)](#benchmark-planned).
3. **Hook latency.** Measured at about 200 ms (see Components).

## Benchmark (planned)

The goal is to measure whether the reminder improves adherence. This is separate from the tests: it calls the model and costs money, so it lives in `bench/` and isn't part of `tests/run.sh`.

- **Why not single-prompt evals.** Drift appears only deep in a session, so a fresh one-prompt case shows little difference.
- **Setup.** Take real long transcripts from `~/.claude/projects/` and cut them at several depths (about 20k, 80k and 150k tokens). At each cut, fork with `--resume <id> --fork-session` and send a fixed probe prompt in `-p` mode.
- **Arms.** No reminder, a hand-written echo hook, and the nag summary. All arms use the same forks and probes, with about 5 samples per cell.
- **Grading.** Scripted where possible: line caps, banned openers, `DONE.` format, prose versus bullets. Use an LLM grader only for fuzzy rules, such as "searched for an existing helper first".
- **Output.** Pass rate per arm per depth. If adherence falls with depth without a reminder and stays flat with one, the reminder helps. If both reminder arms are equal, the plugin's value is mainly the staleness check.
- **First check.** Find out whether `claude plugin eval` can seed a case from a forked transcript. If it can, use it for the arms and the baseline.

## Testing

- `tests/` holds fixture `HOME` and project directories, and runs the scripts with `HOME` overridden.
- Cases: fresh; edited source; added rule file; removed rule file; `paths:` rule ignored; symlinked source; missing summary; stale note shown once per session; both scopes ordered correctly.
- `inject` output is checked per state.

## Migration for this dotfiles repo

Once the spike passes:
1. Install the plugin. Run `/nag:refresh global` with `global_summary_path` pointing into `dotfiles/.claude/`.
2. Remove the echo hook from `.claude/settings.local.json`.
3. Remove the "when editing `terse.md`, update the hook summary" note from `CLAUDE.md`, and the matching README lines.

## Decided

- Name: `nag`. Names starting with `claude-` are reserved, so the plugin is `nag`; the repo can be `claude-nag` for searchability. The branding is Marge Simpson-style: the plugin is the strict one holding a forgetful Claude to its rules.

## Open questions

1. Should a stale summary trigger a prompt to refresh automatically (for example from SessionStart), or only a note?
2. Should the summary include the engineering rules, which `/finish` and the Stop hook already enforce, or only the communication style?
3. Should it be published to a marketplace, or kept as a personal plugin installed from this repo?
