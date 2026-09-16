#!/usr/bin/env bash
# Worker fence (PreToolUse on the file tools): a tl-* worker may only write
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
# checkout; this closes the rest (anywhere else on disk). Bash is not parsed —
# this catches the file tools, the brief covers the rest.
set -uo pipefail
in=$(cat)
j() { jq -r "$1 // empty" <<<"$in" 2>/dev/null; }
[ -n "$(j .agent_id)" ] || exit 0                 # the lead is not a worker
# Namespaced when installed as a plugin: "teamlead:tl-sonnet-low".
case "$(j .agent_type)" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
cwd=$(j .cwd); fp=$(j .tool_input.file_path); [ -n "$fp" ] || fp=$(j .tool_input.notebook_path)
[ -n "$cwd" ] && [ -n "$fp" ] || exit 0

case "$fp" in /*) ;; *) fp="$cwd/$fp" ;; esac   # relative paths are relative to the worker's cwd
root=$(realpath -m "$cwd"); target=$(realpath -m "$fp")
# The session scratchpad is where the harness tells agents to put temp files.
# Allowing it costs nothing — nothing there is project state — while the repo
# itself stays fully fenced.
case "$target" in
  "$root"/*)                 exit 0 ;;
  /tmp/claude-*/*)           exit 0 ;;
esac
jq -n --arg t "$target" --arg r "$root" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
  permissionDecisionReason:("Worker fence: you may only write inside your own worktree (" + $r + "). Refused: " + $t + ". If the task genuinely needs this, stop and report it to the lead instead.")}}'
exit 0
