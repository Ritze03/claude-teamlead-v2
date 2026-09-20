#!/usr/bin/env bash
# PreToolUse (Edit|Write|MultiEdit): guard the active plan's own stage header.
#
# The lead used to bump "> **Stage N**" by hand and nothing checked it. This
# enforces the three rules that make the header trustworthy again:
#   1. one stage at a time — no skipping ahead in a single edit
#   2. 3->4 and 4->5 need a recorded user "Go" newer than the last accepted
#      bump ($TL_STATE/plan-go, written by mode.sh — contract, not our file)
#   3. '## Notes from me' (D23) is the user's inbox — the lead may delete a
#      folded line there, never add or reword one
#
# Only acts on the file that IS the active plan; everything else is untouched.
# Backwards moves and same-stage edits are always fine. A brand-new plan file
# (Write to a path that doesn't exist yet) is never blocked — there is no
# "before" to compare against — it just seeds $TL_STATE/plan-stage.
#
# ponytail: "after this edit, what would the file say" is computed in python3
# (already a dependency via scripts/board.py) rather than hand-rolled in bash.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
tl_init

case "$(tl_json .tool_name)" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

[ -f "$TL_STATE/active-plan" ] || exit 0
plan_path=$(cat "$TL_STATE/active-plan" 2>/dev/null)
[ -n "$plan_path" ] || exit 0

fp=$(tl_json .tool_input.file_path)
[ -n "$fp" ] || exit 0

# realpath -m resolves even a path that doesn't exist yet (the fresh-Write case).
plan_real=$(realpath -m "$plan_path" 2>/dev/null) || exit 0
target_real=$(realpath -m "$fp" 2>/dev/null) || exit 0
[ "$plan_real" = "$target_real" ] || exit 0

tool=$(tl_json .tool_name)

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",
    permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Materialize what the file would say after this edit. Never crash on odd
# input: any failure here (bad JSON, missing fields, old_string not found,
# Edit/MultiEdit against a file that isn't there) -> allow silently, same as
# a parse failure anywhere else in this hook.
after_content() {
  PF_IN="$IN" python3 - "$1" "$2" <<'PY'
import json, os, sys

tool, target = sys.argv[1], sys.argv[2]

def apply_edit(text, old_s, new_s, replace_all):
    if old_s == new_s:
        return text
    if replace_all:
        return text.replace(old_s, new_s)
    i = text.find(old_s)
    if i == -1:
        raise ValueError("old_string not found")
    return text[:i] + new_s + text[i + len(old_s):]

try:
    data = json.loads(os.environ.get("PF_IN", ""))
    ti = data.get("tool_input") or {}
    if tool == "Write":
        new = ti["content"]
    else:
        with open(target, "r") as f:
            old = f.read()
        if tool == "Edit":
            new = apply_edit(old, ti.get("old_string", ""), ti.get("new_string", ""),
                              bool(ti.get("replace_all", False)))
        elif tool == "MultiEdit":
            new = old
            for e in ti.get("edits") or []:
                new = apply_edit(new, e.get("old_string", ""), e.get("new_string", ""),
                                  bool(e.get("replace_all", False)))
        else:
            sys.exit(1)
    sys.stdout.write(new)
except Exception:
    sys.exit(1)
PY
}

stage_of() { grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' <<<"$1" | grep -oE '[0-9]+'; }

# '## Notes from me' body: the heading to the next '## ' heading, or EOF.
notes_of() {
  awk '/^## Notes from me/{o=1;next} /^## /{o=0} o' <<<"$1"
}

record_stage() { printf '%s %s\n' "$1" "$(tl_now)" > "$TL_STATE/plan-stage"; }

if [ ! -f "$target_real" ]; then
  new_content=$(after_content "$tool" "$target_real") || exit 0
  ns=$(stage_of "$new_content")
  [ -n "$ns" ] && record_stage "$ns"
  exit 0
fi

old_content=$(cat "$target_real" 2>/dev/null)
new_content=$(after_content "$tool" "$target_real") || exit 0

# --- D23: '## Notes from me' additions/rewording are refused ------------
old_notes=$(notes_of "$old_content")
new_notes=$(notes_of "$new_content")
new_notes_nonblank=$(grep -vE '^[[:space:]]*$' <<<"$new_notes" || true)
if [ -n "$new_notes_nonblank" ]; then
  while IFS= read -r line; do
    grep -qxF -- "$line" <<<"$old_notes" && continue
    deny "plan-fence: '## Notes from me' is the user's section — you may remove a folded note, never add or reword"
  done <<<"$new_notes_nonblank"
fi

# --- stage header: one step at a time, and a Go before 3->4 / 4->5 -------
old_stage=$(stage_of "$old_content")
new_stage=$(stage_of "$new_content")

if [ -n "$old_stage" ] && [ -n "$new_stage" ] && [ "$new_stage" -gt "$old_stage" ]; then
  if [ $((new_stage - old_stage)) -gt 1 ]; then
    deny "plan-fence: header may only advance one stage at a time (was $old_stage, edit sets $new_stage)"
  fi
  case "$old_stage-$new_stage" in
    3-4|4-5)
      last_bump=""
      [ -f "$TL_STATE/plan-stage" ] && last_bump=$(awk '{print $2}' "$TL_STATE/plan-stage")
      go_ok=0
      if [ -f "$TL_STATE/plan-go" ]; then
        while IFS=' ' read -r _ go_ts; do
          [ -n "$go_ts" ] || continue
          if [ -z "$last_bump" ] || [[ "$go_ts" > "$last_bump" ]]; then go_ok=1; fi
        done < "$TL_STATE/plan-go"
      fi
      [ "$go_ok" = 1 ] || deny "plan-fence: stage $old_stage→$new_stage needs a \"Go\" from the user first — none recorded since the last stage change"
      ;;
  esac
fi

[ -n "$new_stage" ] && [ "$new_stage" != "$old_stage" ] && record_stage "$new_stage"
exit 0
