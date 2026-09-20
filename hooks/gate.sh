#!/usr/bin/env bash
# Stop gate. Blocks ONCE per turn (stop_hook_active guards the loop), so the
# worst case is a forced second look, never a stuck session.
#
# Checks, cheapest first:
#   1. reconcile    — a worker returned but the board still says running
#   1b. board       — internal validity, drift, and whether "merged" is true in git
#   2. decompose    — the tree changed but no task list was ever written
#   3. worktrees    — work left behind by a worker that has FINISHED
#   4. plan footer  — during planning (stage <=4), the turn must end on the fixed line
#   5. plan-lint    — stage 4: the implementation plan itself must pass lint
#   6. stage 5->6   — every board task merged but the plan header was never bumped
#   7. returned     — tasks sitting in 'returned' instead of being triaged
#
# Rule learned the hard way, four times over: a check that fires on a correct
# state is worse than no check. Every condition here must be false during normal
# mid-flight work. Outstanding background workers are NOT a problem: ending the
# turn while they run is the intended shape (the lead is re-invoked when they
# land), and blocking on it here only ever trained "deliberately proceeding".
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

# 1. Returned but never acted on — the window where work used to evaporate.
# (No check on $nout itself: outstanding workers mid-flight are correct, not a
# finding — see header note.)
if [ -f "$TL_STATE/board.json" ] && [ "$(tl_state_count running)" -gt "$nout" ]; then
  problems+=$'\n'"- board.json marks $(tl_state_count running) task(s) 'running' but only $nout worker(s) are still working. Move the returned ones to 'returned' or 'merged'."
fi

# 1b. Board integrity. board.md is the one durable artefact the MODEL writes, so
# it is the one that can be wrong. events.log is hook-written and cannot lie.
if [ -f "$TL_STATE/board.json" ]; then
  bl=$(python3 "${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/scripts/board.py" \
       check --project "$TL_PROJECT" 2>&1) || true
  [ -n "$bl" ] && problems+=$'\n'"$(printf '%s' "$bl" | sed 's/^  - /- /')"
fi

# 2. Decompose. The reported failure "ignores its own task list" starts one step
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

# 3. Worktrees holding work — but only once their worker has FINISHED.
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

# Plan mode. The header line `> **Stage N** —…` in the active plan file is the one
# source of truth for stage (see statusline.sh, plan-lint.sh — same parse there).
plan_stage=""; plan_file=""
if [ -f "$TL_STATE/active-plan" ]; then
  plan_file=$(cat "$TL_STATE/active-plan" 2>/dev/null)
  if [ -n "$plan_file" ] && [ -f "$plan_file" ]; then
    plan_stage=$(grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' "$plan_file" 2>/dev/null | grep -oE '[0-9]+')
  fi
fi

# 4. Fixed footer while planning (stages 1-4). The wording is the model's own
# handoff cue to the user, so it must be byte-exact — a paraphrase reads fine to
# a human but breaks anything matching on it later.
if [ -n "$plan_stage" ] && [ "$plan_stage" -ge 1 ] && [ "$plan_stage" -le 4 ]; then
  if [ "$plan_stage" = "4" ]; then
    footer='Type "Go" if you want me to start implementing.'
  else
    footer='Type "Go" if you want me to plan the implementation.'
  fi
  tp=$(tl_json .transcript_path)
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    last_line=$(python3 - "$tp" <<'PYEOF' 2>/dev/null
import json, sys
path = sys.argv[1]
last_text = None
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("type") == "assistant":
                content = (obj.get("message") or {}).get("content") or []
                if isinstance(content, list):
                    parts = [c.get("text", "") for c in content
                              if isinstance(c, dict) and c.get("type") == "text"]
                    last_text = "".join(parts)
except Exception:
    pass
if last_text is None:
    print("")
else:
    stripped = last_text.rstrip()
    print(stripped.splitlines()[-1] if stripped else "")
PYEOF
) || last_line=""
    [ "$last_line" = "$footer" ] || \
      problems+=$'\n'"- plan is at stage $plan_stage: end the turn with the fixed line: $footer"
  fi
  # transcript_path absent/unreadable: skip silently, nothing to check against.
fi

# 5. plan-lint itself, once there is an implementation plan to lint.
if [ "$plan_stage" = "4" ]; then
  pl_out=$("${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/hooks/plan-lint.sh" "$plan_file" 2>&1)
  if [ $? -ne 0 ]; then
    problems+=$'\n'"$(printf '%s\n' "$pl_out" | tail -n +2)"
  fi
fi

# 6. Everything merged but the header never bumped — the plan would sit "done"
# with nobody told to run acceptance. tl_state_count's by_state never carries
# 'merged' (summary() in board.py drops merged tasks as no longer "open"), so
# zero-across-the-open-states plus at least one task on the board is exactly
# "every task present is merged".
if [ "$plan_stage" = "5" ] && [ -f "$TL_STATE/board.json" ]; then
  still_open=0
  for s in queued running returned blocked; do
    still_open=$(( still_open + $(tl_state_count "$s") ))
  done
  ntasks=$(python3 -c "import json;print(len(json.load(open('$TL_STATE/board.json')).get('tasks',[])))" 2>/dev/null) || ntasks=0
  if [ "$still_open" -eq 0 ] && [ "${ntasks:-0}" -gt 0 ]; then
    problems+=$'\n'"- every board task is merged and the plan is at stage 5 — set the header to Stage 6 and run the 'verified by: agent' criteria"
  fi
fi

# 7. Tasks stuck in 'returned' — the triage step got skipped.
if [ -f "$TL_STATE/board.json" ]; then
  nret=$(tl_state_count returned)
  [ "$nret" -gt 0 ] && problems+=$'\n'"- $nret task(s) are in 'returned' — check what came back and move each to 'merged' (with notes on how it was solved) or back to 'queued'"
fi

[ -z "$problems" ] && exit 0
tl_block "Teamlead — before this turn ends:$problems

Resolve these, or say plainly which you are deliberately skipping and why. This check fires once per turn."
