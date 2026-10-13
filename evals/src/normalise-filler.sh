#!/usr/bin/env bash
# Turns natural-style filler into corrected style: removes em dashes, heading markers and bold from the assistant turns,
# outside fenced code blocks. Reads a JSON array of {user, assistant} turns on stdin and writes it to stdout. Fails if a
# general-rule grader pattern (graders/general/) still matches an assistant line outside a code block.
set -euo pipefail

SRC=$(dirname "$0")
# shellcheck source=lib.sh
source "$SRC/lib.sh"
# Each grader's pattern is its body, after the frontmatter. The general patterns are all line-local, so they're checked
# line by line, which also sidesteps the difference between JS and jq multiline semantics.
patterns=$(for file in "$SRC"/graders/general/*.md; do grader_pattern "$file"; done | jq -R . | jq -s .)

jq --argjson patterns "$patterns" '
  def prose_lines: reduce (split("\n")[]) as $line ({fenced: false, lines: []};
    if ($line | test("^\\s*(```|~~~)")) then .fenced |= not | .lines += [{text: $line, prose: false}]
    else .lines += [{text: $line, prose: (.fenced | not)}] end) | .lines;
  def correct: gsub("\\s*—\\s*"; ", ") | sub("^#{1,6}\\s+"; "") | gsub("\\*\\*(?<t>[^*\n]+)\\*\\*"; .t)
    | gsub("__(?<t>[^_\n]+)__"; .t);
  map(.assistant |= ([prose_lines[] | if .prose then .text | correct else .text end] | join("\n")))
  | (map(.assistant | prose_lines[] | select(.prose) | .text as $text | $patterns[] | select(. as $p | $text | test($p))
      | "\(.): \($text)") | first) as $hit
  | if $hit then error("normalise-filler: a general-rule pattern still matches: \($hit)") else . end'
