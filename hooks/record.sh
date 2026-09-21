#!/usr/bin/env bash
# Ledger writer. The model never writes events.log — this does.
#
# PreToolUse(Agent) records the dispatch (it is the only event carrying the task
# description; SubagentStart has agent_id but no prompt).
# SubagentStop records the return, with the worker's own summary.
set -uo pipefail
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/hooks/lib.sh"
# tl_init's active-flag exit needs the event name first (F16), which needs $IN —
# so read it unconditionally here and re-check the flag ourselves below, once we
# know which event this is.
TL_NO_ACTIVE_CHECK=1 tl_init

ev=$(tl_json .hook_event_name)

if [ ! -f "$TL_STATE/active" ]; then
  # F16: a worker can finish after teamlead was deactivated mid-run. Its
  # SubagentStop still needs recording, or it stays "outstanding" in the ledger
  # forever until `forget`. Every other event stays gated on the flag as before.
  aid=$(tl_json .agent_id)
  if [ "$ev" = "SubagentStop" ] && [ -n "$aid" ] \
     && { grep -q "  start.*id=$aid" "$TL_EVENTS" 2>/dev/null \
          || grep -q "  resume.*id=$aid" "$TL_EVENTS" 2>/dev/null; } \
     && ! grep -q "  return.*id=$aid" "$TL_EVENTS" 2>/dev/null; then
    :   # outstanding for this worker — fall through and record the stop below
  else
    exit 0
  fi
fi

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
    # D1: tag with the hook's session_id where present, appended last so
    # board.py's `id=`/`agent=` field parsing is unaffected.
    sfx=""; sid=$(tl_json .session_id); [ -n "$sid" ] && sfx="  session=$sid"
    tl_event "resume    id=$to  summary=$sm$sfx"
    ;;
  SubagentStart)
    at=$(tl_json .agent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    sfx=""; sid=$(tl_json .session_id); [ -n "$sid" ] && sfx="  session=$sid"
    tl_event "start     agent=$at  id=$(tl_json .agent_id)$sfx"
    ;;
  SubagentStop)
    at=$(tl_json .agent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    msg=$(tl_json .last_assistant_message | tr '\n' ' ' | cut -c1-200)
    tl_event "return    agent=$at  id=$(tl_json .agent_id)  msg=$msg"
    ;;
esac
exit 0
