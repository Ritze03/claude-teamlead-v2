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
#
# SPEED. Claude Code cancels an in-flight status line run whenever a newer update
# fires (debounced ~300 ms). On a network share this script took 1-1.5 s (git plus
# three board.py runs, each re-reading board.json), so with agents streaming every
# run was cancelled before it printed and the segment never showed. So the
# foreground run only PRINTS A CACHE (.state/statusline.cache: a couple of tiny
# reads, no git, no python) and, if that is stale, starts a detached refresh of
# this same script that does the real work. TEAMLEAD_STATUSLINE_SYNC=1 computes
# inline instead (tests, debugging).
set -uo pipefail
REFRESH=${TEAMLEAD_STATUSLINE_REFRESH:-}   # set only on the detached child: the root to refresh

if [ -n "$REFRESH" ]; then
  root="$REFRESH"            # the child has no stdin; the parent already resolved this
else
  in=$(cat 2>/dev/null)
  proj=$(printf '%s' "$in" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
  [ -n "$proj" ] || proj=$PWD

  # Resolve a worktree back to the main checkout so a worker's pane reads the same.
  # Best-effort: teamlead supports non-git projects, so a git failure must fall
  # through to the plain cwd rather than silence the segment. Skipped when the cwd
  # is itself an active project: git over a network share is slow, and the common
  # case needs none of it.
  root="$proj"
  if [ ! -f "$proj/.claude/teamlead/.state/active" ] \
     && common=$(git -C "$proj" rev-parse --git-common-dir 2>/dev/null); then
    case "$common" in /*) ;; *) common="$proj/$common" ;; esac
    r=$(cd "$(dirname "$common")" 2>/dev/null && pwd) && root="$r"
  fi
fi

d="$root/.claude/teamlead"
[ -f "$d/.state/active" ] || exit 0

c() { printf '\033[38;5;%sm%s\033[0m' "$1" "$2"; }   # 256-colour, reset after
TEAL=44; DIM=244; AMBER=214; RED=203; PLUM=176

cache="$d/.state/statusline.cache"
lock="$d/.state/statusline.lock"
# mtime in epoch seconds, 0 if absent. GNU stat, else BSD: the -e guard matters
# because GNU `stat -f` is a different (filesystem) mode that prints junk.
mt()  { stat -c %Y "$1" 2>/dev/null || { [ -e "$1" ] && stat -f %m "$1" 2>/dev/null; } || echo 0; }
now() { printf -v "$1" '%(%s)T' -1 2>/dev/null || printf -v "$1" '%s' "$(date +%s)"; }

# --- foreground: print the cache, refresh behind it ---------------------------
if [ -z "$REFRESH" ] && [ -z "${TEAMLEAD_STATUSLINE_SYNC:-}" ]; then
  { seg=$(<"$cache"); } 2>/dev/null
  [ -n "${seg:-}" ] || seg=$(c $TEAL '⚑ teamlead')   # first run: plain flag until the cache lands
  printf '%s' "$seg"
  now t
  if [ $((t - $(mt "$cache"))) -ge 2 ]; then
    # Fully detached — own session, no inherited fds — so Claude Code neither
    # waits on it (an open stdout pipe would hold the status line open) nor kills
    # it when it cancels this run. Single-flight is the child's job.
    if command -v setsid >/dev/null 2>&1; then
      TEAMLEAD_STATUSLINE_REFRESH="$root" setsid -f bash "${BASH_SOURCE[0]}" </dev/null >/dev/null 2>&1
    else
      TEAMLEAD_STATUSLINE_REFRESH="$root" nohup bash "${BASH_SOURCE[0]}" </dev/null >/dev/null 2>&1 &
    fi
  fi
  exit 0
fi

# --- refresh: one at a time per project ---------------------------------------
# A PID file, not flock: flock is unreliable on CIFS/NFS. The O_EXCL create is the
# atomic step; a holder that is dead, or older than 30 s (a hung board.py), is
# taken over. An empty file is a holder mid-write, not a stale one.
if [ -n "$REFRESH" ]; then
  acquire() { ( set -C; echo $$ > "$lock" ) 2>/dev/null; }
  if ! acquire; then
    lp=$(cat "$lock" 2>/dev/null); now t
    if { [ -z "$lp" ] || kill -0 "$lp" 2>/dev/null; } && [ $((t - $(mt "$lock"))) -lt 30 ]; then
      exit 0
    fi
    rm -f "$lock"; acquire || exit 0
  fi
  tmp="$cache.$$"
  trap 'rm -f "$lock" "$tmp"' EXIT
fi

seg=$(c $TEAL '⚑ teamlead')

# --- planning mode -----------------------------------------------------------
# The plan file's own stage header is the truth. .state/active-plan is only a
# pointer and nothing used to clear it, so a stale one would pin the indicator on
# forever — drop it here when it dangles or the plan has reached handoff.
ap="$d/.state/active-plan"
if [ -f "$ap" ]; then
  pf=$(cat "$ap" 2>/dev/null)
  if [ -n "$pf" ] && [ -f "$pf" ]; then
    hdr=$(grep -m1 -i -E '^> \*\*Stage [0-9]+\*\*' "$pf" 2>/dev/null)
    stage=$(printf '%s' "$hdr" | grep -oE '[0-9]+' | head -1)
    # No upper cutoff: the plan stays active through building and both testing
    # stages. Dropping it at stage 5 is what used to leave the session dangling —
    # implementation would start and the mode would quietly vanish, so a plan that
    # was not actually finished looked like no plan at all. Only archiving ends it.
    if [ -n "$stage" ] && [ "$stage" -ge 1 ] && [ "$stage" -le 7 ]; then
      # Label keyed on the stage NUMBER, not the header prose. The two can
      # disagree — a stage bumped without rewording leaves a stale description —
      # and the number is the structured half.
      case "$stage" in
        1) em="💬"; desc="picking the topic" ;;
        2) em="📄"; desc="open it in your editor" ;;
        3) em="📝"; desc="working it out" ;;
        4) em="📋"; desc="implementation plan" ;;
        5) em="🔨"; desc="building it" ;;
        6) em="🧪"; desc="verifying" ;;
        7) em="🙋"; desc="your turn to test" ;;
      esac
      # "Planning" only reads right for the first four; after that the plan is
      # being executed and checked, and the label should say so.
      [ "$stage" -le 4 ] && what="$em Planning" || what="$em Plan"
      seg+=" $(c $PLUM "$what: $(basename "$pf" .md) · stage $stage/7 $desc")"
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
      # The two stages that are finished and waiting on you specifically.
      [ "$stage" = "4" ] && seg+=" $(c $AMBER 'Go ⏎')"
      [ "$stage" = "7" ] && seg+=" $(c $AMBER 'Your turn ⏎')"
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

if [ -n "$REFRESH" ]; then
  printf '%s' "$seg" > "$tmp" && mv -f "$tmp" "$cache"   # atomic: a reader never sees half
else
  printf '%s' "$seg"
fi
