#!/usr/bin/env bash
# Writes every eval case dir (evals/<level>-<request>-<history>/) from the sources in evals/src. Deterministic: running
# it twice leaves the output unchanged. See docs/eval-spec.md §4.4.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
EVALS=$(dirname "$SRC")
NAG=$(dirname "$EVALS")/scripts/nag

# Filler token targets per level (tokens estimated as chars / 4). l2c is l2 in corrected style.
L1_TOKENS=50000
L2_TOKENS=150000
LEVELS=${*:-l0 l1 l2 l2c}  # pass levels to build only those, e.g. `build.sh l0`
REQUESTS="status commit question"
HISTORIES="nag plain"

MODEL=claude-opus-5-5
RUNS=3
MAX_TURNS=2
TIMEOUT_SECONDS=300

FIRST_USER="Let's pick up the billing service work."
FIRST_ASSISTANT="Sure. Where do you want to start: invoicing, payments or the ledger?"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The nag reminder as the live hook injects it: run `nag inject` once against a fixture home seeded by seed.sh.
nag_reminder() {
  local reminder
  mkdir -p "$TMP/home" "$TMP/cwd"
  (
    cd "$TMP/cwd"
    export HOME=$TMP/home CLAUDE_PLUGIN_DATA=$TMP/data
    "$SRC/seed.sh" >/dev/null
    jq -n --arg cwd "$TMP/cwd" '{session_id: "build", cwd: $cwd, hook_event_name: "UserPromptSubmit"}' |
      "$NAG" inject | jq -r '.hookSpecificOutput.additionalContext'
  ) >"$TMP/reminder"
  reminder=$(cat "$TMP/reminder")
  case $reminder in
    "nag (global):"*) ;;
    *) echo "build: nag inject gave no global summary: $reminder" >&2; exit 1 ;;
  esac
  case $reminder in
    *"out of date"* | *"no approved summary"*) echo "build: nag reminder has a stale or missing note" >&2; exit 1 ;;
  esac
}

# Filler turns for a level, as a JSON array of {user, assistant}: the shortest prefix of the whole filler sequence that
# reaches the level's token target. Levels are therefore nested.
filler_turns() {
  local target
  case $1 in
    l0) echo '[]'; return ;;
    l1) target=$L1_TOKENS ;;
    l2 | l2c) target=$L2_TOKENS ;;
  esac
  jq -s --argjson target "$target" '
    add | reduce .[] as $turn ({chars: 0, turns: []};
      if .chars / 4 >= $target then . else .chars += ($turn.user + $turn.assistant | length) | .turns += [$turn] end)
    | if .chars / 4 < $target then error("filler has \(.chars / 4) tokens; level needs \($target)") else .turns end' \
    "$TMP"/filler/*.json
}

# history.jsonl from the turns on stdin; with a reminder, every user turn gets a hook_additional_context entry. UUIDs and
# timestamps derive from the turn index. Turn 1's user message carries rules.md in the context block Claude Code renders
# CLAUDE.md into. It isn't an `instructions` attachment: on resume Claude Code re-reads instruction files, finds none in
# the sandbox and tells the model the CLAUDE.md is "no longer present", so the model drops the rules.
write_history() {
  local reminder=$1
  jq -c --rawfile rules "$SRC/rules.md" --arg reminder "$reminder" \
    --arg first_user "$FIRST_USER" --arg first_assistant "$FIRST_ASSISTANT" '
    def uuid($kind; $n): "\($kind)0000000-0000-4000-8000-\($n | tostring | ("000000000000" + .)[-12:])";
    def common($n): {isSidechain: false, userType: "external", entrypoint: "sdk-cli", cwd: "/workspace",
      sessionId: "00000000-0000-4000-8000-000000000000", version: "2.1.296",
      timestamp: (1791795600 + $n * 60 | todate)};
    def claude_md: "<system-reminder>\nAs you answer the user'"'"'s questions, you can use the following context:\n"
      + "# claudeMd\nCodebase and user instructions are shown below. Be sure to adhere to these instructions. "
      + "IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.\n\n"
      + "Contents of /workspace/CLAUDE.md (project instructions, checked into the codebase):\n\n\($rules)"
      + "</system-reminder>";
    [{user: [{type: "text", text: claude_md}, {type: "text", text: $first_user}], assistant: $first_assistant}] + .
    | to_entries | map(.key as $n | .value as $turn |
      [{type: "user", uuid: uuid(1; $n), message: {role: "user", content: $turn.user}},
       if $reminder != "" then {type: "attachment", uuid: uuid(3; $n), attachment: {type: "hook_additional_context",
         content: [$reminder], hookName: "UserPromptSubmit", hookEvent: "UserPromptSubmit",
         toolUseID: "hook-\($n + 1)"}} else empty end,
       {type: "assistant", uuid: uuid(4; $n), message: {role: "assistant", type: "message",
         model: "claude-sonnet-5-5", content: [{type: "text", text: $turn.assistant}]}}]
      | map(. + common($n)))
    | flatten | . as $entries | to_entries
    | map(.value + {parentUuid: (if .key == 0 then null else $entries[.key - 1].uuid end)})[]'
}

# Every case runs with the plugin loaded (`--ablation none`). Only `nag` cases are seeded: a `plain` case's sandbox
# has no CLAUDE.md or summary, so nag injects nothing and the run is the nag-off cell.
write_case() {
  local level=$1 request=$2 history=$3 dir
  dir=$EVALS/$level-$request-$history
  rm -rf "$dir"
  mkdir -p "$dir/graders"
  cp "$TMP/history-$level-$history.jsonl" "$dir/history.jsonl"
  [ "$history" = nag ] && cp "$SRC/seed.sh" "$dir/seed.sh"
  cp "$SRC/graders/general/"*.md "$SRC/graders/$request/"*.md "$dir/graders/"
  {
    printf 'schema_version: "1.1"\nname: %s\nruns: %s\ncontext:\n' "$level-$request-$history" "$RUNS"
    [ "$history" = nag ] && printf '  scaffold_script: seed.sh\n'
    printf '  history_file: history.jsonl\n'
    printf 'execution:\n  model: %s\n  max_turns: %s\n  timeout_seconds: %s\n  allowed_tools: []\n  prompt: |\n' \
      "$MODEL" "$MAX_TURNS" "$TIMEOUT_SECONDS"
    sed 's/^/    /' "$SRC/requests/$request.md"
  } >"$dir/case.yaml"
}

mkdir -p "$TMP/filler"
for part in "$SRC"/filler/part-*.json.gz; do
  [ -f "$part" ] || break
  gunzip -c "$part" >"$TMP/filler/$(basename "$part" .gz)"
done
nag_reminder
for level in $LEVELS; do
  if [ "$level" = l2c ]; then
    filler_turns "$level" | "$SRC/normalise-filler.sh" >"$TMP/turns.json"
  else
    filler_turns "$level" >"$TMP/turns.json"
  fi
  write_history "$(cat "$TMP/reminder")" <"$TMP/turns.json" >"$TMP/history-$level-nag.jsonl"
  write_history "" <"$TMP/turns.json" >"$TMP/history-$level-plain.jsonl"
  for request in $REQUESTS; do
    for history in $HISTORIES; do write_case "$level" "$request" "$history"; done
  done
  printf 'build: %s, %s filler turns\n' "$level" "$(jq length "$TMP/turns.json")"
done
