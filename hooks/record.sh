#!/usr/bin/env bash
# Ledger writer. The model never writes events.log — this does.
#
# PreToolUse(Agent) records the dispatch (it is the only event carrying the task
# description; SubagentStart has agent_id but no prompt).
# SubagentStop records the return, with the worker's own summary — or a pause
# when the worker is only idling on its own background job (T65).
set -uo pipefail
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/hooks/lib.sh"
# tl_init's active-flag exit needs the event name first (F16), which needs $IN —
# so read it unconditionally here and re-check the flag ourselves below, once we
# know which event this is.
TL_NO_ACTIVE_CHECK=1 tl_init

# D12: hook logic lives in board.py subcommands; record.sh only parses JSON and
# calls them. Same plugin-root fallback restore.sh uses to locate board.py.
BOARD="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/scripts/board.py"

# D1: a board.py refusal (bad id, blocked-by gate, …) must be visible to the
# lead, never swallowed — but it must not fail the hook itself, or a dispatch
# or a return would be blocked by a board disagreement. So: run it, keep only
# stderr (idiom: `2>&1 >/dev/null` inside the substitution), and on a non-zero
# exit print it to the hook's own stderr plus one ledger line. $2 (board id)
# may be empty for the non-PostToolUse callers below — that is fine, the
# warn line just carries board= empty.
tl_board_call() {
  local aid="$1" bid="$2" err rc
  shift 2
  err=$(python3 "$BOARD" "$@" --project "$TL_PROJECT" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[teamlead] board: $err" >&2
    tl_event "warn      board-refused  id=$aid  board=$bid  msg=$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-100)"
  fi
}

# T65: is this SubagentStop a pause rather than the worker's final return?
# Final = its last tool call is SubagentHandback, the harness tool a worker
# delivers its report with. Only judged when the harness offers that tool (its
# reminder or tool definition is in the transcript); no transcript, unreadable,
# or an older harness without SubagentHandback → final (exit 1), as before.
# $1 is agent_transcript_path — the worker's own; transcript_path is the lead's.
tl_worker_paused() {
  [ -n "$1" ] && [ -r "$1" ] || return 1
  python3 - "$1" <<'PY'
import json, re, sys
offered, last = False, None
try:
    for line in open(sys.argv[1], errors="replace"):
        if "delivered through SubagentHandback" in line or re.search(r'"name":\s*"SubagentHandback"', line):
            offered = True
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("type") == "assistant":
            for b in (o.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    last = b.get("name")
except Exception:
    sys.exit(1)     # anything unparseable reads as final — the old behaviour
sys.exit(0 if offered and last != "SubagentHandback" else 1)
PY
}

ev=$(tl_json .hook_event_name)

if [ ! -f "$TL_STATE/active" ]; then
  # F16: a worker can finish after teamlead was deactivated mid-run. Its
  # SubagentStop still needs recording, or it stays "outstanding" in the ledger
  # forever until `forget`. Every other event stays gated on the flag as before.
  aid=$(tl_json .agent_id)
  # Ledger lines are two-space-separated key=value tokens, so id=$aid must be
  # anchored to the whole token (followed by two spaces or end-of-line) —
  # otherwise id=w1 substring-matches id=w10.
  if [ "$ev" = "SubagentStop" ] && [ -n "$aid" ] \
     && { grep -qE "  start .*  id=$aid(  |$)" "$TL_EVENTS" 2>/dev/null \
          || grep -qE "  resume .*  id=$aid(  |$)" "$TL_EVENTS" 2>/dev/null; } \
     && ! grep -qE "  return .*  id=$aid(  |$)" "$TL_EVENTS" 2>/dev/null; then
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
  # D3: the Agent tool's response carries the brief, the worker id AND
  # tool_input.isolation in one payload — the deterministic pairing PreToolUse
  # alone cannot give (it fires before the id exists).
  PostToolUse)
    [ "$(tl_json .tool_name)" = "Agent" ] || exit 0
    at=$(tl_json .tool_input.subagent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    # tool_response is normally the object {status, agentId, description, prompt}
    # (verified in this project's own transcript). Fall back to hunting an
    # "agentId: X" substring in its text form for any other shape.
    aid=$(tl_json .tool_response.agentId)
    [ -n "$aid" ] || aid=$(tl_json .tool_response | grep -oE 'agentId: [A-Za-z0-9_-]+' | head -1 | awk '{print $2}')
    if [ -z "$aid" ]; then
      # .tool_response may itself be wrapped in an object ({content: …} or
      # {content:[{text: …}]}) instead of a plain string — check its shape
      # once and look inside for the id text.
      case "$(tl_json '.tool_response | type')" in
        object)
          txt=$(tl_json .tool_response.content)
          [ -n "$txt" ] || txt=$(tl_json '.tool_response.content[0].text')
          aid=$(printf '%s' "$txt" | grep -oE 'agentId: [A-Za-z0-9_-]+' | head -1 | awk '{print $2}')
          ;;
      esac
    fi
    if [ -z "$aid" ]; then
      tl_event "warn      no-agent-id  desc=$(tl_json .tool_input.description | tr '\n' ' ' | cut -c1-100)"
      exit 0
    fi
    # The board-row marker is a line of its own, anywhere in the brief. No
    # marker → no board call: a scout, a QC pass, or any brief not tied to a row.
    bid=$(tl_json .tool_input.prompt | grep -oE '^board: [0-9]+$' | head -1 | awk '{print $2}')
    [ -n "$bid" ] || exit 0
    br=""
    [ "$(tl_json .tool_input.isolation)" = "worktree" ] && br="worktree-agent-$aid"
    tl_board_call "$aid" "$bid" worker-start --id "$aid" --board "$bid" ${br:+--branch "$br"}
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
    # D12: whether a SendMessage resume also fires SubagentStart is unverified;
    # both calls are no-ops when nothing matches, so wire both — cheap cover
    # for whichever the harness actually fires.
    tl_board_call "$to" "" worker-start --id "$to"
    ;;
  SubagentStart)
    at=$(tl_json .agent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    sfx=""; sid=$(tl_json .session_id); [ -n "$sid" ] && sfx="  session=$sid"
    tl_event "start     agent=$at  id=$(tl_json .agent_id)$sfx"
    # D12: the resume path — a fresh dispatch's row is already 'running' (or
    # has no worker yet) via PostToolUse, so this is a harmless no-op then.
    tl_board_call "$(tl_json .agent_id)" "" worker-start --id "$(tl_json .agent_id)"
    ;;
  SubagentStop)
    at=$(tl_json .agent_type)
    case "$at" in tl-*|*:tl-*) ;; *) exit 0 ;; esac
    # T65: a worker idling on its own run_in_background job fires SubagentStop
    # too — that is a pause, not a return. The transcript is written async (hooks
    # docs), so a pause verdict is re-read once before it sticks.
    tp=$(tl_json .agent_transcript_path)
    if tl_worker_paused "$tp" && { sleep 1; tl_worker_paused "$tp"; }; then
      tl_event "pause     agent=$at  id=$(tl_json .agent_id)"
      exit 0
    fi
    msg=$(tl_json .last_assistant_message | tr '\n' ' ' | cut -c1-200)
    tl_event "return    agent=$at  id=$(tl_json .agent_id)  msg=$msg"
    tl_board_call "$(tl_json .agent_id)" "" worker-stop --id "$(tl_json .agent_id)"
    ;;
esac
exit 0
