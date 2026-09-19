#!/usr/bin/env bash
# Teamlead status line segment.
#
# A plugin cannot install a MAIN status line — only the user's settings.json can,
# so this is opt-in and composes rather than replaces. It prints one segment and
# nothing else; wrap it if you already have a status line (most people do).
#
# Silent unless teamlead is active for the project, so it costs nothing elsewhere.
set -uo pipefail
in=$(cat 2>/dev/null)
proj=$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
[ -n "$proj" ] || proj=$PWD

# Resolve a worktree back to the main checkout so a worker's pane reads the same.
# Best-effort only: teamlead supports non-git projects, so a git failure must fall
# through to the plain cwd rather than silence the segment.
root="$proj"
if common=$(git -C "$proj" rev-parse --git-common-dir 2>/dev/null); then
  case "$common" in /*) ;; *) common="$proj/$common" ;; esac
  r=$(cd "$(dirname "$common")" 2>/dev/null && pwd) && root="$r"
fi

[ -f "$root/.claude/teamlead/.state/active" ] || exit 0

pr=$(cat "$root/.claude/teamlead/.state/plugin-root" 2>/dev/null)
[ -n "$pr" ] && [ -f "$pr/scripts/board.py" ] || { printf '⚑ teamlead'; exit 0; }

read -r open out < <(python3 "$pr/scripts/board.py" status --project "$root" 2>/dev/null \
  | awk 'NR==1{gsub(/[^0-9 ]/," ");print $1" "$2}') || true
printf '⚑ teamlead %s open · %s out' "${open:-0}" "${out:-0}"
