#!/usr/bin/env bash
# SessionStart: put durable state back after a clear, compaction, or reopening
# the project. This is the fix for the actual reported failure — state lived in
# context, and context gets thrown away.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
tl_init
tl_pin_root
tl_ensure_gitignore
echo "[teamlead] Active for this project. You are the lead: split work into .claude/teamlead/board.md, dispatch tl-* workers, never implement it yourself."
"$HERE/state.sh" "$TL_PROJECT"
