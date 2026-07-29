#!/usr/bin/env bash
# Example ~/.claude/statusline.sh for claude-pod users.
# ASCII-only statusline. Shows: pod/host · profile · repo · branch · model · ctx · 5h · 7d
#
# Install: save as ~/.claude/statusline.sh (chmod +x), then in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 }
#
# Multiple accounts/profiles (see "Multiple accounts / profiles" in the README): the
# profile segment is derived from CLAUDE_CONFIG_DIR's basename on the host (e.g.
# ~/.claude-tessero-bam -> "tb"), or from a "profile-tag" file placed next to this
# script inside a pod, since CLAUDE_CONFIG_DIR itself isn't forwarded into the
# container -- see "Claude config access" in the README for how that file gets mounted.

input="$(cat)"

# --- helpers ------------------------------------------------------------
bar() {
  # bar <pct 0-100> -> 6-cell ASCII bar like [###---]
  local pct="${1:-0}"
  pct=${pct%.*}
  [ -z "$pct" ] && pct=0
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local cells=6
  local filled=$(( pct * cells / 100 ))
  local empty=$(( cells - filled ))
  local b="["
  local i
  for ((i=0; i<filled; i++)); do b+="#"; done
  for ((i=0; i<empty;  i++)); do b+="-"; done
  b+="]"
  printf '%s' "$b"
}

truncate() {
  # truncate <string> <maxlen> -> string, ellipsized with ~ if too long
  local s="$1" max="$2"
  (( ${#s} > max )) && s="${s:0:$((max-1))}~"
  printf '%s' "$s"
}

color_for() {
  local pct="${1:-0}"; pct=${pct%.*}; [ -z "$pct" ] && pct=0
  if   (( pct < 40 )); then printf '\033[32m'
  elif (( pct < 70 )); then printf '\033[33m'
  elif (( pct < 85 )); then printf '\033[38;5;208m'
  else                      printf '\033[1;31m'; fi
}
RESET=$'\033[0m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'

# profile_tag -> first letter of each hyphen-separated word after "claude-" in
# CLAUDE_CONFIG_DIR's basename (e.g. ~/.claude-tessero-bam -> "tb"); "d" if
# CLAUDE_CONFIG_DIR is unset (default profile).
#
# A "profile-tag" file next to this script wins first if present -- inside a
# claude-pod container CLAUDE_CONFIG_DIR isn't forwarded, so claude-pod
# bind-mounts a profile-specific marker file (~/.claude-<profile>/profile-tag)
# alongside this same shared, symlinked script to identify the profile instead.
profile_tag() {
  local script_dir marker
  script_dir=$(dirname "${BASH_SOURCE[0]}")
  marker="$script_dir/profile-tag"
  if [ -s "$marker" ]; then
    printf '%s' "$(<"$marker")"
    return
  fi
  local dir="${CLAUDE_CONFIG_DIR:-}"
  [ -z "$dir" ] && { printf 'd'; return; }
  local name
  name=$(basename "$dir")
  name="${name#.}"
  name="${name#claude-}"
  if [ -z "$name" ] || [ "$name" = "claude" ]; then
    printf 'd'
    return
  fi
  local IFS='-' word out=""
  local -a words
  read -ra words <<< "$name"
  for word in "${words[@]}"; do
    out+="${word:0:1}"
  done
  printf '%s' "${out,,}"
}

time_left() {
  local ts="$1"
  [ -z "$ts" ] || [ "$ts" = "null" ] && { printf '%s' "?"; return; }
  local target now diff
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    target="$ts"
  elif target=$(date -d "$ts" +%s 2>/dev/null); then :
  elif target=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts%.*}Z" +%s 2>/dev/null); then :
  else printf '%s' "?"; return; fi
  now=$(date +%s)
  diff=$(( target - now ))
  (( diff < 0 )) && { printf 'now'; return; }
  if (( diff >= 86400 )); then
    printf '%dd%02dh' $(( diff / 86400 )) $(( (diff % 86400) / 3600 ))
  else
    printf '%dh%02dm' $(( diff / 3600 )) $(( (diff % 3600) / 60 ))
  fi
}

# Read a numeric field; print "x" if null/missing
field_pct() {
  local val
  val=$(printf '%s' "$input" | jq -r "$1 // \"MISSING\"")
  if [ "$val" = "MISSING" ] || [ "$val" = "null" ]; then
    printf 'x'
  else
    printf '%s' "${val%.*}"
  fi
}

# --- pull fields --------------------------------------------------------
# claude-pod's launcher sets HOME=/home/claude-pod inside the container (see claude-pod script);
# nothing else does, so it doubles as a reliable in-container signal.
if [ "$HOME" = "/home/claude-pod" ]; then
  env_tag="$(printf '\033[36mpod%s' "$RESET")"
else
  env_tag="${DIM}host${RESET}"
fi

cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')
repo=$(truncate "$(basename "${cwd:-?}")" 12)
branch=$(truncate "$(git -C "${cwd:-.}" branch --show-current 2>/dev/null)" 14)

# A linked worktree's git-dir lives under the main repo's .git/worktrees/<name>;
# the main checkout's git-dir and git-common-dir are the same path.
git_dir=$(git -C "${cwd:-.}" rev-parse --git-dir 2>/dev/null)
common_dir=$(git -C "${cwd:-.}" rev-parse --git-common-dir 2>/dev/null)
is_worktree=0
[ -n "$git_dir" ] && [ "$git_dir" != "$common_dir" ] && is_worktree=1

is_dirty=0
[ -n "$git_dir" ] && [ -n "$(git -C "${cwd:-.}" status --porcelain 2>/dev/null)" ] && is_dirty=1
model=$(printf '%s' "$input" | jq -r '.model.display_name // "claude"')
model="${model#claude-}"
model=$(truncate "$model" 10)

ctx=$(field_pct '.context_window.used_percentage')
h5=$(field_pct  '.rate_limits.five_hour.used_percentage')
d7=$(field_pct  '.rate_limits.seven_day.used_percentage')

h5_reset=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at  // ""')
d7_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at  // ""')

# --- render -------------------------------------------------------------
# with_bar=1: label[bar]pct%  |  with_bar=0: label pct%(reset)
render_segment() {
  local label="$1" pct="$2" reset_iso="$3" with_bar="$4"
  if [ "$pct" = "x" ]; then
    printf "%s %sn/a%s" "$label" "$DIM" "$RESET"
    return
  fi
  if [ "$with_bar" = "1" ]; then
    printf "%s%s%s %d%%%s" "$label" "$(color_for "$pct")" "$(bar "$pct")" "$pct" "$RESET"
  else
    printf "%s %s%d%%%s" "$label" "$(color_for "$pct")" "$pct" "$RESET"
    [ -n "$reset_iso" ] && printf "%s(%s)%s" "$DIM" "$(time_left "$reset_iso")" "$RESET"
  fi
}

out="$env_tag ${MAGENTA}$(profile_tag)${RESET} $repo"
[ -n "$branch" ] && out+="${DIM}@${branch}${RESET}"
(( is_dirty )) && out+="$(printf '\033[33m*%s' "$RESET")"
(( is_worktree )) && out+=" ${CYAN}wt${RESET}"
out+=" $model"
out+=" $(render_segment "ctx" "$ctx" "" 1)"
out+=" $(render_segment "5h"  "$h5" "$h5_reset" 0)"
out+=" $(render_segment "7d"  "$d7" "$d7_reset" 0)"

printf '%s\n' "$out"
