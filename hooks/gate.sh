#!/usr/bin/env bash
# Stop gate. Blocks ONCE per turn (stop_hook_active guards the loop), so the
# worst case is a forced second look, never a stuck session.
#
# Checks, cheapest first:
#   1. reconcile    — a worker returned but the board still says running
#   1b. board       — internal validity, drift, and whether "merged" is true in git
#   2. decompose    — the tree changed but no task list was ever written
#   3. worktrees    — work left behind by a worker that has FINISHED
#   3b. plan-stage  — header stage vs. last-accepted (D2): catches a plan-file
#                      write that bypassed plan-fence.sh entirely (F1)
#   4. plan footer  — during planning (stage <=4), the turn must end on the fixed line
#   4b. no /clear offer — stage 4: the fresh-context offer waits for the recorded Go
#   5. plan-lint    — stage 4: the implementation plan itself must pass lint
#   6. stage 5->6   — every step of the current phase boarded + merged, header never bumped
#                      (the message names the phase and what follows Stage 7, #8)
#   7. returned     — tasks sitting in 'returned' instead of being triaged
#   8. superdoc     — doc findings in files that HEAD gained since the last Stop (independent of
#                      board rows; wired projects only; shown once, see the check)
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
  # Worktrees the lead marked as kept on purpose (`board.py hold`, #4/#9): row,
  # and why the hold stopped applying ("" while it is good). A good hold is not a
  # finding — without it this check re-fired every turn on a correct state. A hold
  # survives new commits and edits (#16); only --until-change holds lapse on them.
  # A default hold whose worktree got new work gets ONE note (held_notes), never a
  # block; held-noted records that it was shown. Fields: path, row, note_due 0/1, and
  # last, because it may be empty, the lapse reason.
  declare -A held_row=() held_lapsed=()
  held_notes=""
  while IFS=$'\t' read -r hp_ hr_ hn_ hl_; do
    [ -n "$hp_" ] || continue
    held_row[$hp_]=$hr_; held_lapsed[$hp_]=$hl_
    if [ "$hn_" = 1 ]; then
      held_notes+="${held_notes:+$'\n'}  held worktree $hp_ (row $hr_) has new commits or edits since the hold; it stays held, this is the only mention. Merge or release it when it is done."
      python3 "$BOARD_PY" held-noted "$hr_" --project "$TL_PROJECT" >/dev/null 2>&1 || true
    fi
  done < <(python3 "$BOARD_PY" held --project "$TL_PROJECT" 2>/dev/null | python3 -c "
import json,sys
try:
    for p,h in json.load(sys.stdin).items(): print(p,h['row'],int(h['note_due']),h['lapsed'] or '',sep='\t')
except Exception: pass" 2>/dev/null)
  # Board rows by branch and by worker id, merged rows first so an open row wins when
  # several name the same worktree. Used to scope this check and to name the row to hold.
  declare -A row_by_branch=() row_by_worker=() row_state=()
  while IFS=$'\t' read -r rid_ rst_ rbr_ rwk_; do
    [ -n "$rid_" ] || continue
    row_state[$rid_]=$rst_
    [ -n "$rbr_" ] && row_by_branch[$rbr_]=$rid_
    [ -n "$rwk_" ] && row_by_worker[$rwk_]=$rid_
  done < <(python3 -c "
import json,sys
try:
    ts = json.load(open('$TL_STATE/board.json'))['tasks']
    for t in sorted(ts, key=lambda t: t['state'] != 'merged'):
        print(t['id'], t['state'], t.get('branch') or '', t.get('worker') or '', sep='\t')
except Exception: pass" 2>/dev/null)
  hold_rows=" "
  while read -r w; do
    [ -n "$w" ] || continue
    [ "$w" = "$TL_PROJECT" ] && continue
    # .claude/worktrees/agent-<id> — skip it while that worker is still out.
    wid=$(basename "$w"); wid=${wid#agent-}
    case " $out_ids " in *" $wid "*) continue ;; esac
    [ -n "${held_row[$w]:-}" ] && [ -z "${held_lapsed[$w]:-}" ] && continue
    # Scope: the plugin's own worktrees only. A worker's is always
    # .claude/worktrees/agent-<id>; anything else belongs to the plugin only when a
    # board row names its branch or holds it. A worktree the user made by hand for
    # their own branch has no row and cannot be held, so flagging it fired every turn
    # on a correct state (#9 class).
    wbr=$(git -C "$w" rev-parse --abbrev-ref HEAD 2>/dev/null) || wbr=""
    wrow="${row_by_worker[$wid]:-}"
    [ -n "$wbr" ] && [ -n "${row_by_branch[$wbr]:-}" ] && wrow="${row_by_branch[$wbr]}"
    case "$w" in
      */.claude/worktrees/agent-*) ;;
      *) [ -n "$wrow" ] || [ -n "${held_row[$w]:-}" ] || continue ;;
    esac
    note=""
    [ -n "$(git -C "$w" status --porcelain 2>/dev/null)" ] && note="uncommitted changes"
    n=$(git -C "$w" rev-list --count "$main..HEAD" 2>/dev/null) || n=0
    [ "${n:-0}" -gt 0 ] && note="${note:+$note, }$n commit(s) not in $main"
    [ -n "$note" ] || continue
    if [ -n "${held_row[$w]:-}" ]; then
      note+=" (hold on row ${held_row[$w]} lapsed: ${held_lapsed[$w]})"
    elif [ -z "$wrow" ]; then
      note+=" (no board row)"
    elif [ "${row_state[$wrow]:-}" = merged ]; then
      note+=" (board row $wrow, merged)"
    else
      note+=" (board row $wrow)"
      case "$hold_rows" in *" $wrow "*) ;; *) hold_rows+="$wrow " ;; esac
    fi
    dirty+="  $w — $note"$'\n'
  done < <(git -C "$TL_PROJECT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  # One holdable row among the findings: print the command ready to run.
  hrow_arg="<row>"; [ "$(wc -w <<<"$hold_rows")" = 1 ] && hrow_arg=${hold_rows// /}
  [ -n "$dirty" ] && problems+=$'\n'"- finished worker(s) left work behind:"$'\n'"${dirty}  Kept on purpose (paused work, a commit awaiting the user's decision)? Acknowledge it once, instead of answering this gate every turn: python3 $BOARD_PY hold $hrow_arg --reason \"…\" --project \"\$PWD\" (use the board row shown above; it must be queued, blocked or returned). It stays quiet, also across new commits and edits (add --until-change to have it lapse on those), until the row is re-dispatched or merged or the worktree is removed. Not kept? Merge it, or remove the worktree (removing one with unmerged commits needs the user's OK)."
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

# 3b. plan-stage consistency (D2). plan-fence.sh only guards Edit|Write|MultiEdit,
# so a Bash/python write to the plan file (F1) never runs its checks at all. This
# re-derives the header stage independently and compares it to the stage
# plan-fence last accepted ($TL_STATE/plan-stage, "<stage> <ISO-8601 ts>") — the
# net that catches every writer, whatever tool it used.
if [ -n "$plan_stage" ]; then
  cur="$plan_stage"
  rec=""; rec_ts=""
  [ -f "$TL_STATE/plan-stage" ] && read -r rec rec_ts < "$TL_STATE/plan-stage" 2>/dev/null
  if [ -z "$rec" ]; then
    # first run, or a plan predating this check — nothing to compare against yet.
    printf '%s %s\n' "$cur" "$(tl_now)" > "$TL_STATE/plan-stage"
  elif [ "$cur" -gt "$rec" ] 2>/dev/null && [ $((cur - rec)) -gt 1 ]; then
    problems+=$'\n'"- plan header moved Stage $rec → $cur without passing through $((rec + 1)) — set it back to $((rec + 1)) (a Go advances exactly one stage)"
  else
    # Same "Go newer than the last accepted bump" rule as plan-fence.sh (not
    # extracted to lib.sh — that file belongs to another worker's step).
    go_needed=""
    case "$rec-$cur" in
      3-4|4-5) go_needed=1 ;;
    esac
    go_ok=1
    if [ -n "$go_needed" ]; then
      go_ok=0
      if [ -f "$TL_STATE/plan-go" ]; then
        while IFS=' ' read -r _ go_ts; do
          [ -n "$go_ts" ] || continue
          if [ -z "$rec_ts" ] || [[ "$go_ts" > "$rec_ts" ]]; then go_ok=1; fi
        done < "$TL_STATE/plan-go"
      fi
    fi
    if [ "$go_ok" != 1 ]; then
      problems+=$'\n'"- plan header moved Stage $rec → $cur but no \"Go\" is recorded since the last stage change — get a Go from the user, or set the header back to $rec"
    else
      # Accepted (delta 0 or 1 with Go rules satisfied) — record so the next
      # Stop compares against this, not a jump already handled. T66: only when
      # the stage actually moved; re-stamping an unchanged stage would make any
      # Go typed before this Stop look older than "the last stage change".
      [ "$cur" != "$rec" ] && printf '%s %s\n' "$cur" "$(tl_now)" > "$TL_STATE/plan-stage"
    fi
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

# 4b. No /clear offer while still asking for the Go. The fresh-context offer
# (`/teamlead plan continue`) belongs to the reply to the second Go, after the Go is
# recorded and the header is Stage 5. Printed at stage 4 it sends the user through
# /clear and into a `plan continue` that sees no Go and refuses. Stage 4 only: at 5+
# the offer and phase-boundary /clear advice are legitimate; 1-3 are left alone.
if [ "$plan_stage" = "4" ] && tl_json .last_assistant_message | grep -qF '/teamlead plan continue'; then
  problems+=$'\n'"- plan is at stage 4 and your message offers /clear or \`/teamlead plan continue\` — remove it. Ask for the Go with the fixed footer only; print the fresh-context offer only after the user's Go, once the header is Stage 5 (a /clear before then loses the Go)."
fi

# 5. plan-lint itself, once there is an implementation plan to lint.
if [ "$plan_stage" = "4" ]; then
  pl_out=$("${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/hooks/plan-lint.sh" "$plan_file" 2>&1)
  if [ $? -ne 0 ]; then
    problems+=$'\n'"$(printf '%s\n' "$pl_out" | tail -n +2)"
  fi
fi

# 6. Everything merged but the header never bumped — the plan would sit "done"
# with nobody told to run acceptance. The board alone cannot say "done": the lead
# boards one wave/phase at a time, so it is legitimately all-merged between waves
# while later I<n> steps have no row yet (#6). Two conditions, both required:
#   a. nothing open on the board — tl_state_count's by_state never carries
#      'merged' (summary() in board.py drops merged tasks as no longer "open"), so
#      zero-across-the-open-states plus at least one task is "every task present
#      is merged";
#   b. plan_scope_done: every I<n> step of the CURRENT scope has a board row and
#      all its rows are merged.
#
# plan_scope_done <check|snap|info>. check prints "yes"/"no"; info prints the
# phase's name, position and successor for the message (see plan-scope.py). The scope is the current
# phase, or the whole table when it has no phase rows; a table with no I<n> step
# at all has nothing to wait for, so "yes" (the old board-only behaviour). It
# calls board.py's plan_progress(), the same function check_plan (check 1b) and the
# statusline use, not a second parser.
# .state/phase-accepted holds the steps that already went through stage 6/7 (snap
# records them while the header sits at 6 or 7). Without it a finished, accepted
# phase — merged rows still on the board, header back at 5 for the next phase —
# would stay "current" and fire again. The current phase is the first one with a
# step that is not accepted-and-still-merged, so a step reopened by a stage-6/7
# failure is current again.
# The parser lives in plan-scope.py so state.sh reads the same phase the gate does.
plan_scope_done() {
  python3 "${CLAUDE_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}/hooks/plan-scope.py" \
    "$BOARD_PY" "$TL_PROJECT" "$plan_file" "$TL_STATE/phase-accepted" "$1" 2>/dev/null || echo yes
}

if { [ "$plan_stage" = "6" ] || [ "$plan_stage" = "7" ]; } && [ -f "$TL_STATE/board.json" ]; then
  plan_scope_done snap >/dev/null
fi
if [ "$plan_stage" = "5" ] && [ -f "$TL_STATE/board.json" ]; then
  still_open=0
  for s in queued running returned blocked; do
    still_open=$(( still_open + $(tl_state_count "$s") ))
  done
  ntasks=$(python3 -c "import json;print(len(json.load(open('$TL_STATE/board.json')).get('tasks',[])))" 2>/dev/null) || ntasks=0
  if [ "$still_open" -eq 0 ] && [ "${ntasks:-0}" -gt 0 ] && [ "$(plan_scope_done check)" = "yes" ]; then
    # Name the scope. "Stage 6" read as "the whole plan is done" is how a correct
    # gate got overridden as a false positive (#8): each phase loops 5 -> 6 -> 7.
    IFS='|' read -r ph_total ph_idx ph_label ph_next ph_steps < <(plan_scope_done info 5)
    if [ "${ph_total:-0}" -gt 0 ] 2>/dev/null; then
      scope="phase $ph_label (of $ph_total, $ph_steps)"
      if [ -n "$ph_next" ]; then
        after="This is the normal phase cycle, not the end of the plan: phase $ph_next comes after Stage 7 (Stage 7 → Stage 5 for phase $ph_next; no \"Go\" needed)."
      else
        after="Phase $ph_label is the last phase: after Stage 7 the plan is complete."
      fi
      crit="phase $ph_label's"
      hdr="> **Stage 6** — verifying phase $ph_label of $ph_total"
    else
      scope="the whole plan (no phase rows: the table is one phase)"
      after="After Stage 7 the plan is complete."
      crit="the plan's"
      hdr="> **Stage 6** — verifying the whole plan"
    fi
    problems+=$'\n'"- every step of $scope is boarded and merged and the plan is at stage 5 — set the header to Stage 6 ($hdr) and run $crit 'verified by: agent' criteria. $after If this gate still looks wrong, re-read it against the plan's phase structure first; if it really is wrong, report it as a plugin bug — do not override it silently."
  fi
fi

# 7. Tasks stuck in 'returned' — the triage step got skipped.
if [ -f "$TL_STATE/board.json" ]; then
  nret=$(tl_state_count returned)
  [ "$nret" -gt 0 ] && problems+=$'\n'"- $nret task(s) are in 'returned' — check what came back and move each to 'merged' (with notes on how it was solved) or back to 'queued'. Waiting on the user's decision instead? Set it to 'blocked' with a note saying what you are waiting for (blocked rows are not flagged here); if it keeps a worktree, board.py hold it too"
fi

# 8. superdoc findings that arrived with a merge, shown once. Wired projects only (CLAUDE.md has
# `superdoc:start`); independent of board rows, so it also sees a merge the lead never boarded.
# State: $TL_STATE/superdoc-lint-head = the HEAD last checked. No state: record HEAD and say
# nothing (old debt is not noise). A recorded commit that is no longer an ancestor of HEAD
# (history rewritten, another branch checked out): reset to HEAD, nothing. Otherwise lint exactly
# the files git says changed since then (pre-filtered to CLAUDE.md and the doc root: lint's
# --files is quadratic in file count, so a huge merge must not hand it every file), and advance
# the state BEFORE showing anything, so a finding fires once. No finding, or no doc file touched,
# prints nothing: this must be false on every correct state. What is shown: `warn` findings from
# `lint.sh --files` (the touched files, whatever their age), and `error` findings only from
# `lint.sh --range last..HEAD` (lines added in this merge: "a leak got past the commit hooks" is
# then true, and old debt on a line near a typo fix is not re-reported). Each is dropped from the
# other so nothing shows twice. The Stop hook has 10s: each lint call runs under `timeout 4`, and
# on a timeout the state stays where it was and the check stays quiet (it retries at the next
# Stop). The output is capped at 40 lines, like superdoc-guard.sh. When a doc .md or CLAUDE.md is
# among the changed files, `map.py --check` also runs (same timeout, same state) and its DANGLING
# lines that start in or point at a changed file are shown too, capped separately at 40 (#19).
if tl_superdoc_wired "$TL_PROJECT"; then
  sd_head=$(git -C "$TL_PROJECT" rev-parse -q --verify HEAD 2>/dev/null) || sd_head=""
  if [ -n "$sd_head" ]; then
    sd_state="$TL_STATE/superdoc-lint-head"
    sd_last=$(cat "$sd_state" 2>/dev/null) || sd_last=""
    if [ "$sd_last" = "$sd_head" ]; then
      :
    elif [ -z "$sd_last" ] || ! git -C "$TL_PROJECT" merge-base --is-ancestor "$sd_last" "$sd_head" 2>/dev/null; then
      mkdir -p "$TL_STATE" 2>/dev/null; printf '%s\n' "$sd_head" > "$sd_state" 2>/dev/null
    else
      sd_lint=$(tl_superdoc_lint)
      sd_root=""
      [ -f "$sd_lint" ] && sd_root=$(cd "$TL_PROJECT" && bash "$sd_lint" --print-doc-root 2>/dev/null | head -n 1)
      # NUL-separated: a name with spaces or a leading dash stays one argument. Only CLAUDE.md and
      # files under the doc root go to lint (it ignores the rest anyway).
      sd_files=()
      while IFS= read -r -d '' sd_f; do
        if [ "$sd_f" = CLAUDE.md ]; then sd_files+=("$sd_f")
        elif [ -n "$sd_root" ]; then case "$sd_f" in "$sd_root"/*) sd_files+=("$sd_f") ;; esac
        fi
      done < <(git -C "$TL_PROJECT" diff --name-only -z "$sd_last" "$sd_head" 2>/dev/null)
      sd_out=""; sd_warn=""; sd_err=""; sd_rc=0
      if [ "${#sd_files[@]}" -gt 0 ] && [ -f "$sd_lint" ]; then
        sd_warn=$(cd "$TL_PROJECT" && tl_timeout 4 bash "$sd_lint" --files -- "${sd_files[@]}" 2>/dev/null)
        sd_rc=$?
        if [ "$sd_rc" != 124 ]; then
          sd_err=$(cd "$TL_PROJECT" && tl_timeout 4 bash "$sd_lint" --range "$sd_last..$sd_head" 2>/dev/null)
          sd_rc=$?
        fi
        # errors (and the fix/note lines that only go with them) from the range, warnings (and
        # their hints) from the files; the summary line of either is dropped.
        sd_out=$(printf '%s\n' "$sd_err" | grep -E ': error: |^fix: |^note: '
                 printf '%s\n' "$sd_warn" | grep -E ': warn: |^hint: ')
      fi
      # Links (#19): when a doc .md or CLAUDE.md changed, map.py --check over the whole tree; shown
      # are the DANGLING lines whose linking file or target is among the changed files (a deleted or
      # renamed page, a lost heading), not old debt elsewhere. Same timeout and once-only state.
      sd_map=""; sd_mapper=$(tl_superdoc_map); sd_md=0
      for sd_f in ${sd_files[@]+"${sd_files[@]}"}; do case "$sd_f" in *.md) sd_md=1 ;; esac; done
      if [ "$sd_md" = 1 ] && [ "$sd_rc" != 124 ] && [ -f "$sd_mapper" ]; then
        sd_map=$(cd "$TL_PROJECT" && tl_timeout 4 python3 "$sd_mapper" --check 2>/dev/null)
        [ $? = 124 ] && sd_rc=124
        sd_map=$(printf '%s\n' "$sd_map" | SD_CHANGED=$(printf '%s\n' "${sd_files[@]}") awk '
          BEGIN { n = split(ENVIRON["SD_CHANGED"], a, "\n"); for (i = 1; i <= n; i++) ch[a[i]] = 1 }
          /^DANGLING / && match($0, / -> /) {
            l = substr($0, 1, RSTART - 1); sub(/^DANGLING +/, "", l); sub(/:[0-9]+$/, "", l)
            r = substr($0, RSTART + 4); sub(/  \(.*\)$/, "", r); sub(/#.*/, "", r)
            if (l in ch || r in ch) print
          }')
      fi
      if [ "$sd_rc" = 124 ]; then
        :   # timed out: leave the state alone, say nothing
      else
        printf '%s\n' "$sd_head" > "$sd_state" 2>/dev/null
        if [ -n "$sd_out" ]; then
          sd_n=$(printf '%s\n' "$sd_out" | wc -l)
          sd_msg="- superdoc: the merge brought in doc findings (shown once, in files it touched). Lint output; it never prints a value:"$'\n'"$(printf '%s\n' "$sd_out" | head -n 40 | sed 's/^/    /')"
          [ "$sd_n" -gt 40 ] && sd_msg+=$'\n'"    ... and $((sd_n - 40)) more line(s) not shown; $sd_lint lists them all (no arguments: the whole tree)"
          if printf '%s\n' "$sd_out" | grep -q ': error: '; then
            sd_msg+=$'\n'"  An error means a leak got past the commit hooks. Repair it now (placeholder in the file; anything useful moves to .claude/local/) and do not push until lint is clean. If the value is already in a commit, repairing the file does not remove it: tell the user that, and whether it was pushed. Rewriting history is theirs to decide."
          fi
          if printf '%s\n' "$sd_out" | grep -q ': warn: '; then
            sd_msg+=$'\n'"  Warnings: fix them or leave them on your own judgement (dispatch a repair if it is worth it). The docs are the agents' job: do not ask the user about them."
          fi
          problems+=$'\n'"$sd_msg"
        fi
        if [ -n "$sd_map" ]; then
          sd_mn=$(printf '%s\n' "$sd_map" | wc -l)
          sd_mm="- superdoc: the merge left dangling links (shown once; the link's file or anchor is gone). Fix them now (retarget or remove the link), then re-run \`python3 $sd_mapper --check\`:"$'\n'"$(printf '%s\n' "$sd_map" | head -n 40 | sed 's/^/    /')"
          [ "$sd_mn" -gt 40 ] && sd_mm+=$'\n'"    ... and $((sd_mn - 40)) more line(s) not shown; \`python3 $sd_mapper --check\` lists them all"
          problems+=$'\n'"$sd_mm"
        fi
      fi
    fi
  fi
fi

# The held-worktree note (#16) never blocks by itself: with no problem it goes out as a
# systemMessage on exit 0; when the turn is blocked anyway it rides along.
if [ -z "$problems" ]; then
  [ -n "${held_notes:-}" ] && jq -n --arg m "Teamlead:${held_notes}" '{systemMessage:$m}'
  exit 0
fi
[ -n "${held_notes:-}" ] && problems+=$'\n'"- note (shown once):"$'\n'"$held_notes"
tl_block "Teamlead — before this turn ends:$problems

Resolve these, or say plainly which you are deliberately skipping and why. This check fires once per turn."
