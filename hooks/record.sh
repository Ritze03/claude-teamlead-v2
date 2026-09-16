#!/usr/bin/env bash
# Ledger writer. The model never writes events.log — this does.
#
# PreToolUse(Agent) records the dispatch (it is the only event carrying the task
# description; SubagentStart has agent_id but no prompt).
# SubagentStop records the return, with the worker's own summary.
set -uo pipefail
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/hooks/lib.sh"
tl_init

ev=$(tl_json .hook_event_name)

case "$ev" in
  PreToolUse)
    [ "$(tl_json .tool_name)" = "Agent" ] || exit 0
    at=$(tl_json .tool_input.subagent_type)
    # ponytail: only our own workers. Verified in Phase 0 — the harness runs
    # internal agents with an empty agent_type, and counting those as teamlead
    # dispatches would corrupt every reconcile check.
    case "$at" in tl-*) ;; *) exit 0 ;; esac
    desc=$(tl_json .tool_input.description | tr '\n' ' ' | cut -c1-100)
    tl_event "dispatch  agent=$at  prompt=$(tl_json .prompt_id)  desc=$desc"
    ;;
  SubagentStop)
    at=$(tl_json .agent_type)
    case "$at" in tl-*) ;; *) exit 0 ;; esac
    msg=$(tl_json .last_assistant_message | tr '\n' ' ' | cut -c1-200)
    tl_event "return    agent=$at  id=$(tl_json .agent_id)  msg=$msg"
    ;;
esac
exit 0
