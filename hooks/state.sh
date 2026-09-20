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

      # watcher: deliberately off during 5-7 (execution/testing), so only
      # 2-4 (topic settled through implementation-plan) get the restart line.
      case "$stage" in
        2|3|4)
          pidf="$d/.state/plan-watch.pid"
          if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
            echo "  watcher: running (pid $(cat "$pidf"))"
          else
            root=$(cat "$d/.state/plugin-root" 2>/dev/null)
            [ -n "$root" ] || root="$(dirname "$0")/.."
            echo "  watcher: NOT running — restart it: $root/hooks/watch-plan.sh \"$proj\" \"$pf\"  (Monitor tool, timeout 1800000, then write the task id to .state/plan-watch)"
          fi
          ;;
        *) echo "  watcher: off (stages 5-7)" ;;
      esac

      case "$stage" in
        1) next="settle the topic and create the plan file" ;;
        2) next="show the path table, start the watcher, dispatch the scout" ;;
        3) next='answer the open questions with the user; end every turn with: Type "Go" if you want me to plan the implementation.' ;;
        4) next='wait for "Go"; end every turn with: Type "Go" if you want me to start implementing.' ;;
        5) next="translate the current phase's wave table onto the board (board_add with plan: I<n>) and dispatch; when every task is merged, set the header to Stage 6" ;;
        6) next="run every 'verified by: agent' criterion for real, tick it with the command and its result, then set the header to Stage 7" ;;
        7) next="hand the 'verified by: user' criteria to the user and wait; when they confirm, archive with plan-archive.sh" ;;
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
