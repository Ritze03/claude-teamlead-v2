#!/usr/bin/env bash
# Close out one finished worker's leftovers: stop what it left running, remove its
# worktree, delete its branch. Run by the lead after the work is accepted/merged.
#
#   worker-cleanup.sh <worktree-path> [--project DIR]
#
# A worker's Monitors and run_in_background shells run with cwd = its worktree, so
# "a process whose /proc/<pid>/cwd is inside the worktree" finds them without
# needing their task ids. The calling shell and its ancestors are never touched, and
# nothing outside the worktree is. TERM, a short wait, then KILL.
# Then `git worktree remove` (never --force: uncommitted or untracked work refuses)
# and `git branch -d` (refuses an unmerged branch). Any refusal exits 1 with the reason.
# A git lock on the worktree is lifted only when it is Claude Code's own agent lock
# ("claude agent agent-<id> (pid P start S)") and stale: P is dead (or its start time,
# field 22 of /proc/P/stat, differs from S) or the ledger no longer lists <id> as working, or its latest
# ledger event is a pause (idling on background work, not mid-edit).
# Claude records the lead's pid, so a worker that stopped with background work pending
# leaves a lock that looks live for the whole session. Any other lock is never touched.
set -uo pipefail
wt="${1:-}"; shift || true
proj="$PWD"
while [ $# -gt 0 ]; do case "$1" in
  --project) proj="$2"; shift 2 ;;
  *) shift ;;
esac; done
die() { echo "worker-cleanup: $*" >&2; exit 1; }
[ -n "$wt" ] && [ -d "$wt" ] || die "no such worktree directory: ${wt:-<none>}"
wt=$(cd "$wt" && pwd -P) || die "cannot enter $wt"

# Main checkout: the worktree's own git-common-dir, so --project is only a fallback.
c=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || die "$wt is not a git work tree"
case "$c" in /*) ;; *) c="$wt/$c" ;; esac
main=$(cd "$(dirname "$c")" 2>/dev/null && pwd -P) || main=$(cd "$proj" && pwd -P) || die "cannot resolve the main checkout"
[ "$wt" != "$main" ] || die "$wt is the main checkout, not a linked worktree — refusing"
git -C "$main" worktree list --porcelain | grep -qxF "worktree $wt" \
  || die "$wt is not a registered worktree of $main"
branch=$(git -C "$wt" symbolic-ref --short -q HEAD || true)

# 1. stop whatever still runs inside the worktree.
python3 - "$wt" <<'PY' || exit 1
import os, signal, sys, time
wt = sys.argv[1]

def cwd_of(pid):
    try:
        p = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None                   # gone, a zombie, or not ours to read
    if p.endswith(" (deleted)"):      # its directory was removed under it
        p = p[:-len(" (deleted)")]
    return p

def inside(p):
    return p == wt or p.startswith(wt + "/")

def protected():
    keep, pid = set(), os.getpid()
    while pid > 1 and pid not in keep:
        keep.add(pid)
        try:
            pid = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return keep

def found():
    keep = protected()
    return [int(d) for d in os.listdir("/proc")
            if d.isdigit() and int(d) not in keep and (c := cwd_of(d)) and inside(c)]

def cmd(pid):
    try:
        return open(f"/proc/{pid}/cmdline").read().replace("\0", " ").strip()[:80] or "?"
    except OSError:
        return "?"

def send(pids, sig, label):
    for pid in pids:
        c = cmd(pid)
        try:
            os.kill(pid, sig)
            print(f"worker-cleanup: {label} pid {pid}: {c}")
        except ProcessLookupError:
            pass
        except PermissionError:
            print(f"worker-cleanup: cannot signal pid {pid} (not ours): {c}", file=sys.stderr)

pids = found()
send(pids, signal.SIGTERM, "TERM")
for _ in range(20):
    time.sleep(0.1)
    pids = found()
    if not pids:
        break
send(pids, signal.SIGKILL, "KILL")
if pids:
    time.sleep(0.3)
left = found()
if left:
    print("worker-cleanup: still running in the worktree: "
          + ", ".join(f"{p} ({cmd(p)})" for p in left), file=sys.stderr)
    sys.exit(1)
PY

# 1b. a git lock. Claude Code locks an agent's worktree as "claude agent agent-<id>
# (pid P start S)" (P = the session process, S = its /proc/P/stat starttime) and
# normally unlocks it when the agent ends; a worker that stopped with background work
# registered can leave it behind. Lift only that lock, and only when it is stale.
lock=$(git -C "$main" worktree list --porcelain | awk -v w="worktree $wt" '
  $0==w {f=1; next} /^worktree /{f=0} f && /^locked/ {print; exit}')
if [ -n "$lock" ]; then
  lock=${lock#locked}; lock=${lock# }
  verdict=$(python3 - "$lock" "$main" "$(dirname "${BASH_SOURCE[0]}")/board.py" <<'PY'
import json, re, subprocess, sys
reason, main, board = sys.argv[1:4]
m = re.fullmatch(r"claude agent (?:agent-)?(\S+) \(pid (\d+) start (\d+)\)", reason.strip())
if not m:
    print("foreign")
    sys.exit()
aid, pid, start = m.groups()
try:
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    alive = f[0] != "Z" and f[19] == start      # field 22 overall = starttime
except (OSError, IndexError):
    alive = False
if not alive:
    print("stale")                              # session process gone (or pid reused)
    sys.exit()
try:
    out = subprocess.run([sys.executable, board, "ledger", "--project", main],
                         capture_output=True, text=True, check=True).stdout
    working = {a.removeprefix("agent-") for a in json.loads(out)["outstanding"]}
except Exception:
    print("unknown")                            # cannot ask the ledger: assume running
    sys.exit()
if aid not in working:
    print("stale")
    sys.exit()
# Outstanding, but a worker whose latest event is a pause is idling on its background
# job (step 1 just killed it), not mid-edit: the lead is closing it out, so it is stale.
last = None
try:
    for line in open(f"{main}/.claude/teamlead/.state/events.log", errors="replace"):
        parts = line.split(None, 1)
        if len(parts) == 2 and re.search(rf"(?:^|\s)id=(?:agent-)?{re.escape(aid)}(?:\s|$)", parts[1]):
            last = parts[1].split()[0]
except OSError:
    pass
print("stale" if last == "pause" else "running")
PY
)
  case "$verdict" in
    stale) git -C "$main" worktree unlock "$wt" || die "could not unlock $wt"
           echo "worker-cleanup: unlocked stale agent lock ($lock)" ;;
    running|unknown) die "worker still running — $wt is locked ($lock) and its agent is still working per the ledger. Not removed." ;;
    *) die "$wt is locked by something other than a Claude agent ($lock) — refusing to unlock it." ;;
  esac
fi

# 2. the worktree. No --force: git itself refuses uncommitted or untracked files.
if ! out=$(git -C "$main" worktree remove "$wt" 2>&1); then
  die "not removed — $(printf '%s' "$out" | tr '\n' ' '). Commit or discard its changes yourself, then rerun."
fi
echo "worker-cleanup: removed worktree $wt"

# 3. the branch. -d refuses one that is not merged into HEAD of the main checkout.
if [ -z "$branch" ]; then
  echo "worker-cleanup: worktree was on a detached HEAD — no branch to delete"
elif out=$(git -C "$main" branch -d "$branch" 2>&1); then
  echo "worker-cleanup: deleted branch $branch"
else
  die "branch $branch kept — $(printf '%s' "$out" | tr '\n' ' '). Merge it first (a squash merge needs a deliberate branch -D)."
fi
