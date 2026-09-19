#!/usr/bin/env bash
# Retire a finished plan: datestamp it into plan/done/, clear the pointer, stop
# the watcher. Never deletes — a plan is the record of why the work looks like it
# does, and that outlives the work.
#
#   plan-archive.sh <plan-file> [--project DIR] [--abandon]
#
# Refuses a plan with unticked 'Done when' boxes: "confirm before retiring" is the
# whole point, and a rule that lives only in the skill text erodes. --abandon is the
# way out for a plan that was dropped rather than finished, and says so in the name.
set -uo pipefail
plan="${1:-}"; shift || true
proj="$PWD"; abandon=""
while [ $# -gt 0 ]; do case "$1" in
  --project) proj="$2"; shift 2 ;;
  --abandon) abandon=1; shift ;;
  *) shift ;;
esac; done
[ -f "$plan" ] || { echo "plan-archive: no such plan: $plan" >&2; exit 1; }

# Resolve a worktree to the main checkout, same rule as everything else.
if c=$(git -C "$proj" rev-parse --git-common-dir 2>/dev/null); then
  case "$c" in /*) ;; *) c="$proj/$c" ;; esac
  r=$(cd "$(dirname "$c")" 2>/dev/null && pwd) && proj="$r"
fi
state="$proj/.claude/teamlead/.state"
dest="$proj/.claude/teamlead/plan/done"
mkdir -p "$dest"

# A finished plan has every box ticked. Unticked ones mean the confirmation step
# never happened — which is exactly when a plan gets quietly filed away and the
# leftover work is lost.
if [ -z "$abandon" ]; then
  dw=$(awk '/^## Done when/{o=1;next} /^## /{o=0} o' "$plan")
  open=$(printf '%s' "$dw" | grep -cE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]') || open=0
  done_=$(printf '%s' "$dw" | grep -cE '^[[:space:]]*-[[:space:]]*\[[^[:space:]]\]') || done_=0
  if [ "$open" -gt 0 ]; then
    echo "plan-archive: $open of $((open+done_)) 'Done when' item(s) are still unticked." >&2
    printf '%s' "$dw" | grep -E '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' >&2
    echo "Confirm them first, or pass --abandon if this plan was dropped." >&2
    exit 1
  fi
  if [ "$done_" -eq 0 ]; then
    echo "plan-archive: no 'Done when' criteria — this plan was never confirmed finished." >&2
    echo "Add what must be true and verify it, or pass --abandon." >&2
    exit 1
  fi
fi

base=$(basename "$plan" .md)
[ -n "$abandon" ] && base="abandoned-$base"
out="$dest/$(date +%Y-%m-%d)-$base.md"
n=1; while [ -e "$out" ]; do n=$((n+1)); out="$dest/$(date +%Y-%m-%d)-$base-$n.md"; done

# Stop the watcher before moving the file out from under it.
pidf="$state/plan-watch.pid"
if [ -f "$pidf" ]; then
  wp=$(cat "$pidf" 2>/dev/null); [ -n "$wp" ] && kill "$wp" 2>/dev/null
  rm -f "$pidf"
fi

mv "$plan" "$out"
rm -f "$state/active-plan" "$state/plan-watch" "$state/plan-touched" \
      "$state/snap/$(basename "$plan")" 2>/dev/null

printf 'archived: %s\n' "$out"
