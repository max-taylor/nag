#!/usr/bin/env bash
# Runs the nag CLI against fixture home and project directories. No dependencies beyond jq and shasum.
set -uo pipefail

CLI="$(cd "$(dirname "$0")/.." && pwd)/scripts/nag"
PASS=0
FAIL=0

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

contains() {
  local name=$1 needle=$2 haystack=$3
  case $haystack in *"$needle"*) PASS=$((PASS + 1)) ;; *)
    FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$name" "$needle" "$haystack" ;; esac
}

lacks() {
  local name=$1 needle=$2 haystack=$3
  case $haystack in *"$needle"*)
    FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n' "$name" "$needle" ;; *) PASS=$((PASS + 1)) ;; esac
}

# Fresh fixture: a home with CLAUDE.md, rules (one path-scoped), an output style and an import; a git project.
setup() {
  ROOT=$(realpath "$(mktemp -d)")
  export HOME="$ROOT/home"
  export CLAUDE_PLUGIN_DATA="$ROOT/data"
  unset CLAUDE_PLUGIN_OPTION_GLOBAL_SUMMARY_PATH CLAUDE_PLUGIN_OPTION_MAX_CHARS CLAUDE_PLUGIN_OPTION_INCLUDE_LOCAL
  mkdir -p "$HOME/.claude/rules/sub" "$ROOT/dotfiles/output-styles" "$ROOT/proj/.claude/rules"
  ln -s "$ROOT/dotfiles/output-styles" "$HOME/.claude/output-styles"
  printf 'Global rules. See @~/extra.md and `@ignored.md`.\n' >"$ROOT/dotfiles/CLAUDE.md"
  ln -s "$ROOT/dotfiles/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  printf 'Extra imported rule.\n' >"$HOME/extra.md"
  printf 'Search before writing.\n' >"$HOME/.claude/rules/engineering.md"
  printf 'Nested rule.\n' >"$HOME/.claude/rules/sub/nested.md"
  printf -- '---\npaths: "**/*.tsx"\n---\nReact only.\n' >"$HOME/.claude/rules/react.md"
  printf -- '---\nname: terse\n---\nBe brief.\n' >"$HOME/.claude/output-styles/terse-style.md"
  printf -- '---\nname: other\n---\nOther.\n' >"$HOME/.claude/output-styles/other.md"
  printf '{"outputStyle":"terse"}\n' >"$HOME/.claude/settings.local.json"
  git -C "$ROOT/proj" init -q
  printf 'Project rules.\n' >"$ROOT/proj/CLAUDE.md"
  printf 'Project rule file.\n' >"$ROOT/proj/.claude/rules/api.md"
  printf 'Agents file.\n' >"$ROOT/proj/AGENTS.md"
  printf 'Local notes.\n' >"$ROOT/proj/CLAUDE.local.md"
  cd "$ROOT/proj" || exit 1
}

teardown() { cd / && rm -rf "$ROOT"; }

inject() {
  jq -n --arg event "${2:-UserPromptSubmit}" --arg session "${1:-s1}" --arg cwd "$ROOT/proj" \
    '{hook_event_name: $event, session_id: $session, cwd: $cwd, source: "compact"}' | "$CLI" inject |
    jq -r '.hookSpecificOutput.additionalContext // empty'
}

state_of() { "$CLI" status "$1" | head -1 | sed 's/.*: //'; }

fingerprint_of() { "$CLI" status "$1" | awk '/fingerprint:/ { print $2 }'; }

sources_of() { "$CLI" status "$1" | sed -n 's/^  source: //p'; }

# --- sources ------------------------------------------------------------------------------------------------------

setup
check "global sources: CLAUDE.md, import, unscoped rules (recursive), active output style" \
  "$HOME/.claude/CLAUDE.md
$HOME/.claude/output-styles/terse-style.md
$HOME/.claude/rules/engineering.md
$HOME/.claude/rules/sub/nested.md
$HOME/extra.md" "$(sources_of global)"
check "project sources: CLAUDE.md wins over AGENTS.md, local excluded by default" \
  "$ROOT/proj/.claude/rules/api.md
$ROOT/proj/CLAUDE.md" "$(sources_of project)"
CLAUDE_PLUGIN_OPTION_INCLUDE_LOCAL=true
export CLAUDE_PLUGIN_OPTION_INCLUDE_LOCAL
contains "include_local adds CLAUDE.local.md" "CLAUDE.local.md" "$(sources_of project)"
unset CLAUDE_PLUGIN_OPTION_INCLUDE_LOCAL
rm "$ROOT/proj/CLAUDE.md" "$ROOT/proj/CLAUDE.local.md"
contains "AGENTS.md used when there is no CLAUDE.md" "$ROOT/proj/AGENTS.md" "$(sources_of project)"
teardown

setup
# A dotfiles-style repo whose rules are also the global rules: shared files belong to global only.
ln -s "$HOME/.claude/rules/engineering.md" "$ROOT/proj/.claude/rules/engineering.md"
lacks "project drops sources that are already global" "engineering.md" "$(sources_of project)"
cd "$HOME" || exit 1
check "no project scope when the working directory is \$HOME" "" "$(sources_of project)"
teardown

# --- write and status ---------------------------------------------------------------------------------------------

setup
check "missing before any summary" "missing" "$(state_of global)"
printf 'Replies are short.\n' | "$CLI" write global >/dev/null
check "fresh after write" "fresh" "$(state_of global)"
contains "summary records hashed sources" "path: \"~/.claude/rules/engineering.md\"" "$(cat "$HOME/.claude/nag.md")"

printf 'Changed.\n' >>"$HOME/.claude/rules/engineering.md"
check "stale after a source edit" "stale" "$(state_of global)"
contains "status names the changed source" "changed ~/.claude/rules/engineering.md" "$("$CLI" status global)"

printf 'Replies are short.\n' | "$CLI" write global >/dev/null
printf 'New rule.\n' >"$HOME/.claude/rules/new.md"
contains "added rule is reported" "added ~/.claude/rules/new.md" "$("$CLI" status global)"
rm "$HOME/.claude/rules/new.md" "$HOME/.claude/rules/sub/nested.md"
contains "removed rule is reported" "removed ~/.claude/rules/sub/nested.md" "$("$CLI" status global)"

printf 'Changed.\n' >>"$ROOT/dotfiles/CLAUDE.md"
contains "edit through a symlink is detected" "changed ~/.claude/CLAUDE.md" "$("$CLI" status global)"

printf -- '---\npaths: "**/*.ts"\n---\nTS only.\n' >"$HOME/.claude/rules/ts.md"
lacks "path-scoped rule never becomes a source" "ts.md" "$("$CLI" status global)"
teardown

setup
fp=$(fingerprint_of global)
printf 'Changed.\n' >>"$HOME/.claude/rules/engineering.md"
printf 'Body.\n' | "$CLI" write global --expect "$fp" 2>/dev/null
check "write refuses when sources changed after drafting" "1" "$?"
printf 'Body.\n' | "$CLI" write global --expect "$(fingerprint_of global)" >/dev/null
check "write accepts a current fingerprint" "0" "$?"

CLAUDE_PLUGIN_OPTION_MAX_CHARS=10
export CLAUDE_PLUGIN_OPTION_MAX_CHARS
printf 'This summary is far too long.\n' | "$CLI" write global 2>/dev/null
check "write enforces max_chars" "1" "$?"
unset CLAUDE_PLUGIN_OPTION_MAX_CHARS

printf '  \n' | "$CLI" write global 2>/dev/null
check "write refuses an empty body" "1" "$?"

CLAUDE_PLUGIN_OPTION_GLOBAL_SUMMARY_PATH="~/dotfiles-summary.md"
export CLAUDE_PLUGIN_OPTION_GLOBAL_SUMMARY_PATH
printf 'Body.\n' | "$CLI" write global >/dev/null
check "global_summary_path is honoured" "yes" "$([ -f "$HOME/dotfiles-summary.md" ] && echo yes)"
unset CLAUDE_PLUGIN_OPTION_GLOBAL_SUMMARY_PATH

printf '{"pluginConfigs":{"nag@local":{"options":{"max_chars":7}}}}\n' >"$HOME/.claude/settings.json"
contains "options fall back to pluginConfigs in user settings" "max_chars: 7" "$("$CLI" status)"
teardown

# --- inject -------------------------------------------------------------------------------------------------------

setup
first=$(inject s1)
contains "missing note on the first prompt" "global instructions have no approved summary" "$first"
check "missing note only once per session" "" "$(inject s1)"
lacks "no missing note for project scope, which is opt-in" "project instructions" "$first"

printf 'GLOBAL BODY\n' | "$CLI" write global >/dev/null
printf 'PROJECT BODY\n' | "$CLI" write project >/dev/null
out=$(inject s2)
contains "fresh global body injected" "GLOBAL BODY" "$out"
contains "fresh project body injected" "PROJECT BODY" "$out"
check "global comes before project" "GLOBAL BODY" "$(printf '%s\n' "$out" | grep -m1 -E 'GLOBAL BODY|PROJECT BODY')"
contains "body injected on every prompt" "GLOBAL BODY" "$(inject s2)"
lacks "frontmatter is not injected" "sha256" "$out"

printf 'Changed.\n' >>"$HOME/.claude/rules/engineering.md"
out=$(inject s3)
contains "stale summary still injected" "GLOBAL BODY" "$out"
contains "stale note names the change" "changed ~/.claude/rules/engineering.md" "$out"
lacks "stale note only once per session" "out of date" "$(inject s3)"
printf 'Brand new.\n' >"$HOME/.claude/rules/later.md"
lacks "later prompts skip full discovery" "later.md" "$(inject s3)"
contains "compaction runs full discovery" "added ~/.claude/rules/later.md" "$(inject s3 SessionStart)"
rm "$HOME/.claude/rules/later.md"
contains "stale note repeats after compaction" "out of date" "$(inject s3 SessionStart)"

check "inject emits valid JSON for the event" "SessionStart" \
  "$(jq -n --arg cwd "$ROOT/proj" '{hook_event_name: "SessionStart", session_id: "s5", cwd: $cwd}' |
    "$CLI" inject | jq -r '.hookSpecificOutput.hookEventName')"
check "inject exits 0 on garbage input" "0" "$(echo 'not json' | "$CLI" inject >/dev/null; echo $?)"
teardown

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
