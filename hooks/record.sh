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

# T76: background Bash tasks the worker launched and never closed. Parses the
# worker's own transcript (same file tl_worker_paused reads): every
# "Command running in background with ID: X. Output is being written to: P" is a
# launch; X is closed again by a terminal <task-notification> (completed|failed|
# killed), by its own TaskStop ("Successfully stopped task: X" / "Task X is not
# running"), or — kept on purpose, reap only — by being named in its final report
# (TL_MSG = last_assistant_message, plus the SubagentHandback input), which is
# how a worker is told to flag a job it was asked to leave running.
#   $1 = list | reap   $2 = agent_transcript_path
# list: prints the open ids, comma-separated. reap: also signals the processes
# holding each open task's .output as stdout/stderr (the task shell, plus anything
# it spawned that inherited it) and their descendants, then prints "<ids> <npids>".
# Monitors are NOT covered: a Monitor's stdout is a pipe to the harness, not its
# .output file, and the transcript records no pid or path for it, so there is
# nothing reliable to match (they self-expire at their timeout).
# Never signals this hook or its ancestors, nor another uid's processes. Any
# parse error prints nothing and kills nothing.
tl_worker_open() {
  [ -n "$2" ] && [ -r "$2" ] || return 0
  python3 - "$1" "$2" <<'PY'
import json, os, re, signal, sys, time
mode, tp = sys.argv[1], sys.argv[2]
try:
    launched, closed, handback = {}, set(), []
    launch = re.compile(r"Command running in background with ID: (\w+)\. Output is being written to: (/\S+?\.output)")
    notif = re.compile(r"<task-id>(\w+)</task-id>(?:(?!<task-id>).){0,800}?<status>(completed|failed|killed)</status>", re.S)
    for line in open(tp, errors="replace"):
        for m in notif.finditer(line):
            closed.add(m.group(1))
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        blocks = (o.get("message") or {}).get("content")
        if not isinstance(blocks, list):
            continue
        for b in blocks:
            if not isinstance(b, dict):
                continue
            if o.get("type") == "assistant" and b.get("type") == "tool_use" and b.get("name") == "SubagentHandback":
                handback.append(json.dumps(b.get("input")))
            if o.get("type") == "user" and b.get("type") == "tool_result":
                c = b.get("content")
                t = c if isinstance(c, str) else " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
                for m in launch.finditer(t):
                    launched[m.group(1)] = m.group(2)
                for m in re.finditer(r"Successfully stopped task: (\w+)|Task (\w+) is not running", t):
                    closed.add(m.group(1) or m.group(2))
    report = os.environ.get("TL_MSG", "") + " " + " ".join(handback)
    if mode == "reap":     # a pause lists every open id; only a return honours "named = keep"
        closed |= {i for i in launched if re.search(r"(?<!\w)" + re.escape(i) + r"(?!\w)", report)}
    ids = [i for i in launched if i not in closed]
except Exception:
    sys.exit(0)
if not ids:
    sys.exit(0)
if mode != "reap":
    print(",".join(ids)); sys.exit(0)
try:
    want = {launched[i] for i in ids}
    uid, ppid, hit = os.getuid(), {}, set()
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        pid = int(d)
        try:
            if os.stat(f"/proc/{pid}").st_uid != uid:
                continue
            ppid[pid] = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        for fd in (1, 2):
            try:
                if os.readlink(f"/proc/{pid}/fd/{fd}") in want:
                    hit.add(pid)
            except OSError:
                pass
    keep, pid = set(), os.getpid()      # this process and every ancestor (incl. claude)
    while pid > 1 and pid not in keep:
        keep.add(pid)
        try:
            pid = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    todo, grew = set(hit), True
    while grew:                          # descendants of the matches
        grew = False
        for p, pp in ppid.items():
            if pp in todo and p not in todo:
                todo.add(p); grew = True
    todo -= keep
    def alive(p):
        try:
            return open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[0] != "Z"
        except (OSError, IndexError):
            return False
    def send(ps, sig):
        for p in ps:
            try:
                os.kill(p, sig)
            except OSError:
                pass
    send(todo, signal.SIGTERM)
    end = time.time() + 0.8
    while time.time() < end and any(alive(p) for p in todo):
        time.sleep(0.05)
    send([p for p in todo if alive(p)], signal.SIGKILL)
    print(",".join(ids), len(todo))
except Exception:
    sys.exit(0)
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
      # T76: name the background tasks it is idling on (nothing is killed here).
      open=$(tl_worker_open list "$tp")
      tl_event "pause     agent=$at  id=$(tl_json .agent_id)${open:+  open=$open}"
      exit 0
    fi
    msg=$(tl_json .last_assistant_message | tr '\n' ' ' | cut -c1-200)
    tl_event "return    agent=$at  id=$(tl_json .agent_id)  msg=$msg"
    tl_board_call "$(tl_json .agent_id)" "" worker-stop --id "$(tl_json .agent_id)"
    # T76: a real return — stop the background tasks it launched and left open.
    # Inline, and after the recording above so a failure here can never lose it:
    # one python pass over /proc plus a <=0.8s TERM->KILL wait fits the 5s budget
    # even after the pause recheck's 1s, so no detaching is needed.
    reaped=$(TL_MSG=$(tl_json .last_assistant_message) tl_worker_open reap "$tp") || reaped=""
    set -- $reaped
    [ "${2:-0}" -gt 0 ] && tl_event "reap      agent=$at  id=$(tl_json .agent_id)  tasks=$1  pids=$2"
    ;;
esac
exit 0
