#!/usr/bin/env bash
# Live plan-file watch. Run via the Monitor tool, which times out after ~30min;
# the lead must re-arm it by starting this script again when that happens.
# Linux/inotify only.
# Each stdout line becomes a notification, so only emit on a real change.
#
#   watch-plan.sh <project-dir> <plan-file.md>
#
# Two rules that are not obvious and both matter:
#  1. Watch the DIRECTORY. vim and VS Code save by writing a temp file and
#     renaming over the target, which replaces the inode — a watch on the file
#     silently stops working after the first save.
#  2. Never stop this to edit. Stopping opens a window where a user save is
#     clobbered AND generates no notification — exactly the failure this exists
#     to catch. Instead the echo is suppressed by content: the lead updates the
#     snapshot after its own writes, so its own saves look identical and are
#     silent. A 2s settle delay closes the write-then-snapshot race and
#     collapses autosave bursts at the same time.
set -uo pipefail
proj="${1:?project dir}"; plan="${2:?plan file}"
dir=$(dirname "$plan"); base=$(basename "$plan")
snap="$proj/.claude/teamlead/.state/snap/$base"
mkdir -p "$(dirname "$snap")"
# ALWAYS re-baseline at startup. Whatever the file says right now is, by
# definition, not a user edit. Keeping a stale snapshot across a restart would
# replay everything written while the watcher was off — the agent's own stage-4
# plan — as the user's first change.
cp "$plan" "$snap" 2>/dev/null || : > "$snap"

# Publish our PID so the status line can tell, truthfully, whether edits are being
# watched right now. Removed on exit, so a crashed watcher stops claiming to run.
pidf="$proj/.claude/teamlead/.state/plan-watch.pid"
mkdir -p "$(dirname "$pidf")"
# Never allow two watchers to run at once (D2). A second start used to leave the
# first inotifywait alive alongside the new one, so every change got reported
# twice with no way to tell which watcher "owns" the pid file. Kill any live
# previous watcher and wait for it to actually exit (its EXIT trap removes the
# pid file and kills its inotifywait child, but that happens asynchronously)
# before we publish our own pid below.
if [ -f "$pidf" ]; then
  oldpid=$(cat "$pidf" 2>/dev/null)
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    kill -TERM "$oldpid" 2>/dev/null
    for _ in $(seq 1 50); do
      kill -0 "$oldpid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$oldpid" 2>/dev/null && kill -KILL "$oldpid" 2>/dev/null
  fi
fi
printf '%s\n' "$$" > "$pidf"
# (trap installed below, once the child exists)

command -v inotifywait >/dev/null 2>&1 || {
  echo "plan-watch: inotify-tools is required (Linux only, by design)"; exit 1; }

# Run the watch loop in the background and wait on it. A foreground pipeline that
# never ends defers every trap, so a TERM'd watcher would stay alive holding its
# pid file and keep claiming to watch. `wait` is interruptible, so the trap fires
# at once and takes the pipeline down with it.
watch_loop() {
inotifywait -m -q -e close_write,moved_to --format '%f' "$dir" | while read -r f; do
  [ "$f" = "$base" ] || continue
  # Settle before comparing. The lead writes the file and then updates the
  # snapshot; without this pause inotify fires in between and its own edit
  # looks like a user edit. Waiting also collapses autosave bursts.
  sleep 2
  cmp -s "$plan" "$snap" && continue     # unchanged: our own write, or a repeat save
  # A save is the one unambiguous sign the user has the file open and is using
  # it. Opening cannot be detected — IN_OPEN fires for every tool that reads the
  # file, including our own linter, and carries no PID.
  : > "$proj/.claude/teamlead/.state/plan-touched"
  echo "--- $base changed on disk ---"
  diff -u "$snap" "$plan" | tail -n +3 | head -40
  "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/hooks/plan-lint.sh" "$plan" 2>&1 | grep -v '^plan-lint: ok$' || true
  cp "$plan" "$snap"
done
}

watch_loop &
child=$!
# Order matters (D2): killing $child first lets its own children (inotifywait,
# the pipeline's while-loop subshell) get orphaned and reparented away before
# pkill -P "$child" ever looks for them, so it finds nothing and the
# inotifywait survives as an orphan. Kill the grandchildren first, while they
# are still parented under $child, then kill $child itself.
trap 'rm -f "$pidf"; pkill -P "$child" 2>/dev/null; kill "$child" 2>/dev/null; exit 0' EXIT INT TERM
wait "$child"
