#!/usr/bin/env bash
# Board writes are refused in two situations.
#
# 1. Only the lead writes to the board. The MCP board tools are session-wide,
#    so a worker can reach board_add / board_update as easily as the lead
#    can. It must not: the board is the lead's record of what it has checked
#    off, and a worker marking its own task merged would let work close
#    itself without the lead ever looking at it. Workers report to the lead;
#    the lead updates the board.
#
# 2. board_add specifically, while a plan is active and its header stage is
#    below 5: tasks don't belong on the board until the plan has cleared its
#    second "Go" (stage 5). Before that the plan itself is the record of what
#    is being built — board_update stays open throughout (closing out a task
#    that WAS already on the board, e.g. from before this plan, is fine).
#
# Reading is allowed — only writes are refused.
set -uo pipefail
in=$(cat)
j() { jq -r "$1 // empty" <<<"$in" 2>/dev/null; }

tool=$(j .tool_name)
case "$tool" in
  *board_add*|*board_update*) ;;
  *) exit 0 ;;                                    # board_list is fine
esac

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:$r}}'
  exit 0
}

if [ -n "$(j .agent_id)" ]; then                  # the lead has no agent_id
  deny "Only the lead writes to the board ($tool refused). Report your result to the lead instead — including what you changed, how, and anything it needs to verify — and the lead will update the board."
fi

case "$tool" in
  *board_add*)
    proj="${CLAUDE_PROJECT_DIR:-$(j .cwd)}"
    [ -n "$proj" ] || exit 0
    ap="$proj/.claude/teamlead/.state/active-plan"
    if [ -f "$ap" ]; then
      plan=$(cat "$ap" 2>/dev/null)
      if [ -n "$plan" ] && [ -f "$plan" ]; then
        st=$(grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' "$plan" | grep -oE '[0-9]+')
        if [ -n "$st" ] && [ "$st" -lt 5 ]; then
          deny "board-fence: the active plan is at stage $st — tasks go on the board at stage 5, after the user's second \"Go\""
        fi
      fi
    fi
    ;;
esac

exit 0
