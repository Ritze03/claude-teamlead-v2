#!/usr/bin/env bash
# Layer B of the superdoc leak guard (PreToolUse, matcher Bash). Layer A is the native git hooks
# restore.sh installs (pre-commit, pre-merge-commit, pre-push): they are the primary cover and need
# no shell parsing. This hook covers what they cannot:
#   - `git commit --no-verify` and `git push --no-verify`, which skip the native hooks;
#   - projects where the native hooks could not be installed (core.hooksPath set, or a foreign
#     hook of the same name);
#   - fast-forward merges, for which git runs no hook at all (pre-merge-commit never fires).
#
# BEST EFFORT, like worktree-fence.sh says about Bash: what a command will do cannot be reliably
# read out of arbitrary shell (variables, quoting, aliases, scripts that call git themselves). This
# splits the text on && || ; | and newlines, follows a leading `cd DIR` and `git -C DIR`, and looks
# at the git subcommand of each segment. Anything it cannot parse or resolve passes silently:
# a wrong guess that blocks a correct command is worse than a miss, because Layer A, the Stop
# check and the audit catch what slips by.
#
# Runs on EVERY Bash call of the lead and the workers, so the very first thing after reading stdin
# is a pure-bash `case` that exits unless the call mentions git and commit, push or merge. A project
# without the `superdoc:start` marker in CLAUDE.md is never touched. Needs no active teamlead.
#
# Errors answer with the deny JSON board-fence.sh uses. The reason carries lint.sh's output: file,
# line and kind only, never a value.
set -uo pipefail
in=$(cat)
case $in in *git*) ;; *) exit 0 ;; esac
case $in in *commit*|*push*|*merge*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0
j() { jq -r "$1 // empty" <<<"$in" 2>/dev/null; }
[ "$(j .tool_name)" = Bash ] || exit 0
cmd=$(j .tool_input.command); cwd=$(j .cwd)
case $cmd in *git*) ;; *) exit 0 ;; esac
case $cmd in *commit*|*push*|*merge*) ;; *) exit 0 ;; esac
[ -d "$cwd" ] || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
LINT=$(tl_superdoc_lint)
[ -f "$LINT" ] || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:$r}}'
  exit 0
}

# lint DIR ARGS...: runs lint.sh in DIR under a timeout; true (and $out set) only on errors.
# Exit 1 is "errors"; 2 (unresolvable revision, usage) and a timeout (124) pass silently.
out=""
lint() {
  local d=$1; shift
  out=$(cd "$d" 2>/dev/null && tl_timeout 4 bash "$LINT" "$@" 2>/dev/null); [ $? = 1 ]
}
refuse() {  # what, dir
  deny "superdoc-guard: $1 refused. The lint output below lists file, line and kind of each leak (never the value). Replace each flagged value with a placeholder in the file, move anything future agents need to .claude/local/ (untracked), then retry. Do not use --no-verify to get around this."$'\n\n'"$(printf '%s\n' "$out" | head -40)"
}
top_of() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
wired() { local t; t=$(top_of "$1") && [ -n "$t" ] && tl_superdoc_wired "$t"; }

# ---- the subcommands -------------------------------------------------------------------------
do_commit() {  # dir args...
  local d=$1 a i all=0 ch idx tmp top; shift
  for a in "$@"; do
    case $a in
      --all) all=1 ;;
      --*) ;;
      -?*) a=${a#-}                       # letters left to right; m F C c t take a value, so stop there
           for ((i=0; i<${#a}; i++)); do
             ch=${a:i:1}
             case $ch in a) all=1 ;; m|F|C|c|t) break ;; esac
           done ;;
    esac
  done
  if [ "$all" = 1 ]; then
    # `commit -a` stages tracked changes itself: scan what that index would be, on a copy.
    top=$(top_of "$d") || return 0
    idx=$(git -C "$d" rev-parse --git-path index 2>/dev/null) || return 0
    case $idx in /*) ;; *) idx="$d/$idx" ;; esac
    [ -f "$idx" ] || return 0
    tmp="$idx.tl-guard.$$"
    cp "$idx" "$tmp" 2>/dev/null || return 0
    out=$( cd "$top" && GIT_INDEX_FILE=$tmp git add -u >/dev/null 2>&1
           GIT_INDEX_FILE=$tmp tl_timeout 4 bash "$LINT" --staged 2>/dev/null ); local rc=$?
    rm -f "$tmp"
    [ "$rc" = 1 ] && refuse "git commit -a"
    return 0
  fi
  lint "$d" --staged && refuse "git commit"
  return 0
}

do_push() {  # dir args...
  local d=$1 a skip=0 all=0 remote="" refspec="" up r ref; shift
  local -a pos=()
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case $a in
      -d|--delete) return 0 ;;                           # deleting a ref pushes no commit
      --all|--mirror) all=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) skip=1 ;;
      -*) ;;
      *) pos+=("$a") ;;
    esac
  done
  [ "${#pos[@]}" -gt 0 ] && remote=${pos[0]}
  if [ -z "$remote" ]; then
    up=$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) && remote=${up%%/*}
    [ -n "$remote" ] || remote=origin
  fi
  git -C "$d" remote get-url "$remote" >/dev/null 2>&1 || return 0   # a URL or an unknown name: cannot resolve
  if [ "$all" = 1 ]; then
    while read -r ref; do
      lint "$d" --push "$ref" "$remote" && refuse "git push --all"
    done < <(git -C "$d" for-each-ref --format='%(refname)' refs/heads 2>/dev/null)
    return 0
  fi
  if [ "${#pos[@]}" -gt 1 ]; then
    for refspec in "${pos[@]:1}"; do
      r=${refspec#+}; r=${r%%:*}                          # the local side of src:dst
      case $r in ""|--*) continue ;; esac
      git -C "$d" rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1 || continue
      lint "$d" --push "$r" "$remote" && refuse "git push"
    done
    return 0
  fi
  # no refspec: the current branch. Upstream known -> its range; otherwise a new branch.
  if git -C "$d" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    lint "$d" --range '@{u}..HEAD' && refuse "git push"
  else
    lint "$d" --push HEAD "$remote" && refuse "git push"
  fi
  return 0
}

do_merge() {  # dir args...
  local d=$1 a skip=0; shift
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case $a in
      --abort|--continue|--quit) return 0 ;;
      -m|-s|-X|-F|--into-name) skip=1 ;;
      -*) ;;
      *) git -C "$d" rev-parse -q --verify "$a^{commit}" >/dev/null 2>&1 || continue
         # a ref some remote-tracking branch already contains is public history: not ours to block
         [ -n "$(git -C "$d" for-each-ref --count=1 --contains "$a" refs/remotes 2>/dev/null)" ] && continue
         lint "$d" --range "HEAD..$a" && refuse "git merge $a" ;;
    esac
  done
  return 0
}

# ---- walk the command ------------------------------------------------------------------------
norm=${cmd//&&/$'\n'}; norm=${norm//||/$'\n'}; norm=${norm//;/$'\n'}; norm=${norm//|/$'\n'}
cur=$cwd
resolve() {  # base dir word -> absolute dir on stdout, or nothing
  local base=$1 w=$2
  w=${w#\"}; w=${w%\"}; w=${w#\'}; w=${w%\'}
  case $w in "~"|"~/"*) w=${HOME:-/}${w#"~"} ;; esac
  case $w in ""|-|*'$'*|*'`'*|*'*'*) return 0 ;; /*) ;; *) w="$base/$w" ;; esac
  [ -d "$w" ] && (cd "$w" 2>/dev/null && pwd)
  return 0
}
while IFS= read -r seg; do
  read -ra w <<<"$seg" || true
  i=0
  # leading VAR=val words and plain wrappers
  while [ "$i" -lt "${#w[@]}" ]; do
    case ${w[i]} in *=*|env|command|sudo|exec|time|nice|nohup) i=$((i+1)) ;; *) break ;; esac
  done
  [ "$i" -lt "${#w[@]}" ] || continue
  case ${w[i]} in
    cd) cur=$(resolve "$cur" "${w[i+1]:-}"); continue ;;
    git|*/git) ;;
    *) continue ;;
  esac
  [ -n "$cur" ] || continue                            # an earlier cd could not be resolved
  gdir=$cur; i=$((i+1))
  while [ "$i" -lt "${#w[@]}" ]; do                    # git's own options, up to the subcommand
    case ${w[i]} in
      -C) gdir=$(resolve "$gdir" "${w[i+1]:-}"); [ -n "$gdir" ] || continue 2; i=$((i+2)) ;;
      -c|--exec-path|--namespace) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "${#w[@]}" ] || continue
  sub=${w[i]}; args=("${w[@]:i+1}")
  case $sub in commit|push|merge) ;; *) continue ;; esac
  wired "$gdir" || continue
  case $sub in
    commit) do_commit "$gdir" "${args[@]+"${args[@]}"}" ;;
    push)   do_push   "$gdir" "${args[@]+"${args[@]}"}" ;;
    merge)  do_merge  "$gdir" "${args[@]+"${args[@]}"}" ;;
  esac
done <<<"$norm"
exit 0
