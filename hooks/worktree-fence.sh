#!/usr/bin/env bash
# Worker fence (PreToolUse on the file tools): a worker (tl-*, or any agent whose dispatch carried `board: N`) may only write
# under its own cwd. With isolation: worktree the cwd IS the worktree; without it
# the cwd is the project, and "never write outside the project" is still right.
#
# Registered in hooks.json, not agent frontmatter: verified 2026-09-16 that
# frontmatter hooks do not fire for plugin workers on this path, while hooks.json
# hooks do. Identity comes from agent_id/agent_type, which Phase 0 confirmed are
# present on worker tool calls — so the lead (no agent_id) is never fenced and may
# still write plan files and the board.
#
# Claude Code's own worktree isolation already refuses writes into the shared
# checkout; this closes the rest (anywhere else on disk).
#
# Allowed, in the order checked: the worker's own cwd; this session's scratchpad;
# the project root (non-git project, or a git worker that is NOT in a linked
# worktree — it may have inherited a subdirectory cwd); and any ABSOLUTE (or ~)
# path in the `owns` of its own board row. That last one is the sanctioned
# exception (#7): if the lead boards an out-of-project dir as the task's write
# scope, the worker may write there. The row is found by the `worker` id that
# record.sh stores on it (PostToolUse(Agent), from the brief's `board: N`).
# Relative owns entries are inside the worktree already and grant nothing here (a
# relative `hooks/` never opens the main checkout). A match on an absolute entry
# answers with an explicit allow, so Claude Code skips its own permission prompt too.
#
# Bash is NOT fenced, deliberately (#7). A write target cannot be reliably read out
# of arbitrary shell (cd, variables, quoting, scripts that write on their own), so a
# heuristic would refuse harmless commands and still miss real ones, and the fence
# would claim a guarantee it cannot keep. The refusal message therefore says it
# plainly: Bash is no way round, and the exception is `owns`.
set -uo pipefail
in=$(cat)
j() { jq -r "$1 // empty" <<<"$in" 2>/dev/null; }
[ -n "$(j .agent_id)" ] || exit 0                 # the lead is not a worker
# Namespaced when installed as a plugin: "teamlead:tl-sonnet-low". GH#21: any other agent
# type is a worker too when its dispatch carried `board: N` (lib.sh tl_worker_tracked reads
# the ids record.sh stored in the main checkout's .state); every other agent is not fenced.
source "$(dirname "$0")/lib.sh"
main_state() {   # the main checkout's .state, resolved from a linked worktree like lib.sh does
  local bp="${CLAUDE_PROJECT_DIR:-$(j .cwd)}" common
  if common=$(git -C "$bp" rev-parse --git-common-dir 2>/dev/null); then
    case "$common" in /*) ;; *) common="$bp/$common" ;; esac
    bp=$(cd "$(dirname "$common")" 2>/dev/null && pwd) || bp="${CLAUDE_PROJECT_DIR:-$(j .cwd)}"
  fi
  printf '%s' "$bp/.claude/teamlead/.state"
}
case "$(j .agent_type)" in
  tl-*|*:tl-*) ;;
  *) tl_worker_tracked "$(j .agent_type)" "$(j .agent_id)" "$(main_state)" || exit 0 ;;
esac
cwd=$(j .cwd); fp=$(j .tool_input.file_path); [ -n "$fp" ] || fp=$(j .tool_input.notebook_path)
[ -n "$cwd" ] && [ -n "$fp" ] || exit 0

case "$fp" in /*) ;; *) fp="$cwd/$fp" ;; esac   # relative paths are relative to the worker's cwd
root=$(realpath -m "$cwd"); target=$(realpath -m "$fp")
sid=$(j .session_id)
# The session scratchpad is where the harness tells agents to put temp files.
# Allowing it costs nothing — nothing there is project state — while the repo
# itself stays fully fenced. Scoped to THIS session's own tree
# (/tmp/claude-<uid>/<project-slug>/<session_id>/...) when we know the session
# id, so one worker can't write into another session's scratchpad. Without a
# session id on the event (older harness / synthetic call) fall back to the
# old broad rule rather than blocking every scratchpad write outright.
case "$target" in
  "$root"/*)                 exit 0 ;;
esac
if [ -n "$sid" ]; then
  case "$target" in
    /tmp/claude-*/*/"$sid"/*) exit 0 ;;
  esac
else
  case "$target" in
    /tmp/claude-*/*)          exit 0 ;;
  esac
fi
# --- slow path: only reached when the cheap rules above did not allow the write ---
proj_env="${CLAUDE_PROJECT_DIR:-$cwd}"
# Project root a non-worktree worker may write anywhere under. A linked worktree
# (git-dir != git-common-dir) gets none: the main checkout stays off limits.
anchor=""
if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
  gd=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  cd_=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
  case "$cd_" in /*) ;; *) cd_="$cwd/$cd_" ;; esac
  [ "$(realpath -m "$gd")" = "$(realpath -m "$cd_")" ] && anchor=$(realpath -m "$top")
else
  pe=$(realpath -m "$proj_env")
  case "$root" in "$pe"|"$pe"/*) anchor="$pe" ;; esac     # non-git: cwd inside the project dir
fi
if [ -n "$anchor" ] && [ "$anchor" != / ]; then
  case "$target" in "$anchor"/*) exit 0 ;; esac
fi

# An owned path outside the worktree is a grant from the lead, so it also answers
# Claude Code's own permission prompt (a background worker cannot answer one): emit
# an explicit allow. Per the hooks docs, allow skips the prompt, but deny/ask rules
# are still evaluated regardless of what the hook returns. Not emitted for the plain
# in-worktree / scratchpad / project-root passes above: those already work, and an
# allow there would mask Claude Code's normal behaviour.
owned_ok() {
  jq -n --arg n "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",
    permissionDecisionReason:("teamlead: path is in board row " + $n + "'"'"'s owns")}}'
  exit 0
}

# Absolute entries of this worker's own board row(s). The board lives in the MAIN
# checkout, so resolve that from a linked worktree the way lib.sh does.
aid=$(j .agent_id); bp="$proj_env"
if common=$(git -C "$bp" rev-parse --git-common-dir 2>/dev/null); then
  case "$common" in /*) ;; *) common="$bp/$common" ;; esac
  bp=$(cd "$(dirname "$common")" 2>/dev/null && pwd) || bp="$proj_env"
fi
board="$bp/.claude/teamlead/.state/board.json"
if [ -f "$board" ]; then
  while IFS=$'\t' read -r bid o; do
    case "$o" in "~") o="$HOME" ;; "~/"*) o="$HOME/${o#\~/}" ;; esac
    case "$o" in /*) ;; *) continue ;; esac               # relative: inside the worktree already
    o=$(realpath -m "$o"); [ "$o" != / ] || continue       # never a blank cheque
    case "$o" in
      *[\*\?\[]*) case "$target" in $o) owned_ok "$bid" ;; esac ;;  # glob entry
      *)          case "$target" in "$o"|"$o"/*) owned_ok "$bid" ;; esac ;;
    esac
  done < <(jq -r --arg a "$aid" '.tasks[]? | select(.worker == $a and .state != "merged") | .id as $i | .owns[]? | "\($i)\t\(.)"' "$board" 2>/dev/null)
fi

jq -n --arg t "$target" --arg r "$root" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
  permissionDecisionReason:("Worker fence: you may only write inside your own worktree (" + $r + "). Refused: " + $t + ". Bash writes are not checked, but the same rule applies: do not route around this with cp, tee, a script or any other shell write. If the task genuinely needs this path, ask the lead for it with a SCOPE REQUEST: SendMessage to \"main\" with the lines `SCOPE REQUEST: <path or glob>`, `why: <one line>`, `row: <N>` (keep working on anything else until it answers `granted`), or, if you are blocked, end your turn with a hand-back whose report starts with that block. The lead can add it to the row'"'"'s owns, and then it is yours to write.")}}'
exit 0
