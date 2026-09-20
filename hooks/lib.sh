#!/usr/bin/env bash
# Shared helpers for teamlead hooks. Sourced, never executed.
#
# Every hook starts by reading its stdin JSON into $IN and calling tl_init.
# tl_init exits 0 immediately when teamlead is not active for this project,
# which is the common case and must cost nothing.

tl_json() { jq -r "$1 // empty" <<<"$IN" 2>/dev/null; }

tl_init() {
  IN=$(cat)
  # CLAUDE_PROJECT_DIR is not set for every event; fall back to the event's cwd.
  TL_PROJECT="${CLAUDE_PROJECT_DIR:-$(tl_json .cwd)}"
  [ -n "$TL_PROJECT" ] || exit 0
  TL_DIR="$TL_PROJECT/.claude/teamlead"
  TL_STATE="$TL_DIR/.state"
  # ponytail: the flag is the whole gate. No flag, no work, no tokens.
  [ -f "$TL_STATE/active" ] || exit 0
  TL_BOARD="$TL_DIR/board.md"
  TL_EVENTS="$TL_STATE/events.log"
}

# The lead's Bash tool does NOT get CLAUDE_PLUGIN_ROOT, but hooks do. Stash it so
# skills can locate plugin scripts via $(cat .../.state/plugin-root).
tl_pin_root() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 0
  mkdir -p "$TL_STATE" 2>/dev/null || return 0
  [ "$(cat "$TL_STATE/plugin-root" 2>/dev/null)" = "$CLAUDE_PLUGIN_ROOT" ] \
    || printf '%s\n' "$CLAUDE_PLUGIN_ROOT" > "$TL_STATE/plugin-root"
}

# Runtime state must never be committed. A worker running `git add -A` otherwise
# captures board.json onto its branch, and checking back to main deletes it — the
# board silently vanishes. Idempotent, so it is safe to call on every turn; it must
# NOT live only in the activation path, or a project activated by an older version
# never gets it.
tl_ensure_gitignore() {
  git -C "$TL_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local gi="$TL_PROJECT/.gitignore"
  # Ignore the whole teamlead directory, not just the runtime bits: a plan is
  # one person's working state, and a worker that finds a half-made plan
  # sitting in its worktree reads it as instructions.
  if [ -f "$gi" ]; then
    local tmp="$gi.tmp.$$"
    grep -vxF -e ".claude/teamlead/.state/" -e ".claude/teamlead/board.md" "$gi" > "$tmp" 2>/dev/null
    mv "$tmp" "$gi"
  fi
  grep -qxF ".claude/teamlead/" "$gi" 2>/dev/null || printf '%s\n' ".claude/teamlead/" >> "$gi"
}

tl_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Append one event line. Short appends are atomic, so concurrent workers
# returning at once cannot clobber each other.
tl_event() {
  mkdir -p "$TL_STATE"
  printf '%s  %s\n' "$(tl_now)" "$*" >> "$TL_EVENTS"
  # The gate reads this file every Stop, and it only ever grew. Keep the recent
  # tail live and roll the rest off; history nobody reads is not history.
  local n
  n=$(wc -l < "$TL_EVENTS" 2>/dev/null) || return 0
  if [ "${n:-0}" -gt 4000 ]; then
    tail -n 2000 "$TL_EVENTS" > "$TL_EVENTS.tmp" 2>/dev/null &&
      cat "$TL_EVENTS" >> "$TL_STATE/events.archive.log" 2>/dev/null &&
      mv "$TL_EVENTS.tmp" "$TL_EVENTS"
  fi
}

# Block the turn with a message (Stop/PreToolUse deny both read stderr).
tl_block() { printf '%s\n' "$*" >&2; exit 2; }
