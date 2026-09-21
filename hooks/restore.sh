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

BOARD="${CLAUDE_PLUGIN_ROOT:-$HERE/..}/scripts/board.py"
src=$(tl_json .source)

# D5/F18: board.md must match board.json before state.sh reads open rows out of
# it (F18: state.sh greps board.md, not board.json) — so render runs on every
# source, compact included, before anything below reads the board. Only when a
# board already exists in some form: render on a wholly absent board would
# create an empty board.md for a project that never had one. A refusal (json
# missing/empty but md still holds rows) is left as-is; board.py check surfaces
# it via the gate — ignore render's own exit status here.
if [ -f "$TL_STATE/board.json" ] || [ -f "$TL_BOARD" ]; then
  python3 "$BOARD" render --project "$TL_PROJECT" >/dev/null 2>&1
fi

echo "[teamlead] Active for this project. You are the lead: split work into .claude/teamlead/board.md, dispatch tl-* workers, never implement it yourself."

# D1: on startup/resume/clear (not compact — agents survive it) close out every
# outstanding worker whose start predates THIS session's own first event — no
# liveness probe, just "older than us and not started by us". The boundary is
# this session's earliest ledger line; before any exist (the usual case on
# startup) there is nothing of ours yet, so "now" is the boundary. No session_id
# means we can't tell whose workers they'd be, so skip rather than guess.
case "$src" in
  startup|resume|clear)
    sid=$(tl_json .session_id)
    if [ -n "$sid" ]; then
      boundary=$(grep -E "session=${sid}\$" "$TL_EVENTS" 2>/dev/null | head -1 | awk '{print $1}')
      [ -n "$boundary" ] || boundary=$(tl_now)
      fout=$(python3 "$BOARD" forget all --before "$boundary" --not-session "$sid" \
                     --project "$TL_PROJECT" 2>/dev/null)
      ids=$(printf '%s' "$fout" | jq -r '(.forgotten // []) | join(" ")' 2>/dev/null)
      if [ -n "$ids" ]; then
        n=$(printf '%s' "$ids" | wc -w | tr -d ' ')
        echo "[teamlead] Closed out $n worker(s) from a previous session: $ids — they never reported back."
      fi
    fi
    ;;
esac

# A /clear mid-plan throws away everything except the plan file and the board —
# they ARE the handoff. Only worth saying when there's a plan in flight past the
# point a fresh read of the file alone would make obvious what's happening.
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
