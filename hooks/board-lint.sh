#!/usr/bin/env bash
# Board integrity. board.md is the one durable artefact the MODEL writes, so it is
# the one that needs checking — events.log is hook-written and cannot lie.
#
# Usage: board-lint.sh <board.md>   -> prints problems, exit 1 if any.
set -uo pipefail
f="${1:-}"; [ -f "$f" ] || exit 0
fail=""; add() { fail+="  - $1"$'\n'; }

grep -q '^| ✓ | ID | Task |' "$f" || {
  echo "  - board.md is not in the required table format (| ✓ | ID | Task | Agent | Owns | State | Branch |). Rewrite it as that table."; exit 1; }

# Data rows only: skip the header and the |:-:| separator.
rows=$(grep -E '^\|' "$f" | grep -v '^| ✓ | ID | Task |' | grep -vE '^\|[:| -]+\|$' || true)
[ -z "$rows" ] && exit 0
fld() { awk -F'|' -v n="$2" '{gsub(/^ +| +$/,"",$n); print $n}' <<<"$1"; }

declare -A seen_id
inflight=""          # "path<TAB>id" for rows that are not finished
while IFS= read -r r; do
  [ -n "$r" ] || continue
  tick=$(fld "$r" 2); id=$(fld "$r" 3); ag=$(fld "$r" 5)
  own=$(fld "$r" 6); st=$(fld "$r" 7)

  [ -n "$id" ] || continue
  [ -n "${seen_id[$id]:-}" ] && add "duplicate task id $id — ids must be unique"
  seen_id[$id]=1

  case "$st" in
    queued|running|returned|merged|done) ;;
    blocked-by*) ;;
    "") add "task $id has no State (expected queued/running/returned/merged or blocked-by N)" ;;
    *) add "task $id has an unknown State '$st'" ;;
  esac

  # ✓ and State must agree, or the board lies about what is finished.
  case "$tick:$st" in
    x:merged|x:done|✓:merged|✓:done) ;;
    x:*|✓:*) add "task $id is ticked done but its State is '$st'" ;;
    :merged|:done) add "task $id has State '$st' but is not ticked" ;;
  esac

  case "$st" in
    merged|done) ;;
    *)
      [ -n "$ag" ] || add "task $id is $st with no agent assigned"
      case "$own" in
        *read-only*|"") ;;
        *) while IFS= read -r p; do
             p=$(tr -d ' `' <<<"$p"); [ -n "$p" ] || continue
             inflight+="$p"$'\t'"$id"$'\n'
           done < <(tr ',' '\n' <<<"$own") ;;
      esac ;;
  esac
done <<< "$rows"

# The parallel-safety rule, enforced where it actually matters: no two UNFINISHED
# rows may own the same path. Enforced for plans already; execution needs it more.
# Compare every in-flight pair. Overlap is not just equality: "src/" contains
# "src/router/", and a worker owning the parent can clobber the child.
mapfile -t pairs < <(printf '%s' "$inflight" | grep -v '^$' | sort -u)
n=${#pairs[@]}
for ((i=0;i<n;i++)); do
  pi=${pairs[i]%%$'\t'*}; ii=${pairs[i]##*$'\t'}
  for ((k=i+1;k<n;k++)); do
    pk=${pairs[k]%%$'\t'*}; ik=${pairs[k]##*$'\t'}
    [ "$ii" = "$ik" ] && continue
    a="${pi%/}/"; b="${pk%/}/"
    if [ "$pi" = "$pk" ] || [ "${a#"$b"}" != "$a" ] || [ "${b#"$a"}" != "$b" ]; then
      add "tasks $ii and $ik are both in flight and own overlapping paths ('$pi' vs '$pk') — two workers writing one path is the collision this rule exists to prevent"
    fi
  done
done

[ -z "$fail" ] && exit 0
printf '%s' "$fail"
exit 1
