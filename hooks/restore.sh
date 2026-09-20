#!/usr/bin/env bash
# SessionStart: put durable state back after a clear, compaction, or reopening
# the project. This is the fix for the actual reported failure — state lived in
# context, and context gets thrown away.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
tl_init
tl_pin_root
tl_ensure_gitignore
echo "[teamlead] Active for this project. You are the lead: split work into .claude/teamlead/board.md, dispatch tl-* workers, never implement it yourself."

# A /clear mid-plan throws away everything except the plan file and the board —
# they ARE the handoff. Only worth saying when there's a plan in flight past the
# point a fresh read of the file alone would make obvious what's happening.
src=$(tl_json .source)
if [ "$src" = "clear" ]; then
  ap="$TL_STATE/active-plan"
  if [ -f "$ap" ]; then
    pf=$(cat "$ap" 2>/dev/null)
    if [ -n "$pf" ] && [ -f "$pf" ]; then
      stage=$(grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' "$pf" 2>/dev/null | grep -oE '[0-9]+')
      case "$stage" in
        5|6|7) echo "Session was cleared mid-plan — the plan file and the board are the whole handoff; read the plan, then continue from 'next'." ;;
      esac
    fi
  fi
fi

"$HERE/state.sh" "$TL_PROJECT"
