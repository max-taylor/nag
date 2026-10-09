#!/usr/bin/env bash
# Shared functions for nag: config, source discovery, hashing and summary-file parsing.
# Sourced by scripts/nag. Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

SUMMARY_FORMAT_VERSION=1
DEFAULT_GLOBAL_SUMMARY_PATH="~/.claude/nag.md"
DEFAULT_MAX_CHARS=1500
IMPORT_MAX_DEPTH=4
PLUGIN_NAME="nag"

# --- config -------------------------------------------------------------------------------------------------------

# Loads the plugin options once into NAG_GLOBAL_SUMMARY_PATH, NAG_MAX_CHARS and NAG_INCLUDE_LOCAL: hook env
# (CLAUDE_PLUGIN_OPTION_<KEY>) first, then pluginConfigs in user settings (skills don't get the env), then the defaults.
nag_load_options() {
  local s_path="" s_max="" s_local=""
  if [ -f "$HOME/.claude/settings.json" ]; then
    eval "$(jq -r --arg p "$PLUGIN_NAME@" '
      def opt(k): .[k] | if . == null then "" else tostring end;
      [(.pluginConfigs // {}) | to_entries[] | select(.key | startswith($p)) | .value.options][0] // {}
      | @sh "s_path=\(opt("global_summary_path")) s_max=\(opt("max_chars")) s_local=\(opt("include_local"))"
    ' "$HOME/.claude/settings.json" 2>/dev/null)"
  fi
  NAG_GLOBAL_SUMMARY_PATH=${CLAUDE_PLUGIN_OPTION_GLOBAL_SUMMARY_PATH:-${s_path:-$DEFAULT_GLOBAL_SUMMARY_PATH}}
  NAG_MAX_CHARS=${CLAUDE_PLUGIN_OPTION_MAX_CHARS:-${s_max:-$DEFAULT_MAX_CHARS}}
  NAG_INCLUDE_LOCAL=${CLAUDE_PLUGIN_OPTION_INCLUDE_LOCAL:-${s_local:-false}}
}

nag_expand_home() {
  case $1 in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

nag_resolve() { realpath "$1" 2>/dev/null || printf '%s' "$1"; }

nag_hash_stdin() { shasum -a 256 | cut -d' ' -f1; }

# --- paths --------------------------------------------------------------------------------------------------------

# The repo containing cwd, or cwd itself. Empty when that is $HOME, whose files are the global scope.
nag_project_root() {
  local cwd=${1:-$PWD} root
  root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || root=$cwd
  root=$(nag_resolve "$root")
  [ "$root" = "$(nag_resolve "$HOME")" ] && return 0
  printf '%s' "$root"
}

# How a source is written in the summary file: project-relative, else ~-relative, else absolute. Sets the named
# variable rather than printing, so per-file callers don't fork.
nag_set_display_path() {
  local _path=$2 _root=${3:-}
  if [ -n "$_root" ] && [ "${_path#"$_root"/}" != "$_path" ]; then printf -v "$1" '%s' "${_path#"$_root"/}"
  elif [ "${_path#"$HOME"/}" != "$_path" ]; then printf -v "$1" '~/%s' "${_path#"$HOME"/}"
  else printf -v "$1" '%s' "$_path"; fi
}

nag_display_path() { local display; nag_set_display_path display "$1" "${2:-}"; printf '%s' "$display"; }

nag_summary_path() {
  local scope=$1 root=${2:-}
  if [ "$scope" = global ]; then
    nag_expand_home "$NAG_GLOBAL_SUMMARY_PATH"
  elif [ -n "$root" ]; then
    printf '%s/.claude/nag.md' "$root"
  fi
}

# --- source discovery ---------------------------------------------------------------------------------------------
# Runs on every prompt, so each step handles all files in one process rather than forking per file.

# Lists the files from stdin, then breadth-first the files they @import (outside code spans and fenced blocks), up to
# Claude Code's four hops. Relative imports resolve from the importing file's directory, then from its symlink target's.
nag_expand_imports() {
  local level depth=0 file token candidate next
  level=$(cat)
  while [ -n "$level" ]; do
    printf '%s\n' "$level"
    [ "$depth" -ge "$IMPORT_MAX_DEPTH" ] && break
    next=""
    while IFS=$'\t' read -r file token; do
      case $token in
        "~/"*) candidate="$HOME/${token#\~/}" ;;
        /*) candidate=$token ;;
        *) candidate="${file%/*}/$token"
          [ -f "$candidate" ] || candidate="$(dirname "$(nag_resolve "$file")")/$token" ;;
      esac
      [ -f "$candidate" ] && next="$next$candidate"$'\n'
    done < <(printf '%s\n' "$level" | tr '\n' '\0' | xargs -0 awk '
      FNR == 1 { fenced = 0 }
      /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
      fenced { next }
      {
        gsub(/`[^`]*`/, "")
        n = split($0, words, /[ \t]+/)
        for (i = 1; i <= n; i++) if (words[i] ~ /^@[^@]/) print FILENAME "\t" substr(words[i], 2)
      }')
    level=${next%$'\n'}
    depth=$((depth + 1))
  done
}

# Rule files under a rules directory, minus those with `paths:` frontmatter: they load only for matching files, so they
# don't belong in an always-on summary.
nag_unscoped_rules() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find -L "$dir" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort | tr '\n' '\0' | xargs -0 awk '
    FNR == 1 { if ($0 != "---") { print FILENAME; nextfile } next }
    $0 == "---" { print FILENAME; nextfile }
    /^paths:/ { nextfile }'
}

# The file behind the `outputStyle` setting. A style's name is its frontmatter `name`, else its file name.
nag_output_style_file() {
  local name styles
  name=$(jq -rs 'map(.outputStyle // empty) | last // empty' \
    "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" 2>/dev/null)
  [ -n "$name" ] || return 0
  styles=$(find -L "$HOME/.claude/output-styles" -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort)
  [ -n "$styles" ] || return 0
  printf '%s\n' "$styles" | tr '\n' '\0' | xargs -0 awk '
    FNR == 1 { if (file) print file "\t" name; file = FILENAME; name = FILENAME
      sub(/^.*\//, "", name); sub(/\.md$/, "", name); infm = ($0 == "---"); next }
    infm && $0 == "---" { infm = 0 }
    infm && /^name:/ { name = $0; sub(/^name:[ \t]*/, "", name); gsub(/^["\047]|["\047]$/, "", name) }
    END { if (file) print file "\t" name }' | awk -F '\t' -v want="$name" '$2 == want { print $1; exit }'
}

nag_global_candidates() {
  {
    [ -f "$HOME/.claude/CLAUDE.md" ] && echo "$HOME/.claude/CLAUDE.md"
    nag_unscoped_rules "$HOME/.claude/rules"
  } | nag_expand_imports
  nag_output_style_file
}

# Mirrors Claude Code's default: AGENTS.md is read only when the project has no CLAUDE.md of any kind.
nag_project_candidates() {
  local root=$1 file
  {
    for file in CLAUDE.md .claude/CLAUDE.md; do
      [ -f "$root/$file" ] && echo "$root/$file"
    done
    [ "$NAG_INCLUDE_LOCAL" = true ] && [ -f "$root/CLAUDE.local.md" ] && echo "$root/CLAUDE.local.md"
    if [ ! -f "$root/CLAUDE.md" ] && [ ! -f "$root/.claude/CLAUDE.md" ] && [ ! -f "$root/CLAUDE.local.md" ]; then
      for file in AGENTS.md .claude/AGENTS.md; do
        [ -f "$root/$file" ] && echo "$root/$file"
      done
    fi
    nag_unscoped_rules "$root/.claude/rules"
  } | nag_expand_imports
}

# Turns candidate paths into source rows "<path>\t<resolved path>\t<display path>", sorted by display path. A file
# reached twice, or already in `exclude` (resolved paths), is listed once.
nag_tabulate() {
  local candidates=$1 root=$2 exclude=$3 seen path resolved display rows=""
  [ -n "$candidates" ] || return 0
  seen=$'\n'"$exclude"$'\n'
  while IFS=$'\t' read -r path resolved; do
    case $seen in *$'\n'"$resolved"$'\n'*) continue ;; esac
    seen="$seen$resolved"$'\n'
    nag_set_display_path display "$path" "$root"
    rows="$rows$path"$'\t'"$resolved"$'\t'"$display"$'\n'
  done < <(paste <(printf '%s\n' "$candidates") <(printf '%s\n' "$candidates" | tr '\n' '\0' | xargs -0 realpath))
  printf '%s' "$rows" | LC_ALL=C sort -t $'\t' -k3,3
}

# Discovers both scopes' sources in one pass, into NAG_SOURCES_GLOBAL and NAG_SOURCES_PROJECT. Call it in the current
# shell, not in $(...). Project drops files that are already global, as when a dotfiles repo holds the global rules.
nag_discover() {
  local root=$1
  NAG_SOURCES_GLOBAL=$(nag_tabulate "$(nag_global_candidates)" "" "")
  NAG_SOURCES_PROJECT=""
  [ -n "$root" ] && NAG_SOURCES_PROJECT=$(nag_tabulate "$(nag_project_candidates "$root")" "$root" \
    "$(printf '%s\n' "$NAG_SOURCES_GLOBAL" | cut -f2)")
  return 0
}

nag_sources() { if [ "$1" = global ]; then printf '%s' "$NAG_SOURCES_GLOBAL"; else printf '%s' "$NAG_SOURCES_PROJECT"; fi; }

# "<sha256> <display path>" per source of a scope: what the summary file records and staleness is checked against.
nag_manifest() {
  local sources
  sources=$(nag_sources "$1")
  [ -n "$sources" ] || return 0
  paste -d ' ' \
    <(printf '%s\n' "$sources" | cut -f1 | tr '\n' '\0' | xargs -0 shasum -a 256 | cut -d' ' -f1) \
    <(printf '%s\n' "$sources" | cut -f3) | LC_ALL=C sort -k2
}

# --- summary file -------------------------------------------------------------------------------------------------

nag_stored_manifest() {
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^  - path: / { path = substr($0, 11); gsub(/^"|"$/, "", path) }
    /^    sha256: / { print substr($0, 13) " " path }
  ' "$1" | LC_ALL=C sort -k2
}

nag_summary_body() {
  awk 'NR == 1 && $0 == "---" { infm = 1; next } infm && $0 == "---" { infm = 0; started = 0; next } infm { next }
    !started && /^[ \t]*$/ { next } { started = 1; print }' "$1"
}

nag_write_summary() {
  local file=$1 scope=$2 manifest=$3 body=$4 tmp hash display
  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.$$"
  {
    printf -- '---\nnag: %s\nscope: %s\napproved: %s\nsources:\n' \
      "$SUMMARY_FORMAT_VERSION" "$scope" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$manifest" | while read -r hash display; do
      [ -n "$hash" ] && printf '  - path: "%s"\n    sha256: %s\n' "$display" "$hash"
    done
    printf -- '---\n\n%s\n' "$body"
  } >"$tmp" && mv "$tmp" "$file"
}

# Lines "changed|added|removed <display path>" between the stored and current manifests.
nag_manifest_diff() {
  local stored=$1 current=$2
  awk 'NR == FNR { if ($0 != "") { split($0, f, " "); old[substr($0, length(f[1]) + 2)] = f[1] }; next }
    $0 != "" { split($0, f, " "); p = substr($0, length(f[1]) + 2); seen[p] = 1
      if (!(p in old)) print "added " p; else if (old[p] != f[1]) print "changed " p }
    END { for (p in old) if (!(p in seen)) print "removed " p }' \
    <(printf '%s\n' "$stored") <(printf '%s\n' "$current") | LC_ALL=C sort -k2
}

# Re-hashes only the sources a summary already lists, in one call: the cheap staleness check for prompts after the
# first. Catches edits and removals; added files are caught by the full discovery on the next session or compaction.
nag_rehash_manifest() {
  local stored=$1 root=$2 hash display path paths="" displays=""
  while read -r hash display; do
    case $display in "~/"*) path="$HOME/${display#\~/}" ;; /*) path=$display ;; *) path="$root/$display" ;; esac
    [ -f "$path" ] || continue
    paths="$paths$path"$'\n'
    displays="$displays$display"$'\n'
  done <<<"$stored"
  [ -n "$paths" ] || return 0
  paste -d ' ' <(printf '%s' "$paths" | tr '\n' '\0' | xargs -0 shasum -a 256 | cut -d' ' -f1) \
    <(printf '%s' "$displays") | LC_ALL=C sort -k2
}

# fresh | stale | missing (sources but no summary) | none (neither)
nag_state() {
  local summary=$1 current=$2 stored=$3
  if [ -f "$summary" ]; then
    [ "$stored" = "$current" ] && echo fresh || echo stale
  elif [ -n "$current" ]; then
    echo missing
  else
    echo none
  fi
}
