#!/usr/bin/env bash
# Shared helpers for teamlead hooks. Sourced, never executed.
#
# Every hook starts by reading its stdin JSON into $IN and calling tl_init.
# tl_init exits 0 immediately when teamlead is not active for this project,
# which is the common case and must cost nothing.

tl_json() { jq -r "$1 // empty" <<<"$IN" 2>/dev/null; }

# Every hook that sources this runs board.py as the HOOK, not as a worker's Bash:
# board.py refuses CLI writes from a worker's worktree, and exempts only the
# hook-driven commands (worker-start/-stop, render, forget) when this is set. A
# worker's own Bash never has it. Exported at source time, so even a hook that
# exits early inherits it.
export TL_HOOK=1

tl_init() {
  IN=$(cat)
  # CLAUDE_PROJECT_DIR is not set for every event; fall back to the event's cwd.
  TL_PROJECT="${CLAUDE_PROJECT_DIR:-$(tl_json .cwd)}"
  [ -n "$TL_PROJECT" ] || exit 0
  # F5: fired from inside a worktree, cwd/CLAUDE_PROJECT_DIR point at the worktree,
  # not the main checkout where teamlead's state lives — resolve it the same way
  # statusline.sh and board.py's _main_checkout do, or the hook silently acts as
  # if teamlead were inactive. One git call, and only when the dir exists.
  if [ -d "$TL_PROJECT" ]; then
    local common
    if common=$(git -C "$TL_PROJECT" rev-parse --git-common-dir 2>/dev/null); then
      case "$common" in /*) ;; *) common="$TL_PROJECT/$common" ;; esac
      local r
      r=$(cd "$(dirname "$common")" 2>/dev/null && pwd) && TL_PROJECT="$r"
    fi
  fi
  TL_DIR="$TL_PROJECT/.claude/teamlead"
  TL_STATE="$TL_DIR/.state"
  TL_BOARD="$TL_DIR/board.md"
  TL_EVENTS="$TL_STATE/events.log"
  # ponytail: the flag is the whole gate. No flag, no work, no tokens.
  # F16: record.sh sets TL_NO_ACTIVE_CHECK to still catch a worker's SubagentStop
  # when teamlead was deactivated mid-run — every other hook keeps this exit
  # exactly as it was.
  [ -n "${TL_NO_ACTIVE_CHECK:-}" ] || [ -f "$TL_STATE/active" ] || exit 0
}

# The lead's Bash tool does NOT get CLAUDE_PLUGIN_ROOT, but hooks do. Stash it so
# skills can locate plugin scripts via $(cat .../.state/plugin-root).
tl_pin_root() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 0
  mkdir -p "$TL_STATE" 2>/dev/null || return 0
  [ "$(cat "$TL_STATE/plugin-root" 2>/dev/null)" = "$CLAUDE_PLUGIN_ROOT" ] \
    || printf '%s\n' "$CLAUDE_PLUGIN_ROOT" > "$TL_STATE/plugin-root"
}

# Per-user teamlead state must never be committed, because it breaks collaboration
# between teamlead users. Two directories are ignored, and only those two (never the
# whole `.claude/`, so settings.json, agents/ and commands/ stay shareable):
#   .claude/teamlead/  runtime state. A worker running `git add -A` otherwise
#                      captures board.json onto its branch, and checking back to
#                      main deletes it — the board silently vanishes.
#   .claude/worktrees/ where Claude Code puts the per-worker git worktrees of
#                      `isolation: worktree`. Unignored they show up as untracked
#                      nested repos and can be committed as embedded repos (gitlinks).
# Idempotent, so it is safe to call on every turn; it must NOT live only in the
# activation path, or a project activated by an older version never gets it.
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
  # F11/D7: exact-match only used to mean a pre-existing equivalent pattern
  # (".claude/", no trailing slash, a leading "/") got a redundant line appended
  # underneath it. A whole-.claude entry covers both directories.
  local pat d
  for pat in ".claude" ".claude/" "/.claude" "/.claude/"; do
    grep -qxF "$pat" "$gi" 2>/dev/null && return 0
  done
  # Otherwise check each directory on its own, in any of its common spellings,
  # and append only the missing one(s).
  for d in "teamlead" "worktrees"; do
    for pat in ".claude/$d" ".claude/$d/" "/.claude/$d" "/.claude/$d/"; do
      grep -qxF "$pat" "$gi" 2>/dev/null && continue 2
    done
    printf '%s\n' ".claude/$d/" >> "$gi"
  done
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

# ---- tracked workers (GH#21) --------------------------------------------------------------
# A "worker" is a tl-* agent (plugin-namespaced or not) OR any other agent type whose dispatch
# carried a `board: N` line: that line is the explicit opt-in, so a project-level custom agent
# (.claude/agents/my-worker.md pinning a model, say) gets the board link, ledger, base-guard
# note and worktree fence exactly like a tl-* worker. SubagentStart/Stop and the file-tool hooks
# see agent_type + agent_id but never the brief, so the brief's board line is carried over here:
#   PreToolUse(Agent)  tl_track_pend TYPE      one "<epoch> TYPE" line in .state/tracked-pending
#   SubagentStart      tl_track_claim TYPE ID  consumes the oldest fresh pending of TYPE, records ID
#   PostToolUse(Agent) pairs id and brief exactly (tl_track_add), whichever of the two fired first
# .state/tracked-workers holds the ids (one per line). tl_worker_tracked is the ONE test every
# gate uses, in place of the old `case "$at" in tl-*|*:tl-*)`.

# The board id of a brief: a `board: N` line of its own, anywhere in it. Prints N or nothing.
tl_brief_board() { printf '%s' "$1" | grep -oE '^board: [0-9]+$' | head -1 | awk '{print $2}'; }

# tl_worker_tracked TYPE ID [STATE_DIR]: 0 for a tl-* type or an id recorded as tracked.
tl_worker_tracked() {
  case "$1" in tl-*|*:tl-*) return 0 ;; esac
  [ -n "$2" ] && grep -qxF -- "$2" "${3:-$TL_STATE}/tracked-workers" 2>/dev/null
}

tl_track_add() {
  local f="$TL_STATE/tracked-workers"
  [ -n "$1" ] || return 0
  grep -qxF -- "$1" "$f" 2>/dev/null && return 0
  mkdir -p "$TL_STATE" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$f" 2>/dev/null || return 0
  if [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 500 ]; then      # bounded, newest kept
    tail -n 300 "$f" > "$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f"
  fi
  return 0
}

tl_track_pend() {
  mkdir -p "$TL_STATE" 2>/dev/null || return 0
  printf '%s %s\n' "$(date +%s)" "$1" >> "$TL_STATE/tracked-pending" 2>/dev/null || true
}

# tl_track_claim TYPE ID: 0 and ID recorded when a fresh (<=120s) pending entry of TYPE existed.
tl_track_claim() {
  local f="$TL_STATE/tracked-pending" now ts ty got="" tmp
  [ -n "$2" ] && [ -s "$f" ] || return 1
  now=$(date +%s); tmp="$f.tmp.$$"
  {
    flock 9 2>/dev/null
    : > "$tmp"
    while read -r ts ty; do
      case "$ts" in ''|*[!0-9]*) continue ;; esac
      [ $((now - ts)) -le 120 ] || continue
      if [ -z "$got" ] && [ "$ty" = "$1" ]; then got=1; continue; fi
      printf '%s %s\n' "$ts" "$ty" >> "$tmp"
    done < "$f"
    mv "$tmp" "$f"
    [ -n "$got" ] && tl_track_add "$2"
  } 9>"$TL_STATE/tracked.lock"
  [ -n "$got" ]
}

# Block the turn with a message (Stop/PreToolUse deny both read stderr).
tl_block() { printf '%s\n' "$*" >&2; exit 2; }

# Worker scratch lives in <worktree>/.tl-scratch/ and must never be committed.
# info/exclude sits in the git COMMON dir, so one line in the main checkout covers
# every linked worktree, and nothing tracked (.gitignore) changes. Idempotent, and
# silent on any failure: a missing git, a non-repo project or a read-only .git
# must never fail the hook that calls it.
tl_ensure_scratch_exclude() {
  local common ex
  common=$(git -C "$TL_PROJECT" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common" in /*) ;; *) common="$TL_PROJECT/$common" ;; esac
  ex="$common/info/exclude"
  grep -qxF ".tl-scratch/" "$ex" 2>/dev/null && return 0
  mkdir -p "$common/info" 2>/dev/null || return 0
  printf '%s\n' ".tl-scratch/" >> "$ex" 2>/dev/null || true
  return 0
}

# ---- superdoc enforcement helpers (gate.sh check 8, restore.sh, superdoc-guard.sh) -------------
# Everything superdoc does nothing unless CLAUDE.md carries the `superdoc:start` marker. An
# unmarked superdoc/ is hand-written docs someone else owns, so nothing blocks there, and a repo
# without superdoc pays one grep.
tl_superdoc_wired() { grep -q 'superdoc:start' "$1/CLAUDE.md" 2>/dev/null; }

tl_superdoc_lint() {
  printf '%s' "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/skills/teamlead-superdoc/lint.sh"
}

tl_superdoc_map() {
  printf '%s' "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/skills/teamlead-superdoc/map.py"
}

# tl_timeout SECONDS CMD...: GNU `timeout` when there is one, else just run it.
tl_timeout() {
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}

# Layer A: native git hooks. The primary cover for superdoc leaks, because git runs them for every
# commit, merge commit and push, from Claude's Bash or a human's terminal, and nothing has to
# parse shell text (see worktree-fence.sh for why shell text is not a reliable thing to fence on).
# Each hook is a small generated stub that carries TL_HOOK_MARK; it is re-written when its content
# differs (the plugin root changes with every installed version) and a hook WITHOUT the mark is
# never touched. With core.hooksPath set git does not read $GIT_COMMON_DIR/hooks at all, so
# nothing is installed. Every case that leaves a hook uninstalled prints ONE line saying which,
# so the lead knows superdoc-guard.sh (Layer B) is the only cover there. Silent on success.
TL_HOOK_MARK='# managed by teamlead'

tl_superdoc_stub() {  # pre-commit|pre-merge-commit|pre-push -> the stub's text on stdout
  local lint q
  lint=$(tl_superdoc_lint); q=${lint//\'/\'\\\'\'}
  printf '#!/bin/sh\n%s (superdoc leak check): regenerated at SessionStart, do not edit.\n' "$TL_HOOK_MARK"
  printf "LINT='%s'\n" "$q"
  printf '[ -f "$LINT" ] || { echo "teamlead: superdoc lint.sh not found, leak check skipped (plugin uninstalled?)" >&2; exit 0; }\n'
  case $1 in
    pre-push) cat <<'EOS'
# stdin: <local ref> <local sha> <remote ref> <remote sha>; $1 is the remote name.
rc=0
while read -r lref lsha rref rsha; do
  case $lsha in *[!0]*) ;; *) continue ;; esac          # all zeros: deleting a ref, nothing to scan
  case $rsha in
    *[!0]*) bash "$LINT" --range "$rsha..$lsha" >&2; r=$?
            [ "$r" = 2 ] && { bash "$LINT" --push "$lsha" "$1" >&2; r=$?; } ;;   # remote sha not local
    *)      bash "$LINT" --push "$lsha" "$1" >&2; r=$? ;;                          # new ref
  esac
  [ "$r" = 1 ] && rc=1
done
[ "$rc" = 0 ] || echo "teamlead: push blocked: the superdoc errors above are in commits being pushed (the value is never printed)." >&2
exit $rc
EOS
      ;;
    *) printf 'bash "$LINT" --staged >&2; r=$?\n[ "$r" = 1 ] && exit 1\nexit 0\n' ;;
  esac
}

# Prints at most one line (nothing on success). Needs TL_PROJECT (the main checkout).
tl_install_superdoc_hooks() {
  tl_superdoc_wired "$TL_PROJECT" || return 0
  local common hp hooks h want cur skipped=""
  common=$(git -C "$TL_PROJECT" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common" in /*) ;; *) common="$TL_PROJECT/$common" ;; esac
  hp=$(git -C "$TL_PROJECT" config --get core.hooksPath 2>/dev/null)
  if [ -n "$hp" ]; then
    echo "[teamlead] superdoc: core.hooksPath is set, so the pre-commit, pre-merge-commit and pre-push leak checks could not be installed. Only the Bash guard covers superdoc leaks here (agents' git commands, not a human's terminal)."
    return 0
  fi
  hooks="$common/hooks"
  mkdir -p "$hooks" 2>/dev/null || return 0
  for h in pre-commit pre-merge-commit pre-push; do
    want=$(tl_superdoc_stub "$h"; echo x); want=${want%x}
    if [ -e "$hooks/$h" ]; then
      if ! grep -qF "$TL_HOOK_MARK" "$hooks/$h" 2>/dev/null; then skipped+="$h "; continue; fi
      cur=$(cat "$hooks/$h"; echo x); cur=${cur%x}
      [ "$cur" = "$want" ] && continue
    fi
    printf '%s' "$want" > "$hooks/$h.tl-tmp.$$" 2>/dev/null && chmod +x "$hooks/$h.tl-tmp.$$" 2>/dev/null &&
      mv -f "$hooks/$h.tl-tmp.$$" "$hooks/$h" 2>/dev/null || { rm -f "$hooks/$h.tl-tmp.$$"; skipped+="$h "; }
  done
  if [ -n "$skipped" ]; then
    echo "[teamlead] superdoc: could not install the git hook(s): ${skipped% } (an existing hook is not managed by teamlead, or the folder is not writable). Those commands are covered only by the Bash guard (agents' git commands, not a human's terminal)."
  fi
  return 0
}
