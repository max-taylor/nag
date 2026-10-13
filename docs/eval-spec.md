# nag eval suite: spec

Status: pilot run 2026-10-13, no difference between nag on and off; project abandoned (see README). Owner: Max. Written 2026-10-12.

## 1. Question

Does Claude follow CLAUDE.md rules more reliably in a long session when nag is enabled than when it isn't, and how does that change as the context fills?

Two kinds of rule are tested:

- **General rules** that apply to every reply (style).
- **Situational rules** that apply only to certain tasks (a status update, a commit message), the kind loaded long before they're needed.

## 2. What the eval tool allows

These were confirmed by running throwaway probe cases against `claude plugin eval` (CLI 2.1.296) and by reading https://code.claude.com/docs/en/plugin-evals.md. The implementation depends on all of them.

| Fact | Evidence |
| --- | --- |
| Each run gets a fresh sandbox: `HOME=/private/tmp/e-XXXX/home`, working dir `$HOME/cwd`, separate Claude config dir. The user's real `~/.claude` (including their real `nag.md`) is never read | probe output |
| CLAUDE.md files never load in eval runs, even ones a scaffold writes ("Nothing personal or project-level loads … even one a `scaffold_script` wrote") | docs + probe (no `instructions` entry in the session record) |
| `context.scaffold_script` (case.yaml, `schema_version: "1.1"`) runs a bash script from the case dir in the empty workspace before Claude starts, with `HOME` set to the sandbox home, only when the run passes `--scaffold`. `$0` is the script's real path in the repo, so it can call `scripts/nag`. 120 s limit, minimal env, no `EVAL_*` vars | docs + probe |
| `context.history_file` (case.yaml) replays a `.jsonl` session transcript; the case prompt becomes the next user turn | docs + probe |
| An `attachment` entry of type `instructions` in the history is shown to the model as the session's CLAUDE.md, in the same place as in a real session | probe: model listed `CLAUDE_MD` marker first |
| **But don't use one.** On resume Claude Code re-reads instruction files, finds none in the sandbox and adds "Instruction files were re-read when this session started. Instructions no longer present: /workspace/CLAUDE.md". The model then drops the rules on purpose: at `l0` the `plain`/without cell scored 0.44 and its reply ended "The CLAUDE.md with the team's status-update conventions is no longer present in this session, so I haven't applied them." That would hand nag a large fake Δ. The history instead puts the rules in turn 1's user message, in the `<system-reminder>` context block Claude Code renders CLAUDE.md into (§4.1). With that, every `l0` cell scored 1.00 | implementation pilot (Sonnet 5.5, `l0-*-plain`, 1 run per arm) |
| An `attachment` entry of type `hook_additional_context` in the history is shown to the model after the user turn it's attached to | probe |
| nag's live `UserPromptSubmit` reminder lands after the case prompt, in the with-plugin arm only | probe: order was `CLAUDE_MD`, history, `PROMPT`, `NAG` |
| Both arms get the same history and scaffold output; nothing tells the scaffold which arm it's in (env, sandbox layout and config are identical) | probe diff + docs |
| Recorded `hook_additional_context` entries in the history replay in both arms | probe |
| Case `env` accepts only `EVAL_*` keys; `prompt.md` frontmatter doesn't accept `scaffold_script` or `context` | runner errors |
| `--keep-temp` keeps each run's sandbox (`out/trace.jsonl`, `config/projects/*/<session>.jsonl`); `home/` and `tmp/` are sealed (mode 000) and need `chmod 700` to inspect | runner output |

## 3. Design

### 3.1 One test run

```
system prompt
history.jsonl
  turn 1  user: CLAUDE.md context block (test rules) + "Let's pick up the billing service work."
          assistant: short reply
  turns 2..N  filler conversation                          (+ nag reminder on every user turn in -nag cases)
case prompt: the request                                   (+ live nag reminder, with-plugin arm only)
reply  →  graders
```

The scaffold seeds `~/.claude/CLAUDE.md` (the rules, so the summary's hashes are fresh) and `~/.claude/nag.md` (via `scripts/nag write global`) so the live hook injects the real summary with no stale or missing note. Claude Code never loads the seeded CLAUDE.md (§2); the model sees the rules only through the history's turn 1 context block.

### 3.2 Paired cases

The tool can't give the two arms different histories (§2), so every test is a pair of cases built from the same base history:

| History | Contents |
| --- | --- |
| `nag` | base + a `hook_additional_context` entry with nag's reminder after every user turn, as real use would have |
| `plain` | base, unchanged |

Every case runs with the plugin loaded (`--ablation none`). Only `nag` cases have a scaffold. A `plain` case's sandbox has no CLAUDE.md and no summary, so nag's hook injects nothing (state `none`). That gives two cells per pair:

| | |
| --- | --- |
| `nag` history, seeded | **nag on**: history reminders + the live one |
| `plain` history, unseeded | **nag off**: no reminders |

**Headline result = nag on minus nag off**, computed by `report.sh` (§4.7). The only other difference between the cells is that nag's two skills appear in the skill list in both, which is negligible.

The first design ran both histories in both arms (`--ablation with-without`). That gave two more cells, "history reminders only" and "live reminder only", to show how much of the effect comes from accumulated reminders versus the latest one. They doubled the cost: the pilot hit a plan session limit after 17 of 48 runs (about $4 at list price, l1 runs at ~$0.70 each). If the headline shows an effect, a targeted two-arm run on one level can answer the attribution question later.

Within a pair, the assistant text in the history is identical. In real use nag would also have kept the earlier replies on track, so this understates nag slightly. It doesn't favour it.

### 3.3 Fill levels and filler style

Levels are nested prefixes of one filler sequence: a bigger level is the smaller one plus more turns. Token targets are configurable in `build.sh`.

| Level | Filler | Filler style |
| --- | --- | --- |
| `l0` | none (turn 1 only) | n/a |
| `l1` | ~50k tokens | natural |
| `l2` | ~150k tokens | natural |
| `l2c` | ~150k tokens | corrected |

- **Natural:** the filler as generated. Claude's own style shows up in the assistant turns (em dashes, headings, bold), so those turns break the general rules, as in a session that has already drifted. This is the harder test: can the reminder pull Claude back?
- **Corrected:** the same filler after `normalise-filler.sh` (§4.3) removes those features, as in a session that has stayed on track. It tests whether Claude stays compliant. It runs at one level only, to limit cost.

The filler never contains a status update or a commit message, so it's neutral on the situational rules in both styles.

### 3.4 Rules under test

The test CLAUDE.md (`src/rules.md`) states:

**General (every reply)**

- G1. Replies never use em dashes (`—`).
- G2. Replies don't use markdown headings.
- G3. Replies don't use bold text.
- G4. Replies are at most 120 words unless the user asks for detail. Added after the first pilot: Opus held G1–G3 and every situational rule at `l2` with nag off, while the drift seen in real use is mostly creeping verbosity. The filler's replies are 1,500–2,500 words, so the history pulls hard against it.

**Status updates**

- S1. A status update starts with a line `STATUS: green`, `STATUS: amber` or `STATUS: red`.
- S2. Dates in status updates are written YYYY-MM-DD.
- S3. Next steps in a status update are a `-` bullet list, never numbered.
- S4. A status update ends with a line `[end]`.

**Commit messages**

- C1. Commit messages use `type(scope): subject`.
- C2. The subject line is at most 50 characters.
- C3. The subject line ends with the ticket ID in square brackets, e.g. `[BIL-482]`.

It may also hold a few unrelated, realistic rules as padding (e.g. about tests or naming) that no request triggers. `src/summary.md` is the nag summary of all of it, written in nag's style: facts, not commands, under `max_chars`.

The rules were chosen so that each is a yes/no regex check and none is Claude's default behaviour. Otherwise both sides pass and the difference is hidden.

### 3.5 Requests

Each request supplies every fact it needs, so it can be done at every fill level and doesn't depend on the filler.

**Status (`src/requests/status.md`).** Triggers G and S rules. Dates are given in month-name form to tempt the wrong format.

> Write today's status update for the team. Changed: the ledger export now streams; the rate limiter moved to the gateway. Milestones: Beta demo on 14 November 2026, Public launch on 2 December 2026. Next steps: load-test the export, migrate the remaining webhooks, write the runbook.

**Commit (`src/requests/commit.md`).** Triggers G and C rules.

> Write the commit message for this change: invoice sync retries now send an idempotency key so a retried request can't charge a customer twice. Ticket BIL-482.

**Question (`src/requests/question.md`).** Triggers only the G rules. It's the negative case for the situational rules: nag's reminder shouldn't make Claude apply the status or commit format where it doesn't belong.

> In plain prose with no code, explain how a retry in invoice sync could charge a customer twice, and what usually prevents it.

### 3.6 Case matrix

Case name: `<level>-<request>-<history>`, e.g. `l1-status-nag`, `l2c-commit-plain`.

| Factor | Values | Count |
| --- | --- | --- |
| Level | `l0`, `l1`, `l2`, `l2c` | 4 |
| Request | `status`, `commit`, `question` | 3 |
| History | `nag`, `plain` | 2 |

- **24 cases.**
- Each case runs once per run, × 3 runs, so **72 Claude sessions per full suite**.
- Cost at list price on Opus, from the pilot: about $0.06 per `l0` run, $0.68 per `l1` run and an estimated $1.90 per `l2`/`l2c` run. A full suite is about $80, and the routine run (`l1` and `l2`, §6) about $46.

## 4. Components

```
evals/
├── src/                          hand-edited sources
│   ├── rules.md                  test CLAUDE.md (§3.4)
│   ├── summary.md                nag summary body for rules.md
│   ├── requests/                 status.md, commit.md, question.md (§3.5)
│   ├── graders/
│   │   ├── general/              G1–G3, applied to every case
│   │   ├── status/               S1–S4 + task-done
│   │   ├── commit/               C1–C3 + task-done
│   │   └── question/             not-status, not-commit + task-done
│   ├── filler/                   outline.json + part-NN.json.gz, natural style, generated once, committed, never edited
│   ├── gen-filler.sh             one-off filler generator (§4.2)
│   ├── normalise-filler.sh       natural → corrected style (§4.3)
│   ├── build.sh                  writes every case dir from src (§4.4)
│   ├── seed.sh                   scaffold shared by every case (§4.5)
│   ├── report.sh                 headline tables from aggregate-result.json (§4.7)
│   ├── lib.sh                    shared helper (grader_pattern)
│   └── test-graders.mjs          checks every grader against handwritten replies (§5)
└── l0-status-nag/ … l2c-question-plain/      24 case dirs, build output, not hand-edited
```

To swap rules, requests or graders, edit `src/` and re-run `build.sh`. The filler only needs regenerating if a new general rule can't be applied mechanically by `normalise-filler.sh`.

### 4.1 History file format

One JSON object per line, linked by `parentUuid` (first entry `null`). Minimal shape that the probe confirmed works:

```json
{"type":"user","uuid":"U1","parentUuid":null,"sessionId":"S","timestamp":"…","isSidechain":false,"userType":"external","entrypoint":"sdk-cli","cwd":"/workspace","version":"2.1.296","message":{"role":"user","content":[{"type":"text","text":"<CLAUDE.md context block>"},{"type":"text","text":"Let's pick up the billing service work."}]}}
{"type":"attachment","uuid":"H1","parentUuid":"U1", …common fields…,"attachment":{"type":"hook_additional_context", …}}   (nag histories only)
{"type":"assistant","uuid":"R1","parentUuid":"H1", …common fields…,"message":{"role":"assistant","type":"message","model":"claude-sonnet-5-5","content":[{"type":"text","text":"…"}]}}
{"type":"user","uuid":"U2","parentUuid":"R1", …}
{"type":"attachment","uuid":"H2","parentUuid":"U2", …,"attachment":{"type":"hook_additional_context","content":["<nag reminder>"],"hookName":"UserPromptSubmit","hookEvent":"UserPromptSubmit","toolUseID":"hook-2"}}
{"type":"assistant","uuid":"R2","parentUuid":"H2", …}
```

- `plain` histories have no `hook_additional_context` entries, and `plain` cases have no scaffold (§3.2). `nag` histories have one after every user turn, including turn 1.
- Turn 1's assistant reply is short and follows the general rules in both filler styles.
- Use fixed UUIDs and timestamps (derived from the turn index) so builds are deterministic and diffs stay small.
- The CLAUDE.md context block is the text Claude Code renders CLAUDE.md into: `<system-reminder>`, "As you answer the user's questions, you can use the following context:", `# claudeMd`, the "Codebase and user instructions are shown below…" header, "Contents of /workspace/CLAUDE.md (project instructions, checked into the codebase):", then `rules.md`. It replaces the `instructions` attachment the probe used, which a resumed session reports as removed (§2). It also settles the old open question about whether the model sees the header: the header is now in the text itself.

### 4.2 Filler generation (`gen-filler.sh`, run once)

- Calls `claude -p --model sonnet` (no tools, no user settings or plugins, no session file, run in an empty directory). The first call writes `src/filler/outline.json`, a two or three sentence summary for each of 12 parts. Then one call per part, four at a time, each given its own summary and the previous part's. Parts target ~15k tokens (5 turn pairs), so 12 parts clear `l2` with margin. The outline is what lets parts run in parallel rather than waiting on the previous part's output.
- Shared brief across parts: a fictional TypeScript billing service; realistic user/assistant coding conversation (bugs, reviews, refactors, snippets, design discussion) in Claude's normal reply style.
- Output per part: stored as a JSON array of `{"user": "...", "assistant": "..."}` turns, about 2–5k tokens per turn pair. The model is asked for plain text between `=====USER=====` and `=====ASSISTANT=====` marker lines, and `gen-filler.sh` converts it, because long JSON replies came back with trailing commas or raw newlines in strings. Failed replies are kept in `src/filler/failed/` (gitignored) for diagnosis.
- `STATUS:` is forbidden only at the start of a line, so `const STATUS:` in code is fine. "Status update" isn't banned as a phrase, since it also means updating a row's status.
- Must not contain: status updates, commit messages, ticket IDs like `BIL-123`, the strings `STATUS:` or `[end]`, calendar dates, or anything that addresses or overrides an assistant's instructions. `gen-filler.sh` checks each part against a list of patterns (including the status month-date grader's own pattern) and regenerates failures, up to 3 attempts. Re-running it only fills missing parts.
- Must contain natural style: across the full set, assistant turns should include em dashes, headings and bold often enough for the natural style to be a real drifted history. `gen-filler.sh` prints the counts. If they're low, the brief asks for longer, structured replies.
- Committed gzipped as `src/filler/part-NN.json.gz`. Treat as frozen: every regeneration adds a full copy to git history.
- Expected cost is about $2–5.

### 4.3 Corrected style (`normalise-filler.sh`)

It transforms the assistant turns only, outside fenced code blocks:

- `—` with spaces around it becomes `, `; a bare `—` becomes `, `.
- A line starting with `#`–`######` followed by a space keeps its text and loses the marker.
- `**text**` and `__text__` become `text`.

It doesn't shorten replies, so corrected style still breaks G4: length can't be corrected mechanically. A G4-compliant history would need filler generated under the rule. It's deterministic, run by `build.sh` rather than committed. Afterwards it checks that no G1–G3 grader pattern matches any assistant turn outside code blocks, and fails if one does.

### 4.4 Builder (`build.sh`)

For each case in the matrix (§3.6):

1. Take filler parts until the level's token target is reached (estimate tokens as chars / 4). For `l2c`, apply `normalise-filler.sh`.
2. Write `history.jsonl` (§4.1). Turn 1's user message carries `rules.md` in the CLAUDE.md context block.
3. For `nag` histories, get the reminder text by running `scripts/nag inject` once against a temp fixture: `HOME=<tmp>` with `<tmp>/.claude/CLAUDE.md = rules.md` and a summary written by `scripts/nag write global`, `CLAUDE_PLUGIN_DATA=<tmp>/data`, stdin `{"session_id":"build","cwd":"<tmp>/cwd","hook_event_name":"UserPromptSubmit"}`. Take `.hookSpecificOutput.additionalContext`. Fail the build if it contains a stale or missing note. Use the same text for every turn.
4. Write `case.yaml` (§4.6) with the request as the prompt.
5. Copy `graders/general/` plus the request's grader folder into the case's `graders/`.

Builds must be deterministic: running `build.sh` twice leaves `git status` clean. History files for the same level and filler style differ only in the reminder entries, so git deltas keep the repo small. If the committed case dirs still get too large, gitignore them and run `build.sh` before each eval (and in CI).

### 4.5 Scaffold (`seed.sh`)

The runner docs say the scaffold is "a Bash script in the case directory", so `build.sh` copies `src/seed.sh` into each `nag` case dir (`plain` cases are unseeded, §3.2). The copy resolves the repo the same way, since case dirs and `src/` sit at the same depth. It:

1. Resolves the repo root from `$0` and `scripts/nag` from that.
2. Writes `src/rules.md` to `$HOME/.claude/CLAUDE.md`.
3. Gets the fingerprint from `scripts/nag status global` and pipes `src/summary.md` into `scripts/nag write global --expect <fp>`.
4. Exits non-zero on any failure, so a broken seed fails the run instead of silently testing nothing.

### 4.6 case.yaml

```yaml
schema_version: "1.1"
name: l2-status-nag
runs: 3
context:
  scaffold_script: seed.sh
  history_file: history.jsonl
execution:
  model: claude-opus-5-5
  max_turns: 2
  timeout_seconds: 300
  allowed_tools: []
  prompt: |
    <src/requests/status.md>
```

No tools are needed: the answer is a single reply. The runner accepts an empty `allowed_tools`. Size `timeout_seconds` to the largest history after the pilot.

### 4.7 Report (`report.sh`)

Reads the newest `evals/results/*/aggregate-result.json` (or a path argument). For each level and request it prints:

| level | request | nag on (`nag` case) | nag off (`plain` case) | Δ |

It prints:

- One table for mean score.
- One per rule: the pass rate of each grader, since one rule may drift while others hold.
- A summary of G-rule pass rates across all requests.

Per-run results are read from `cases[].arms.with[]` and `cases[].arms.without[]` (`score`, `error`, and `graders[]` with `name`, `passed`, `scored`), as checked against a real results file. Runs with a non-null `error` are left out and listed at the end. A run that errors before replying still passes every `not_contains` grader (0.56 on a status case), so counting it would skew the means.

## 5. Graders

All regex, so no judge model is needed. Weight 1 each, `target: last_message`. JS regex semantics: without the `m` flag, `^` and `$` anchor to the whole reply.

`TYPES` below stands for `(feat|fix|refactor|perf|chore|docs|test|build|ci)`. `MONTHS` stands for `(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?)`, whole words only, so "mark 3" or "decided 4" don't count as dates.

**General, every case (`graders/general/`)**

| File | Match | Pattern | Rule |
| --- | --- | --- | --- |
| `no-em-dash.md` | not_contains | `—` | G1 |
| `no-headings.md` | not_contains (flags `m`) | `^#{1,6}\s` | G2 |
| `no-bold.md` | not_contains | `\*\*[^*\n]+\*\*\|__[^_\n]+__` | G3 |
| `max-words.md` | not_contains | `^\s*(?:\S+\s+){120}\S` (matches a reply of 121+ words) | G4 |

**Status (`graders/status/`)**

| File | Match | Pattern | Rule |
| --- | --- | --- | --- |
| `status-line.md` | contains | `^\s*STATUS: (green\|amber\|red)\b` | S1 |
| `iso-dates.md` | contains | `(?=[\s\S]*2026-11-14)(?=[\s\S]*2026-12-02)` | S2, and the dates were converted |
| `no-month-dates.md` | not_contains (flags `i`) | `\bMONTHS\b\.?\s+\d{1,2}\b\|\b\d{1,2}(st\|nd\|rd\|th)?\s+MONTHS\b` | S2 |
| `no-numbered-list.md` | not_contains (flags `m`) | `^\s*\d+[.)]\s` | S3 |
| `end-line.md` | contains | `\[end\]\s*$` | S4 |
| `task-done.md` | contains (flags `i`) | lookaheads for `ledger export`, `rate limit`, `beta demo`, `public launch`, `runbook` | outcome |

**Commit (`graders/commit/`)**

| File | Match | Pattern | Rule |
| --- | --- | --- | --- |
| `conventional.md` | contains (flags `m`) | `^TYPES(\([a-z0-9-]+\))?: \S` | C1 |
| `subject-length.md` | not_contains (flags `m`) | `^(?=TYPES[(:]).{51,}$` | C2 |
| `ticket-suffix.md` | contains (flags `m`) | `^TYPES(\([a-z0-9-]+\))?: .*\[BIL-482\]\s*$` | C3 |
| `task-done.md` | contains (flags `i`) | `idempoten` | outcome |

**Question (`graders/question/`)**

| File | Match | Pattern | Checks |
| --- | --- | --- | --- |
| `no-status-line.md` | not_contains (flags `m`) | `^\s*STATUS:` | situational format not applied where it doesn't belong |
| `no-end-line.md` | not_contains | `\[end\]` | same |
| `no-commit-line.md` | not_contains (flags `m`) | `^TYPES(\([a-z0-9-]+\))?: \S` | same |
| `task-done.md` | contains (flags `i`) | lookaheads for `retr(y\|ies)`, `(twice\|double\|duplicate)` and `idempoten` | outcome |

Notes:

- G2 would also match a `#` comment inside a code block in the reply. The requests avoid code (the question says "no code"); check the pilot for false hits.
- C2 and C3 look only at lines that start with a commit type, so an intro line like "Here's the message:" doesn't affect them. If Claude wraps the message in a code fence, the lines still match with the `m` flag.
- `test-graders.mjs` runs every grader against handwritten good and bad replies (a wrapped status, month dates, a numbered list, a fenced commit after an intro, a long subject, a question with status or commit formatting, and more). `scripts/check` runs it. Add a reply there when adding or changing a grader.

## 6. Running

```bash
evals/src/build.sh
# routine: l1 and l2, 36 sessions, as two runs merged by report.sh
claude plugin eval . --case 'l1-*' --ablation none --scaffold --no-publish
claude plugin eval . --case 'l2-*' --ablation none --scaffold --no-publish
evals/src/report.sh evals/results/<l1 run>/aggregate-result.json evals/results/<l2 run>/aggregate-result.json

claude plugin eval . --ablation none --scaffold --no-publish   # full suite: 24 cases, 72 sessions
evals/src/report.sh
```

`--case` takes a simple glob without character classes (`l[12]-*` matches nothing), so the routine run is two runs. `l2-*` doesn't match `l2c-…`. `report.sh` merges any results files it's given by case, a later file winning, which is also how to re-run cases a session limit cut off. `l0` already passes everything (the floor check) and `l2c` waits until `l2` shows a gap.

Pilot first: the routine commands with `--runs 1`. In the pilot, check:

- `aggregate-result.json` → `suite.plugins` lists nag with no `manifest_invalid`, `disabled_by_default` or `will_not_load` problem.
- With `--keep-temp` on one run each of `l1-status-nag` and `l1-status-plain`: the `nag` case has a live `hook_additional_context` entry and the `plain` case doesn't.
- No `⚠ case … cannot pass with the granted tools` notice.
- Read every reply and grade it by hand against the graders. Any disagreement means fixing the grader before the full run.
- Ceiling/floor checks:
  - If `plain` passes everything even at `l2`, the rules aren't drifting and need to be harder.
  - If everything fails at `l0`, the rules or requests are broken.
- Record the pilot's top-level `costUsd`; one full run of the same cases ≈ that × 3. A plan's session limit ends a run partway: those runs error with "You've hit your session limit" and `report.sh` leaves them out. Re-run the missing cases with `--case` after the limit resets.

## 7. Invariants (don't drop these)

- `--ablation none` with `plain` cases unseeded, so the two cells are nag on and nag off (§3.2).
- `runs` ≥ 3.
- At least one negative case. The `question` cases are the negative for the situational rules.
- Every case has an outcome grader (`task-done`), not only rule checks.
- The eval never reads the user's real `~/.claude/nag.md`. It's guaranteed by the sandbox; don't add anything that points outside it.

## 8. Decisions and open questions

Decided:

- **Agent model: Opus 5.5** (`claude-opus-5-5`), the model the user works with day to day, so results reflect real use. Results describe Opus only: models differ in how much they drift and how much a reminder helps. For cheaper iteration on rules and graders, or to compare models, run with `--model claude-sonnet-5-5` (it overrides every case) and keep the reports separate. If an LLM grader is ever added, the judge must differ from the agent model (`--judge-model sonnet`).
- **Runs: 3.** Per-rule pass rates per cell are coarse (0, 33, 67 or 100%), but the G rules are checked on all three requests, which gives more samples. Revisit if the pilot Δ is small and noisy.

Open:

- **A larger level:** a ~400k level was dropped for cost. Add `l3` if the pilot shows Δ still growing at `l2`.
- **Reminder cadence:** real sessions inject on every user prompt. If filler turns are much longer than real prompts, the reminder density is lower than in real use. Note this when reading results.

## 9. Not covered

- Compaction (`SessionStart:compact`).
- Claude Code's own CLAUDE.md file loading (the history supplies the same content in the same place).
- `/nag:refresh` and `/nag:status`.

## 10. Housekeeping

- Done: deleted the probe leftovers `evals/_probe/` and `evals/fixtures/`, and gitignored `evals/results/`.
- Done: added `evals/` to the README layout line under Develop, and the eval scripts to `scripts/check` (shellcheck and `test-graders.mjs`). This isn't a behaviour change, so `spec.md` and `version` stay as they are.
