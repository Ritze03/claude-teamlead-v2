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
  # "safe to remove" has to be a claim the script can back: no uncommitted changes
  # AND nothing committed that $main does not already have. Same $main and the same
  # rev-list as gate.sh, so the two hooks cannot disagree about "unmerged".
  main=$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null) || main=""
  while read -r w; do
    [ -n "$w" ] || continue
    [ "$w" = "$root" ] && continue
    if ! git -C "$w" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "  worktree CANNOT BE CHECKED (not a git work tree) — do not remove: $w"
      continue
    fi
    if [ -z "$main" ]; then
      echo "  worktree CANNOT BE CHECKED (main branch unresolved) — do not remove: $w"
      continue
    fi
    note=""
    if st=$(git -C "$w" status --porcelain 2>/dev/null); then
      [ -n "$st" ] && note="uncommitted changes"
    else
      note="status check FAILED"
    fi
    if n=$(git -C "$w" rev-list --count "$main..HEAD" 2>/dev/null); then
      [ "${n:-0}" -gt 0 ] && note="${note:+$note, }$n commit(s) not in $main"
    else
      note="${note:+$note, }unmerged-commit check FAILED"
    fi
    if [ -n "$note" ]; then
      echo "  worktree HOLDING WORK ($note): $w"
    else
      echo "  worktree (clean, merged into $main, safe to remove): $w"
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
if [ -f "$d/.state/active-plan" ]; then
  pf=$(cat "$d/.state/active-plan" 2>/dev/null)
  if [ -n "$pf" ] && [ -f "$pf" ]; then
    echo "Active plan: $pf"
    stage=$(grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' "$pf" 2>/dev/null | grep -oE '[0-9]+')
    if [ -n "$stage" ]; then
      case "$stage" in
        1) label="topic" ;;
        2) label="file created, show the path: $pf" ;;
        3) label="working it out" ;;
        4) label="implementation plan written, awaiting Go" ;;
        5) label="building" ;;
        6) label="agent-testing" ;;
        7) label="user-testing" ;;
        *) label="unknown" ;;
      esac
      echo "  stage: $stage — $label"

      # go: the last "Go" the user typed, vs the last stage bump the plan-fence
      # hook recorded. A Go is only live if nothing has moved the stage since —
      # otherwise it belongs to a stage already left behind.
      go_line=$(tail -n1 "$d/.state/plan-go" 2>/dev/null)
      stage_line=$(tail -n1 "$d/.state/plan-stage" 2>/dev/null)
      go_ts=${go_line#* }; stage_ts=${stage_line#* }
      go_recorded=0
      if [ -n "$go_line" ] && { [ -z "$stage_line" ] || [[ "$go_ts" > "$stage_ts" ]]; }; then
        go_recorded=1
      fi
      if [ "$go_recorded" = 1 ]; then
        echo "  go: recorded at $go_ts (stage ${go_line%% *})"
      else
        echo "  go: none recorded since the last stage change"
      fi

      # watcher: deliberately off during 5-6 (execution/agent testing), so only
      # 2-4 (planning) and 7 (the user ticks their boxes in the file) get the restart line.
      case "$stage" in
        2|3|4|7)
          pidf="$d/.state/plan-watch.pid"
          if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
            echo "  watcher: running (pid $(cat "$pidf"))"
          else
            root=$(cat "$d/.state/plugin-root" 2>/dev/null)
            [ -n "$root" ] || root="$(dirname "$0")/.."
            echo "  watcher: NOT running — restart it: $root/hooks/watch-plan.sh \"$proj\" \"$pf\"  (Monitor tool, timeout 1800000, then write the task id to .state/plan-watch)"
          fi
          ;;
        *) echo "  watcher: off (stages 5-6)" ;;
      esac

      # Which phase is this stage about? Same parser the Stop gate uses, so the two
      # cannot disagree. A plan with phases loops 5 -> 6 -> 7 once per phase, and a
      # `next:` that reads as plan-global is how the stage-6 gate got overridden (#8).
      ph_total=0; ph_idx=0; ph_label=""; ph_next=""; ph_steps=""
      case "$stage" in
        5|6|7)
          IFS='|' read -r ph_total ph_idx ph_label ph_next ph_steps < <(python3 "$(dirname "$0")/plan-scope.py" \
            "$(dirname "$0")/../scripts/board.py" "$proj" "$pf" "$d/.state/phase-accepted" info "$stage" 2>/dev/null)
          ;;
      esac
      if [ "${ph_total:-0}" -gt 0 ] 2>/dev/null; then
        scope="phase $ph_label of $ph_total"
        echo "  phase: phase $ph_label of $ph_total ($ph_steps) — each phase runs Stage 5 → 6 → 7, then back to Stage 5 for the next one"
        if [ -n "$ph_next" ]; then
          after7="back to Stage 5 for phase $ph_next (your own move, no \"Go\" needed — Stage 7 → 5 is the normal cycle, not a step backwards; do not tell them the whole plan is done)"
        else
          after7="plan complete (phase $ph_label is the last phase) — tell them it is done and that it can be archived; run plan-archive.sh only if they ask"
        fi
      else
        scope="the whole plan"; after7="plan complete — tell them it is done and that it can be archived; run plan-archive.sh only if they ask"
      fi
      case "$stage" in
        1) next="settle the topic and create the plan file" ;;
        2) next="show the path table, start the watcher, dispatch the scout" ;;
        3) next='answer the open questions with the user; end every turn with: Type "Go" if you want me to plan the implementation.' ;;
        4) next='wait for "Go"; end every turn with: Type "Go" if you want me to start implementing.' ;;
        5) next="build $scope: translate its wave table onto the board (board_add with plan: I<n>) and dispatch; when every step of $scope is boarded and merged, set the header to Stage 6 (verifying $scope); after Stage 7: $after7" ;;
        6) next="verify $scope: run every 'verified by: agent' criterion for $scope for real, tick it with the command and its result, then set the header to Stage 7 (no \"Go\" needed)" ;;
        7) next="user-test $scope: start the watcher, hand the 'verified by: user' criteria of $scope to the user and wait (their ticks are their report); when they confirm: $after7" ;;
        *) next="" ;;
      esac
      if [ "$go_recorded" = 1 ]; then
        [ "$stage" = "4" ] && next+=" — the user already said Go: write Stage 5 and start"
        [ "$stage" = "3" ] && next+=" — the user already said Go: write the implementation plan"
      fi
      echo "  next: $next"
    fi
  fi
fi
[ -f "$d/.state/plugin-root" ] && echo "Plugin scripts: $(cat "$d/.state/plugin-root")/hooks/  (CLAUDE_PLUGIN_ROOT is NOT set in your shell — use this absolute path)"
exit 0
