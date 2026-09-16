#!/usr/bin/env bash
# Stop gate. Blocks ONCE per turn (stop_hook_active guards the loop), so the
# worst case is a forced second look, never a stuck session.
#
# Three checks, cheapest first:
#   1. outstanding  — dispatched workers that never returned
#   2. reconcile    — events.log says returned, board still says running
#   3. worktrees    — worker branches with unmerged or uncommitted work
set -uo pipefail
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/hooks/lib.sh"
tl_init

[ "$(tl_json .stop_hook_active)" = "true" ] && exit 0

problems=""

# 1. Outstanding dispatches. (Ledger checks only run once a ledger exists —
# a project that has not dispatched yet must still get checks 3 and 4.)
# Counts are global, not per-turn: a background worker dispatched three turns
# ago still returns into this same ledger.
if [ -f "$TL_EVENTS" ]; then
d=$(grep -c '  dispatch  ' "$TL_EVENTS" 2>/dev/null) || d=0
r=$(grep -c '  return    ' "$TL_EVENTS" 2>/dev/null) || r=0
if [ "$d" -gt "$r" ]; then
  problems+=$'\n'"- $((d - r)) dispatched worker(s) have not returned yet. Wait for them, or say why you are proceeding without them."
fi

# 2. Returned but never acted on. A task the board still calls 'running' while
# the ledger recorded its return is exactly the work that used to evaporate.
# State is column 7 of "| ✓ | ID | Task | Agent | Owns | State | Branch |".
# Scanning the whole line matched a Task cell that merely began with "running".
tl_state_count() { awk -F'|' -v want="$1" 'NF>7{s=$7;gsub(/^ +| +$/,"",s); if(s==want)n++} END{print n+0}' "$TL_BOARD"; }
if [ -f "$TL_BOARD" ] && [ "$r" -gt 0 ] && [ "$(tl_state_count running)" -gt 0 ]; then
  running=$(tl_state_count running)
  outstanding=$((d - r))
  if [ "$running" -gt "$outstanding" ]; then
    problems+=$'\n'"- board.md marks $running task(s) 'running' but only $outstanding worker(s) are still out. Update the returned ones to 'returned' or 'merged'."
  fi
fi

fi

# 2b. Board format. The row checks above are worthless against an invented
# format, and the model will invent one given the chance.
if [ -f "$TL_BOARD" ] && ! grep -q '^| ✓ | ID | Task |' "$TL_BOARD"; then
  problems+=$'\n'"- board.md is not in the required table format (| ✓ | ID | Task | Agent | Owns | State | Branch |). Rewrite it as that table."
fi

# 3. Decompose. The reported failure "ignores its own task list" starts one step
# earlier: no list was ever made. If this turn changed the working tree in more
# than one place and the board was not touched, the work was never decomposed.
# ponytail: 2+ files, so a one-line fix is never nagged.
if [ -f "$TL_STATE/turn-baseline" ] && git -C "$TL_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  now=$(git -C "$TL_PROJECT" status --porcelain 2>/dev/null | grep -v '\.claude/teamlead/') || now=""
  changed=$(comm -13 <(sort "$TL_STATE/turn-baseline") <(printf '%s\n' "$now" | sort) | grep -c . ) || changed=0
  if [ "$changed" -ge 2 ]; then
    was=$(cat "$TL_STATE/turn-board-mtime" 2>/dev/null || echo 0)
    is=$(date -r "$TL_BOARD" +%s%N 2>/dev/null || echo 0)
    [ "$is" -le "$was" ] && problems+=$'\n'"- $changed files changed but .claude/teamlead/board.md was never written. Decompose the request into board rows first — that is the task list you are meant to work off."
  fi
fi

# 4. Worktrees holding work.
if git -C "$TL_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty=""
  main=$(git -C "$TL_PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  while read -r w; do
    [ -n "$w" ] || continue
    [ "$w" = "$TL_PROJECT" ] && continue
    note=""
    [ -n "$(git -C "$w" status --porcelain 2>/dev/null)" ] && note="uncommitted changes"
    # "never merged back" is the other half: commits that exist only on this branch.
    n=$(git -C "$w" rev-list --count "$main..HEAD" 2>/dev/null) || n=0
    [ "${n:-0}" -gt 0 ] && note="${note:+$note, }$n commit(s) not in $main"
    [ -n "$note" ] && dirty+="  $w — $note"$'\n' 
  done < <(git -C "$TL_PROJECT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  [ -n "$dirty" ] && problems+=$'\n'"- worker worktrees still hold work:"$'\n'"$dirty"
fi

[ -z "$problems" ] && exit 0
tl_block "Teamlead — before this turn ends:$problems

Resolve these, or say plainly which you are deliberately skipping and why. This check fires once per turn."
