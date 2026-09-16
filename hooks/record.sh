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

[ "$ev" = "PreToolUse" ] && [ "$(tl_json .tool_name)" = "SendMessage" ] && ev=PreToolUse_SendMessage

case "$ev" in
  PreToolUse)
    [ "$(tl_json .tool_name)" = "Agent" ] || exit 0
    at=$(tl_json .tool_input.subagent_type)
    # Only our own workers. The harness runs internal agents with an empty
    # agent_type, and counting those would corrupt every reconcile check.
    # Installed as a plugin the type is NAMESPACED ("teamlead:tl-sonnet-low"),
    # so a bare tl-* test silently matches nothing and the ledger stays empty.
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    desc=$(tl_json .tool_input.description | tr '\n' ' ' | cut -c1-100)
    tl_event "dispatch  agent=$at  prompt=$(tl_json .prompt_id)  desc=$desc"
    ;;
  # A resumed worker never fires PreToolUse(Agent), so the retry ladder — which
  # works by resuming the SAME worker for its one correction — was invisible to the
  # ledger. outstanding read 0 while a worker was genuinely running, exactly when
  # tracking matters most. The lead diagnosed this itself: "the gate's worker count
  # doesn't track resumed agents".
  PreToolUse_SendMessage)
    to=$(tl_json .tool_input.to)
    [ -n "$to" ] || exit 0
    # Only count it if that id is one of ours, i.e. it appears in our own ledger.
    grep -q "id=$to" "$TL_EVENTS" 2>/dev/null || exit 0
    sm=$(tl_json .tool_input.summary | tr '\n' ' ' | cut -c1-100)
    tl_event "resume    id=$to  summary=$sm"
    ;;
  SubagentStart)
    at=$(tl_json .agent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    tl_event "start     agent=$at  id=$(tl_json .agent_id)"
    ;;
  SubagentStop)
    at=$(tl_json .agent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    msg=$(tl_json .last_assistant_message | tr '\n' ' ' | cut -c1-200)
    tl_event "return    agent=$at  id=$(tl_json .agent_id)  msg=$msg"
    ;;
esac
exit 0
