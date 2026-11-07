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

BOARD="${CLAUDE_PLUGIN_ROOT:-$HERE/..}/scripts/board.py"
src=$(tl_json .source)

# D5/F18: board.md must match board.json before state.sh reads open rows out of
# it (F18: state.sh greps board.md, not board.json) — so render runs on every
# source, compact included, before anything below reads the board. Only when a
# board already exists in some form: render on a wholly absent board would
# create an empty board.md for a project that never had one. A refusal (json
# missing/empty but md still holds rows) is left as-is; board.py check surfaces
# it via the gate — ignore render's own exit status here.
if [ -f "$TL_STATE/board.json" ] || [ -f "$TL_BOARD" ]; then
  python3 "$BOARD" render --project "$TL_PROJECT" >/dev/null 2>&1
fi

# Version tag from the installed plugin.json, read at runtime; silently omitted if unreadable.
tl_ver=$(jq -r '.version // empty' "${CLAUDE_PLUGIN_ROOT:-$HERE/..}/.claude-plugin/plugin.json" 2>/dev/null)
echo "[teamlead${tl_ver:+ v$tl_ver}] Active for this project. You are the lead: split work into .claude/teamlead/board.md, dispatch tl-* workers, never implement it yourself."

# D1: on startup/resume/clear (not compact — agents survive it) close out every
# outstanding worker whose start predates THIS session's own first event — no
# liveness probe, just "older than us and not started by us". The boundary is
# this session's earliest ledger line; before any exist (the usual case on
# startup) there is nothing of ours yet, so "now" is the boundary. No session_id
# means we can't tell whose workers they'd be, so skip rather than guess.
case "$src" in
  startup|resume|clear)
    sid=$(tl_json .session_id)
    if [ -n "$sid" ]; then
      boundary=$(grep -E "session=${sid}\$" "$TL_EVENTS" 2>/dev/null | head -1 | awk '{print $1}')
      [ -n "$boundary" ] || boundary=$(tl_now)
      fout=$(python3 "$BOARD" forget all --before "$boundary" --not-session "$sid" \
                     --project "$TL_PROJECT" 2>/dev/null)
      ids=$(printf '%s' "$fout" | jq -r '(.forgotten // []) | join(" ")' 2>/dev/null)
      if [ -n "$ids" ]; then
        n=$(printf '%s' "$ids" | wc -w | tr -d ' ')
        echo "[teamlead] Closed out $n worker(s) from a previous session: $ids — they never reported back."
      fi
    fi
    ;;
esac

# A /clear mid-plan throws away everything except the plan file and the board —
# they ARE the handoff. Only worth saying when there's a plan in flight past the
# point a fresh read of the file alone would make obvious what's happening.
if [ "$src" = "clear" ]; then
  ap="$TL_STATE/active-plan"
  if [ -f "$ap" ]; then
    pf=$(cat "$ap" 2>/dev/null)
    if [ -n "$pf" ] && [ -f "$pf" ]; then
      stage=$(grep -m1 -oiE '^> \*\*stage [0-9]+\*\*' "$pf" 2>/dev/null | grep -oE '[0-9]+')
      case "$stage" in
        5|6|7) echo "Session was cleared mid-plan — the plan file and the board are the whole handoff; read the plan, then continue from 'next'." ;;
      esac
    fi
  fi
fi

# A plan with a "## Handoff" section was left for exactly this: the lead wrote it
# before the user cleared (or the context compacted). Point at it by name, so the
# first thing read is the section that holds what chat did not.
case "$src" in
  clear|compact|resume)
    ap="$TL_STATE/active-plan"
    pf=$(cat "$ap" 2>/dev/null)
    if [ -n "$pf" ] && [ -f "$pf" ] && grep -qx '## Handoff' "$pf" 2>/dev/null; then
      hdr=$(grep -m1 -E '^> \*\*Stage [0-9]+\*\*' "$pf" 2>/dev/null)
      echo "[teamlead] Plan $pf — ${hdr:-no stage header}. It has a '## Handoff' section: read the whole plan file now, Handoff first, then board_list, before doing anything else."
    fi
    ;;
esac

# superdoc, wired projects only (CLAUDE.md carries `superdoc:start`; anything else is a repo
# that pays one grep here).
if tl_superdoc_wired "$TL_PROJECT"; then
  # Layer A of the leak guard: native git hooks (see lib.sh). Silent unless one cannot be installed.
  tl_install_superdoc_hooks

  # Audit reminder. Findings only fire where a script can decide; staleness it cannot, so a
  # periodic audit is the cover. N = 50 non-merge commits (this repo runs ~43 a month, so roughly
  # a month of work). The state is the commit of the last audit (the superdoc skill records it):
  # local and per clone, which is fine for a reminder. No file, or a commit that is not an
  # ancestor of HEAD (rewritten history, another branch): start counting from here, silently.
  case "$src" in
    startup|resume|clear)
      sd_head=$(git -C "$TL_PROJECT" rev-parse -q --verify HEAD 2>/dev/null)
      if [ -n "$sd_head" ]; then
        sd_last=$(cat "$TL_STATE/superdoc-audit" 2>/dev/null)
        if [ -z "$sd_last" ] || ! git -C "$TL_PROJECT" merge-base --is-ancestor "$sd_last" "$sd_head" 2>/dev/null; then
          mkdir -p "$TL_STATE" 2>/dev/null && printf '%s\n' "$sd_head" > "$TL_STATE/superdoc-audit" 2>/dev/null
        else
          sd_n=$(git -C "$TL_PROJECT" rev-list --count --no-merges "$sd_last..$sd_head" 2>/dev/null) || sd_n=0
          if [ "${sd_n:-0}" -gt 50 ]; then
            echo "[teamlead] superdoc: the last audit is $sd_n commits old. Run /teamlead superdoc (audit, then repair) when the current work allows. It is the agents' job: do not ask the user."
          fi
        fi
      fi
      ;;
  esac
fi

"$HERE/state.sh" "$TL_PROJECT"
