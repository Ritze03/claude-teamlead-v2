#!/usr/bin/env bash
# UserPromptSubmit. Owns activation, deactivation, and the per-turn reminder.
#
# Activation lives here, not in the skill body: skill-body `!` shell only runs on
# an explicit namespaced slash invocation, so a description-matched load would
# silently start the mode with no flag and no state. Hooks always run.
#
# Activation/deactivation match ONLY the literal slash command, never a phrase
# anywhere in the prompt: a subagent's result or a file-watcher diff quoting
# "stop teamlead" arrives through this same hook and used to kill the mode.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

IN=$(cat)
TL_PROJECT="${CLAUDE_PROJECT_DIR:-$(tl_json .cwd)}"
[ -n "$TL_PROJECT" ] || exit 0
TL_DIR="$TL_PROJECT/.claude/teamlead"; TL_STATE="$TL_DIR/.state"
TL_BOARD="$TL_DIR/board.md"; TL_EVENTS="$TL_STATE/events.log"

# Lowercased and trimmed: exact-match checks below must ignore case and any
# leading/trailing whitespace the client adds around a typed slash command.
p=$(tl_json .prompt | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

case "$p" in
  "/teamlead stop"|"/teamlead:teamlead stop")
    [ -f "$TL_STATE/active" ] || exit 0
    rm -f "$TL_STATE/active"
    echo "Teamlead deactivated for this project. Print: ❌ TEAMLEAD DEACTIVATED"
    exit 0 ;;
esac

if [ ! -f "$TL_STATE/active" ]; then
  case "$p" in
    "/teamlead"*)
      mkdir -p "$TL_STATE"
      : > "$TL_STATE/active"
      tl_pin_root
      tl_ensure_gitignore
      # Seed through the script: board.json is the truth, board.md is rendered.
      [ -f "$TL_STATE/board.json" ] || \
        python3 "${CLAUDE_PLUGIN_ROOT:-$HERE/..}/scripts/board.py" render --project "$TL_PROJECT" >/dev/null 2>&1
      echo "TEAMLEAD ACTIVATED for this project (persists across sessions until '/teamlead stop'). Print: ✅ TEAMLEAD ACTIVATED"
      "$HERE/state.sh" "$TL_PROJECT"
      exit 0 ;;
    *) exit 0 ;;
  esac
fi

tl_pin_root
tl_ensure_gitignore

# D16: record "Go" against the active plan's current stage. Other hooks
# (plan-fence.sh, gate.sh, state.sh) read $TL_STATE/plan-go for this exact
# "<stage> <ISO-8601 UTC timestamp>" line format — do not change the shape.
if [ "$p" = "go" ] && [ -f "$TL_STATE/active-plan" ]; then
  plan=$(cat "$TL_STATE/active-plan")
  if [ -f "$plan" ]; then
    stage=$(grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' "$plan" | grep -oE '[0-9]+')
    if [ -n "$stage" ]; then
      # F21/D7: "first Go" is judged BEFORE the append below adds this one.
      first_go=1; [ -s "$TL_STATE/plan-go" ] && first_go=0
      printf '%s %s\n' "$stage" "$(tl_now)" >> "$TL_STATE/plan-go"
      # watch-plan.sh:72 marks plan-touched on the first user save it sees. No
      # mark by the first recorded Go means the user typed Go having only ever
      # seen the lead's own edits — worth one nudge, not a repeat on every Go.
      if [ "$first_go" -eq 1 ] && [ ! -f "$TL_STATE/plan-touched" ]; then
        echo "[teamlead] First Go recorded, but the plan file was never edited by you — answer in the file or in chat if anything in it is wrong."
      fi
    fi
  fi
fi

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

# Re-inject routing whenever settings change (or were written after activation,
# which is the first-run case: at activation settings.md did not exist yet, so the
# state block said MISSING and the lead had no resolved names for the rest of the
# session — and invented them).
if [ -f "$TL_DIR/settings.md" ]; then
  shown="$TL_STATE/routing-shown"
  if [ ! -f "$shown" ] || [ "$TL_DIR/settings.md" -nt "$shown" ]; then
    "$HERE/resolve.sh" "$TL_PROJECT"
    touch "$shown"
  fi
fi

echo "[teamlead] Concise output style is active for what you say to the USER: lead with the result, skip preamble and narration. It does NOT apply to dispatch briefs — those stay thorough, carrying every piece of your context the worker would otherwise rediscover."

# Active. ponytail: say nothing when there is nothing to say.
[ -f "$TL_STATE/board.json" ] || exit 0
open=$(python3 "${CLAUDE_PLUGIN_ROOT:-$HERE/..}/scripts/board.py" list --project "$TL_PROJECT" 2>/dev/null \
       | python3 -c 'import json,sys; print(json.load(sys.stdin)["open"])' 2>/dev/null) || open=0
[ "${open:-0}" -eq 0 ] && exit 0
# Paired by agent id, same as the gate. Counting dispatches against returns
# drifts on a resumed worker (no dispatch) and a killed one (no return), so this
# line used to disagree with the gate about how many workers were live.
nw=$(python3 "${CLAUDE_PLUGIN_ROOT:-$HERE/..}/scripts/board.py" ledger --project "$TL_PROJECT" 2>/dev/null \
     | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d["outstanding"])+d.get("pending",0))' 2>/dev/null) || nw=0
echo "[teamlead] board.md: $open open task(s), ${nw:-0} worker(s) working. You orchestrate; workers implement."
