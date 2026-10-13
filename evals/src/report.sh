#!/usr/bin/env bash
# Prints the headline tables for an eval run (docs/eval-spec.md §3.2, §4.7) from aggregate-result.json: the newest under
# evals/results/ unless paths are given. Several files are merged by case, a later file winning, so a suite run in parts
# (e.g. `--case 'l1-*'` then `--case 'l2-*'`) reports as one. Every case runs with the plugin loaded (`--ablation none`), so each case pair
# gives two cells: nag on (`nag` history, seeded) and nag off (`plain` history, unseeded, so nag injects nothing).
# Runs without the plugin, from an older two-arm run, are ignored.
#
# Runs that ended with an error are left out (an empty reply passes every not_contains grader) and counted below.
set -euo pipefail

EVALS=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || set -- "$(printf '%s\n' "$EVALS"/results/*/aggregate-result.json | sort | tail -1)"
for result in "$@"; do
  [ -f "$result" ] || { echo "report: no aggregate-result.json at '$result'; pass its path" >&2; exit 1; }
done

printf 'Results: %s\n' "$@"
jq -r '
  def mean: if length == 0 then null else add / length end;
  def score: if . == null then "-" else . * 100 | round / 100 | tostring end;
  def pct: if . == null then "-" else "\(. * 100 | round)%" end;
  def signed: if . == null then "-" elif . > 0 then "+\(score)" else score end;
  def table($head): ($head | "| \(join(" | ")) |"), ($head | "|\(map(" --- ") | join("|"))|"), (.[] | "| \(join(" | ")) |");
  def order($list): . as $v | $list | index($v) // 99;
  def columns: ["nag on", "nag off"];

  [.cases[] | (.name | capture("^(?<level>[^-]+)-(?<request>[^-]+)-(?<history>nag|plain)$")) as $key
    | .arms.with[] | $key + {score, error, graders: [.graders[] | select(.scored != false) | {name, passed}]}] as $runs
  | ($runs | map(select(.error == null))) as $ok
  | ([$ok[] | {level, request}] | unique
      | sort_by((.level | order(["l0", "l1", "l2", "l2c"])), (.request | order(["status", "commit", "question"])))) as $rows
  | def cell($row; $history): [$ok[] | select(.level == $row.level and .request == $row.request and .history == $history)];
    def rate($grader): [.[].graders[] | select(.name == $grader) | if .passed then 1 else 0 end] | mean;

  "\nMean score (Δ = nag on − nag off)\n",
  ([$rows[] | . as $row | ([cell($row; "nag", "plain") | map(.score) | mean]) as [$on, $off]
    | [$row.level, $row.request, ($on | score), ($off | score),
       (if $on == null or $off == null then null else $on - $off end | signed)]]
    | table(["level", "request"] + columns + ["Δ"])),

  ([$ok[].graders[].name] | unique[] as $grader
    | "\nPass rate: \($grader)\n",
      ([$rows[] | . as $row | [cell($row; "nag", "plain") | rate($grader)]
        | select(any(. != null)) | [$row.level, $row.request] + map(pct)]
        | table(["level", "request"] + columns))),

  "\nGeneral rules across all requests\n",
  ([["l0", "l1", "l2", "l2c"][] as $level | ["no-em-dash", "no-headings", "no-bold", "max-words"][] as $grader
    | [$ok[] | select(.level == $level)] as $level_runs | select($level_runs | length > 0)
    | [$level, $grader] + [("nag", "plain") as $h | $level_runs | map(select(.history == $h)) | rate($grader) | pct]]
    | table(["level", "rule"] + columns)),

  "\nRuns: \($runs | length), errored and left out: \($runs | map(select(.error != null)) | length)",
  ($runs[] | select(.error != null) | "  \(.level)-\(.request)-\(.history): \(.error | .[0:160])")
' <(jq -s '{cases: (map(.cases) | add | reverse | unique_by(.name))}' "$@")
