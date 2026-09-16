#!/usr/bin/env bash
# Only the lead writes to the board.
#
# The MCP board tools are session-wide, so a worker can reach board_add /
# board_update as easily as the lead can. It must not: the board is the lead's
# record of what it has checked off, and a worker marking its own task merged
# would let work close itself without the lead ever looking at it.
#
# Workers report to the lead; the lead updates the board. Reading is allowed —
# only writes are refused.
set -uo pipefail
in=$(cat)
j() { jq -r "$1 // empty" <<<"$in" 2>/dev/null; }

[ -n "$(j .agent_id)" ] || exit 0                 # the lead has no agent_id
tool=$(j .tool_name)
case "$tool" in
  *board_add*|*board_update*) ;;
  *) exit 0 ;;                                    # board_list is fine
esac

jq -n --arg t "$tool" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
  permissionDecisionReason:("Only the lead writes to the board (" + $t + " refused). Report your result to the lead instead — including what you changed, how, and anything it needs to verify — and the lead will update the board.")}}'
exit 0
