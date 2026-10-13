#!/usr/bin/env bash
# One-off generator for the natural-style filler conversation (docs/eval-spec.md §4.2). Writes filler/outline.json (one
# summary per part), then filler/part-NN.json.gz, each a JSON array of {user, assistant} turns continuing from the
# previous part's summary. Existing files are kept, so a re-run only fills gaps. Parts are frozen once committed.
#
#   gen-filler.sh [parts]    default 12 parts, about 15k tokens each
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "$SRC/lib.sh"
OUT=$SRC/filler
PARTS=${1:-12}
TURNS_PER_PART=5
MODEL=sonnet
ATTEMPTS=3
CONCURRENCY=4

# Patterns no filler turn may contain: the situational formats, ticket IDs, dates and anything about instructions.
# [pattern, flags] in jq (Oniguruma) syntax. The month-name date pattern is the status grader's own.
FORBIDDEN=$(jq -n --arg months "$(grader_pattern "$SRC/graders/status/no-month-dates.md")" '[
  ["^\\s*STATUS:", ""], ["\\[end\\]", ""], ["commit message|git commit", "i"],
  ["\\b(?!SHA|UTF|ISO|RFC|AES)[A-Z]{2,5}-\\d+\\b", ""],
  ["^\\s*(feat|fix|refactor|perf|chore|docs|test|build|ci)(\\([a-z0-9-]+\\))?: ", ""],
  ["\\b20\\d\\d-[01]\\d-[0-3]\\d\\b", ""], [$months, "i"],
  ["CLAUDE\\.md|system prompt|system-reminder|your instructions|ignore (all |any )?(previous|prior)", "i"]
]')

BRIEF="You are generating synthetic test data: a realistic transcript of one long working session between a software
engineer (the user) and an AI coding assistant (the assistant). The project is a fictional TypeScript billing service:
invoicing, payments, a customer ledger, webhooks, a job queue and Postgres. The session covers bugs, code reviews,
refactors, design discussion and code snippets.

Write the assistant exactly as a modern AI coding assistant usually replies: long, structured answers with markdown
headings, bold key terms, em dashes (—) in prose, bullet lists and fenced TypeScript code blocks. User messages are
short to medium, written like a busy engineer.

Never include: status updates or progress reports, commit messages or git commands, ticket or issue IDs (like
ABC-123), calendar dates of any kind, or any mention of the assistant's instructions, system prompt or configuration."

FAILED=$OUT/failed  # gitignored: the raw output of replies that failed a check
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Runs one prompt through claude -p with no tools, user settings, plugins or session file, and prints the reply text.
# The full claude -p output is kept in $FAILED/last-<pid>.json for diagnosing a bad reply. Runs in an empty directory
# so no project config applies.
ask() {
  local raw=$FAILED/last-$$.json
  (cd "$TMP" && CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 claude -p --model "$MODEL" --output-format json --tools "" \
    --setting-sources project --no-session-persistence "$1") >"$raw"
  jq -r '.result // empty' "$raw"
}

# Parts are requested as plain text between USER_MARK and ASSISTANT_MARK lines, not JSON: long JSON replies often
# carried trailing commas or raw newlines inside strings. This turns that text into a JSON array of {user, assistant}.
USER_MARK="=====USER====="
ASSISTANT_MARK="=====ASSISTANT====="
parse_turns() {
  jq -Rs --arg u "$USER_MARK" --arg a "$ASSISTANT_MARK" '
    [scan("(?:^|\n)\($u)\n([\\s\\S]*?)\n\($a)\n([\\s\\S]*?)(?=\n\($u)\n|\\z)")
      | {user: (.[0] | sub("\\s+$"; "")), assistant: (.[1] | sub("\\s+$"; ""))}]'
}

write_outline() {
  [ -f "$OUT/outline.json" ] && return
  local outline
  outline=$(ask "$BRIEF

Plan the session as $PARTS consecutive parts of $TURNS_PER_PART exchanges each. Output only a JSON array of $PARTS
strings, each a two or three sentence summary of what that part covers, so later parts build on earlier ones.")
  outline=$(printf '%s' "$outline" | sed '/^```/d')
  printf '%s' "$outline" | jq -e --argjson n "$PARTS" 'type == "array" and length == $n' >/dev/null ||
    { echo "gen-filler: bad outline" >&2; exit 1; }
  printf '%s' "$outline" | jq . >"$OUT/outline.json"
}

# Prints the first forbidden pattern found in a part's turns, or nothing.
forbidden_hit() {
  jq -r --argjson forbidden "$FORBIDDEN" '
    [.[] | .user, .assistant] as $texts | first($forbidden[] as [$p, $flags] | $texts[] | select(test($p; $flags)) | $p) // empty'
}

# Keeps the rejected reply's raw output for diagnosis and logs why it was rejected.
reject() {
  local n=$1 attempt=$2 reason=$3
  mv "$FAILED/last-$$.json" "$FAILED/part-$n-attempt-$attempt.json"
  echo "gen-filler: part $n attempt $attempt: $reason (see filler/failed/part-$n-attempt-$attempt.json)" >&2
}

gen_part() {
  local n=$1 file attempt part previous="This is the start of the session." hit
  file=$OUT/$(printf 'part-%02d.json.gz' "$n")
  [ -f "$file" ] && return
  [ "$n" -gt 1 ] && previous="The previous part covered: $(jq -r --argjson i $((n - 2)) '.[$i]' "$OUT/outline.json")"
  for attempt in $(seq "$ATTEMPTS"); do
    part=$(ask "$BRIEF

This is part $n of $PARTS. $previous
This part covers: $(jq -r --argjson i $((n - 1)) '.[$i]' "$OUT/outline.json")

Write exactly $TURNS_PER_PART exchanges. Each assistant reply is 1,500 to 2,500 words. Output only the exchanges, in
this plain-text format with nothing before or after, each marker on its own line:

$USER_MARK
<the user's message>
$ASSISTANT_MARK
<the assistant's reply>
$USER_MARK
...") || part=""
    part=$(printf '%s' "$part" | parse_turns)
    if ! printf '%s' "$part" | jq -e --argjson n "$TURNS_PER_PART" \
      'type == "array" and length == $n and all(.[]; (.user | type) == "string" and (.assistant | type) == "string")' \
      >/dev/null 2>&1; then
      reject "$n" "$attempt" "reply doesn't hold $TURNS_PER_PART turns"
      continue
    fi
    hit=$(printf '%s' "$part" | forbidden_hit)
    if [ -n "$hit" ]; then
      reject "$n" "$attempt" "contains forbidden pattern $hit"
      continue
    fi
    rm -f "$FAILED/last-$$.json"
    printf '%s' "$part" | jq -c . | gzip -n -9 >"$file"
    echo "gen-filler: wrote $(basename "$file")"
    return
  done
  echo "gen-filler: part $n failed after $ATTEMPTS attempts" >&2
  return 1
}

# Style counts over every assistant turn, outside code fences: the natural style must actually break the general rules.
print_style_counts() {
  gunzip -c "$OUT"/part-*.json.gz | jq -s -r '
    [add[] | .assistant | split("\n") | foreach .[] as $line ({fenced: false};
      if ($line | test("^\\s*(```|~~~)")) then .fenced |= not | .line = null else .line = $line end;
      select(.fenced | not) | .line // empty)] as $lines
    | "tokens (chars / 4): \([add[] | .user + .assistant | length] | add / 4 | floor)",
      "em dashes: \([$lines[] | [match("—"; "g")] | length] | add)",
      "heading lines: \([$lines[] | select(test("^#{1,6}\\s"))] | length)",
      "bold spans: \([$lines[] | [match("\\*\\*[^*]+\\*\\*|__[^_]+__"; "g")] | length] | add)"'
}

mkdir -p "$FAILED"
if [ "${GEN_FILLER_PART:-}" ]; then gen_part "$GEN_FILLER_PART"; exit; fi
write_outline
seq "$PARTS" | xargs -P "$CONCURRENCY" -I{} env GEN_FILLER_PART={} "$0" "$PARTS"
print_style_counts
