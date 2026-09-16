#!/usr/bin/env bash
# Emit the project state block. Shared by activation (mode.sh) and session
# restore (restore.sh) so both paths report identically.
#   state.sh <project-dir>
set -uo pipefail
proj="${1:?}"; d="$proj/.claude/teamlead"

if git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git: yes — every worker that writes gets isolation: worktree"
  # A worktree is only "leftover" if it holds work. One with a live worker in it
  # is normal, and calling it leftover invites cleanup of active work.
  root=$(cd "$proj" && pwd)
  while read -r w; do
    [ -n "$w" ] || continue
    [ "$w" = "$root" ] && continue
    if [ -n "$(git -C "$w" status --porcelain 2>/dev/null)" ]; then
      echo "  worktree HOLDING UNCOMMITTED WORK: $w"
    else
      echo "  worktree (clean, safe to remove): $w"
    fi
  done < <(git -C "$proj" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
else
  echo "git: no — no worktree isolation available; partition writes by file/dir"
fi

if [ -f "$d/settings.md" ]; then
  "$(dirname "$0")/resolve.sh" "$proj"
else
  echo "settings: MISSING — run Project setup now, before greeting or acting on anything"
fi

if [ -f "$d/board.md" ]; then
  open=$(grep -E '^\| +\|' "$d/board.md" 2>/dev/null) || open=""
  [ -n "$open" ] && { echo "Open board rows:"; printf '%s\n' "$open"; }
fi
[ -f "$d/.state/active-plan" ] && echo "Active plan: $(cat "$d/.state/active-plan")"
[ -f "$d/.state/plugin-root" ] && echo "Plugin scripts: $(cat "$d/.state/plugin-root")/hooks/  (CLAUDE_PLUGIN_ROOT is NOT set in your shell — use this absolute path)"
exit 0
