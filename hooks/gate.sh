#!/usr/bin/env bash
# Stop gate. Blocks ONCE per turn (stop_hook_active guards the loop), so the
# worst case is a forced second look, never a stuck session.
#
# Checks, cheapest first:
#   1. outstanding  — workers still running, paired by agent id
#   2. reconcile    — a worker returned but the board still says running
#   2b. board       — internal validity, drift, and whether "merged" is true in git
#   3. decompose    — the tree changed but no task list was ever written
#   4. worktrees    — work left behind by a worker that has FINISHED
#
# Rule learned the hard way, four times over: a check that fires on a correct
# state is worse than no check. Every condition here must be false during normal
# mid-flight work.
set -uo pipefail
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/hooks/lib.sh"
tl_init

[ "$(tl_json .stop_hook_active)" = "true" ] && exit 0

problems=""

# State counted from board.json, never by grepping rendered markdown.
tl_state_count() {
  python3 "${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/scripts/board.py" \
    list --project "$TL_PROJECT" 2>/dev/null \
  | python3 -c "import json,sys;print(len(json.load(sys.stdin)['by_state'].get('$1',[])))" 2>/dev/null || echo 0
}

# Workers still out, by id. Counting dispatches against returns drifted two ways:
# a resumed worker fires no dispatch, and a killed one fires no return. Pairing
# start/resume against return by agent id is exact, and it does not care how long
# a worker runs — observed runs reach ~1.5h.
BOARD_PY="${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/scripts/board.py"
lg=$(python3 "$BOARD_PY" ledger --project "$TL_PROJECT" 2>/dev/null) || lg=""
out_ids=$(printf '%s' "$lg" | python3 -c "
import json,sys
try: print(' '.join(json.load(sys.stdin)['outstanding']))
except Exception: pass" 2>/dev/null)
npend=$(printf '%s' "$lg" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('pending',0))
except Exception: print(0)" 2>/dev/null) || npend=0
nout=$(( $(printf '%s' "$out_ids" | wc -w) + ${npend:-0} ))

if [ "$nout" -gt 0 ]; then
  problems+=$'\n'"- $nout worker(s) still running. Wait for them, or say why you are proceeding without them."
fi

# 2. Returned but never acted on — the window where work used to evaporate.
if [ -f "$TL_STATE/board.json" ] && [ "$(tl_state_count running)" -gt "$nout" ]; then
  problems+=$'\n'"- board.json marks $(tl_state_count running) task(s) 'running' but only $nout worker(s) are still out. Move the returned ones to 'returned' or 'merged'."
fi

# 2b. Board integrity. board.md is the one durable artefact the MODEL writes, so
# it is the one that can be wrong. events.log is hook-written and cannot lie.
if [ -f "$TL_STATE/board.json" ]; then
  bl=$(python3 "${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/scripts/board.py" \
       check --project "$TL_PROJECT" 2>&1) || true
  [ -n "$bl" ] && problems+=$'\n'"$(printf '%s' "$bl" | sed 's/^  - /- /')"
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

# 4. Worktrees holding work — but only once their worker has FINISHED.
# A worktree with a live worker in it is normal mid-flight, not a finding. Flagging
# those trained the lead to answer every block with "deliberately proceeding",
# which is how a gate stops being read.
if git -C "$TL_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty=""
  main=$(git -C "$TL_PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  while read -r w; do
    [ -n "$w" ] || continue
    [ "$w" = "$TL_PROJECT" ] && continue
    # .claude/worktrees/agent-<id> — skip it while that worker is still out.
    wid=$(basename "$w"); wid=${wid#agent-}
    case " $out_ids " in *" $wid "*) continue ;; esac
    note=""
    [ -n "$(git -C "$w" status --porcelain 2>/dev/null)" ] && note="uncommitted changes"
    n=$(git -C "$w" rev-list --count "$main..HEAD" 2>/dev/null) || n=0
    [ "${n:-0}" -gt 0 ] && note="${note:+$note, }$n commit(s) not in $main"
    [ -n "$note" ] && dirty+="  $w — $note"$'\n'
  done < <(git -C "$TL_PROJECT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  [ -n "$dirty" ] && problems+=$'\n'"- finished worker(s) left work behind:"$'\n'"$dirty"
fi

[ -z "$problems" ] && exit 0
tl_block "Teamlead — before this turn ends:$problems

Resolve these, or say plainly which you are deliberately skipping and why. This check fires once per turn."
