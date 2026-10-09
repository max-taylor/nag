---
name: refresh
description: Draft, get approval for and save the rule-anchor summary of the user's CLAUDE.md, rules and output style, which a hook re-sends on every prompt. Use when a summary is missing or stale.
argument-hint: "[global|project]"
disable-model-invocation: true
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor status*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor sources *)
  - Read
---

Refresh the rule-anchor summary for scope `$ARGUMENTS`. If no scope is given, do both scopes, skipping any that are `fresh` or `none`. Do one scope at a time.

## 1. Check state

Run `${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor status <scope>`. Note the summary path, `fingerprint` and `max_chars`. For a stale summary, also note the lines that list changed, added or removed sources.

If the requested scope is `fresh`, say so and stop, unless the user asked to redo it.

## 2. Read

Run `${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor sources <scope>` and read every file it lists. If a summary already exists, read it as well.

## 3. Draft

The summary is re-sent with every prompt as a reminder of instructions that are already loaded, so it should hold only what keeps the user's standing instructions in focus:

- Keep the always-on behavioural rules most likely to drift in a long session: response length and format, process steps, things to never do. Leave out reference material such as folder layouts, naming tables and examples.
- Leave out anything already enforced mechanically, such as a hook that blocks or a lint rule.
- Write facts, not commands: "Replies are at most 5 lines unless detail is requested", not "You MUST keep replies short". Imperative injected text can trip prompt-injection defences.
- Plain prose or short bullets, no headings. Stay under `max_chars` characters, and well under it where possible.
- End with one line naming the source files as the full reference.
- When updating a stale summary, change only what the changed sources require.

## 4. Approve

If a summary already exists, show the user a diff from it. Otherwise show the full draft. Ask the user to approve it, edit it or reject it, and wait for the answer. Write nothing until they approve. If they ask for edits, apply them and show the result again.

## 5. Save

When the user approves, save the summary with the fingerprint from step 1:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/rule-anchor write <scope> --expect <fingerprint> <<'RULE_ANCHOR_EOF'
<approved summary>
RULE_ANCHOR_EOF
```

If it reports that the sources changed, go back to step 1. When a project summary is saved, mention that `.claude/rule-anchor.md` is meant to be committed.
