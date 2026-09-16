#!/usr/bin/env bash
# UserPromptSubmit. Owns activation, deactivation, and the per-turn reminder.
#
# Activation lives here, not in the skill body: skill-body `!` shell only runs on
# an explicit namespaced slash invocation, so a description-matched load would
# silently start the mode with no flag and no state. Hooks always run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

IN=$(cat)
TL_PROJECT="${CLAUDE_PROJECT_DIR:-$(tl_json .cwd)}"
[ -n "$TL_PROJECT" ] || exit 0
TL_DIR="$TL_PROJECT/.claude/teamlead"; TL_STATE="$TL_DIR/.state"
TL_BOARD="$TL_DIR/board.md"; TL_EVENTS="$TL_STATE/events.log"

p=$(tl_json .prompt | tr '[:upper:]' '[:lower:]')

case "$p" in
  *"stop teamlead"*|*"normal mode"*|*"/teamlead stop"*)
    [ -f "$TL_STATE/active" ] || exit 0
    rm -f "$TL_STATE/active"
    echo "Teamlead deactivated for this project. Print: ❌ TEAMLEAD DEACTIVATED"
    exit 0 ;;
esac

if [ ! -f "$TL_STATE/active" ]; then
  case "$p" in
    "/teamlead"*|*"teamlead mode"*|*"act as teamlead"*|*"as a team lead"*|*"teamlead orchestrat"*)
      mkdir -p "$TL_STATE"
      : > "$TL_STATE/active"
      tl_pin_root
      # Seed the board. A model handed an empty prompt invents its own format;
      # handed an existing table, it fills in rows. Cheaper than enforcing prose.
      [ -f "$TL_BOARD" ] || cat > "$TL_BOARD" <<'BOARD'
# Board

| ✓ | ID | Task | Agent | Owns | State | Branch |
|:-:|:--:|------|-------|------|-------|--------|

## Done
BOARD
      echo "TEAMLEAD ACTIVATED for this project (persists across sessions until 'stop teamlead'). Print: ✅ TEAMLEAD ACTIVATED"
      "$HERE/state.sh" "$TL_PROJECT"
      exit 0 ;;
    *) exit 0 ;;
  esac
fi

tl_pin_root

# Baseline for the Decompose gate: what the tree looked like when this turn
# started, and when the board was last touched. Compared at Stop.
if git -C "$TL_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$TL_PROJECT" status --porcelain 2>/dev/null \
    | grep -v '\.claude/teamlead/' > "$TL_STATE/turn-baseline" || true
fi
# Nanoseconds: second granularity misses a board updated in the same second
# the turn started, which is the common case.
if [ -f "$TL_BOARD" ]; then date -r "$TL_BOARD" +%s%N > "$TL_STATE/turn-board-mtime" 2>/dev/null || true
else echo 0 > "$TL_STATE/turn-board-mtime"; fi

# Active. ponytail: say nothing when there is nothing to say.
[ -f "$TL_BOARD" ] || exit 0
open=$(grep -cE '^\| +\|' "$TL_BOARD" 2>/dev/null) || open=0
[ "$open" -eq 0 ] && exit 0
d=$(grep -c '  dispatch  ' "$TL_EVENTS" 2>/dev/null) || d=0
r=$(grep -c '  return    ' "$TL_EVENTS" 2>/dev/null) || r=0
echo "[teamlead] board.md: $open open task(s), $((d - r)) worker(s) still out. You orchestrate; workers implement."
