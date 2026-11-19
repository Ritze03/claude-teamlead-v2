#!/usr/bin/env bash
# PostToolUse (Edit|Write|MultiEdit): the lead's own edit of the active plan.
#
# Two duties used to be the lead's, by hand, after every plan write (GH#27):
#   1. refresh .state/snap/<file>, so the watcher / mode.sh do not report the lead's
#      own edit as the user's. A multi-Edit fold takes longer than the watcher's 2 s
#      settle delay, so the watcher fired between the first Edit and the manual cp.
#   2. run plan-lint.
# Both now run inside the same tool call that wrote the file. Lint failures go back
# to the model as additionalContext; `plan-lint: ok` stays silent.
#
# Only the lead: a subagent has an agent_id (same test as board-fence.sh), and a
# worker's edit is not a plan edit. Any other file is untouched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
tl_init

case "$(tl_json .tool_name)" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac
[ -z "$(tl_json .agent_id)" ] || exit 0

[ -f "$TL_STATE/active-plan" ] || exit 0
plan_path=$(cat "$TL_STATE/active-plan" 2>/dev/null)
fp=$(tl_json .tool_input.file_path)
[ -n "$plan_path" ] && [ -n "$fp" ] || exit 0
[ "$(realpath -m "$plan_path" 2>/dev/null)" = "$(realpath -m "$fp" 2>/dev/null)" ] || exit 0
[ -f "$plan_path" ] || exit 0

mkdir -p "$TL_STATE/snap" 2>/dev/null
cp "$plan_path" "$TL_STATE/snap/$(basename "$plan_path")" 2>/dev/null

out=$("$HERE/plan-lint.sh" "$plan_path" 2>&1) && exit 0
jq -n --arg c "$out" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
