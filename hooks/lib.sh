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

tl_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Append one event line. Short appends are atomic, so concurrent workers
# returning at once cannot clobber each other.
tl_event() {
  mkdir -p "$TL_STATE"
  printf '%s  %s\n' "$(tl_now)" "$*" >> "$TL_EVENTS"
}

# Block the turn with a message (Stop/PreToolUse deny both read stderr).
tl_block() { printf '%s\n' "$*" >&2; exit 2; }
