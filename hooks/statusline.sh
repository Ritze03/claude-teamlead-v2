#!/usr/bin/env bash
# Teamlead status line segment.
#
# A plugin cannot install a MAIN status line — only the user's settings.json can,
# so this is opt-in and composes rather than replaces. Prints one segment, nothing
# else, and stays silent unless teamlead is active for the project.
#
# Design rule: a status line earns its space by CHANGING. Everything here is
# either always-relevant (mode) or normally absent (returned, blocked, ⚠), so the
# line stays short and grows exactly when something needs you.
set -uo pipefail
in=$(cat 2>/dev/null)
proj=$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
[ -n "$proj" ] || proj=$PWD

# Resolve a worktree back to the main checkout so a worker's pane reads the same.
# Best-effort: teamlead supports non-git projects, so a git failure must fall
# through to the plain cwd rather than silence the segment.
root="$proj"
if common=$(git -C "$proj" rev-parse --git-common-dir 2>/dev/null); then
  case "$common" in /*) ;; *) common="$proj/$common" ;; esac
  r=$(cd "$(dirname "$common")" 2>/dev/null && pwd) && root="$r"
fi

d="$root/.claude/teamlead"
[ -f "$d/.state/active" ] || exit 0

c() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }   # 256-colour, reset after
TEAL=44; DIM=244; AMBER=214; RED=203; PLUM=176

seg=$(c $TEAL '⚑ teamlead')

# --- planning mode -----------------------------------------------------------
# The plan file's own stage header is the truth. .state/active-plan is only a
# pointer and nothing used to clear it, so a stale one would pin the indicator on
# forever — drop it here when it dangles or the plan has reached handoff.
ap="$d/.state/active-plan"
if [ -f "$ap" ]; then
  pf=$(cat "$ap" 2>/dev/null)
  if [ -n "$pf" ] && [ -f "$pf" ]; then
    hdr=$(grep -m1 -E '^> \*\*Stage [0-9]+\*\*' "$pf" 2>/dev/null)
    stage=$(printf '%s' "$hdr" | grep -oE '[0-9]+' | head -1)
    if [ -n "$stage" ] && [ "$stage" -lt 5 ]; then
      # Label keyed on the stage NUMBER, not the header prose. The two can
      # disagree — a stage bumped without rewording leaves a stale description —
      # and the number is the structured half.
      case "$stage" in
        1) desc="picking the topic" ;;
        2) desc="open it in your editor" ;;
        3) desc="working it out" ;;
        4) desc="implementation plan" ;;
      esac
      seg+=" $(c $PLUM "📄 Planning: $(basename "$pf" .md) · stage $stage/5 $desc")"
      # 👀 = your edits will actually be picked up right now. The watcher stops
      # while the agent holds control, so its absence is real information.
      # Keyed on a PID the watcher publishes and clears on exit: a pgrep pattern
      # matched any command line mentioning the path (including the shell that
      # launched it), and a plain marker file would outlive a crash.
      pidf="$d/.state/plan-watch.pid"
      if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
        seg+=" $(c $PLUM '👀')"
      else
        rm -f "$pidf" 2>/dev/null      # watcher died; stop claiming otherwise
      fi
      # Stage 4 is finished and waiting on you specifically.
      [ "$stage" = "4" ] && seg+=" $(c $AMBER 'Go ⏎')"
    else
      rm -f "$ap"            # handed off to the board; stop claiming planning
    fi
  else
    rm -f "$ap"              # dangling pointer
  fi
fi

# --- board + workers ---------------------------------------------------------
pr=$(cat "$d/.state/plugin-root" 2>/dev/null)
if [ -n "$pr" ] && [ -f "$pr/scripts/board.py" ]; then
  read -r open running returned blocked out < <(
    python3 - "$pr" "$root" <<'PY' 2>/dev/null
import json, subprocess, sys
pr, root = sys.argv[1], sys.argv[2]
def run(*a):
    r = subprocess.run([sys.executable, pr + "/scripts/board.py", *a, "--project", root],
                       capture_output=True, text=True, timeout=10)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}
b, l = run("list"), run("ledger")
s = b.get("by_state", {})
print(b.get("open", 0), len(s.get("running", [])), len(s.get("returned", [])),
      len(s.get("blocked", [])), len(l.get("outstanding", [])) + l.get("pending", 0))
PY
  ) || { open=""; }
  [ -n "${open:-}" ] || { open=0 out=0 returned=0 blocked=0; }

  [ "${open:-0}" -gt 0 ] && seg+=" $(c $DIM '·') $open open"
  [ "${out:-0}" -gt 0 ]  && seg+=" $(c $DIM '·') $(c $TEAL "$out working")"
  # Returned = a worker came back and the lead has not acted. The window where
  # work used to evaporate, and the number most worth seeing.
  [ "${returned:-0}" -gt 0 ] && seg+=" $(c $DIM '·') $(c $AMBER "$returned returned")"
  [ "${blocked:-0}" -gt 0 ]  && seg+=" $(c $DIM '·') $(c $DIM "$blocked blocked")"

  # One character for "something is actually wrong": drift, a false merge, or two
  # unfinished tasks owning the same path.
  python3 "$pr/scripts/board.py" check --project "$root" >/dev/null 2>&1 || seg+=" $(c $RED '⚠')"
fi

printf '%s' "$seg"
