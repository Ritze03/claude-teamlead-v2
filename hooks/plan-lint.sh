#!/usr/bin/env bash
# Plan file consistency. A plan does not go wrong when written — it goes wrong
# later, when a decision moves and an earlier section is not revised. So this
# runs on every write, not as a stage-4 ritual.
#
# Usage: plan-lint.sh <plan.md>   -> prints failures, exit 1 if any.
set -uo pipefail
f="${1:-}"; [ -f "$f" ] || { echo "plan-lint: no such file: $f"; exit 1; }
fail=""
add() { fail+="  - $1"$'\n'; }

# 1. sections present, in order  (checks are numbered as in the skill: 1 sections,
# 2 dependency waves, 3 Owns overlap, 4 agent tier, 5 decisions covered,
# 6 unpromoted answers, 7 TBD at stage 4, 8 staleness stamp)
order=$(grep -n '^## ' "$f" | sed 's/^[0-9]*:## //')
want=$'Goal\nContext\nDecisions\nOpen questions\nNotes from me\nImplementation plan'
[ "$order" = "$want" ] || add "sections wrong or out of order. Want: Goal, Context, Decisions, Open questions, Notes from me, Implementation plan"

# table rows: | wave | id | task | agent | owns | after |
# ID may carry a suffix (I4b); without [a-z]? such a row is silently invisible.
rows=$(grep -E '^\| *[0-9]+ *\| *I[0-9]+[a-z]? *\|' "$f" || true)
fld() { awk -F'|' -v n="$2" '{gsub(/^ +| +$/,"",$n); print $n}' <<<"$1"; }

if [ -n "$rows" ]; then
  declare -A wave_of
  while IFS= read -r r; do
    wave_of["$(fld "$r" 3)"]=$(fld "$r" 2)
  done <<< "$rows"

  while IFS= read -r r; do
    w=$(fld "$r" 2); id=$(fld "$r" 3); ag=$(fld "$r" 5); aft=$(fld "$r" 7)

    # 4. agent tier present and known
    case "$ag" in
      '`tl-'*'`'|tl-*) ;;
      *) add "$id has no valid agent tier (got: '${ag:-empty}')" ;;
    esac

    # 2. every After target exists and is in a lower wave (see 3 below for Owns)
    [ "$aft" = "—" ] || [ -z "$aft" ] || \
    for dep in $(tr ',' ' ' <<<"$aft"); do
      dep=$(tr -d ' ' <<<"$dep"); [ -n "$dep" ] || continue
      dw="${wave_of[$dep]:-}"
      if [ -z "$dw" ]; then add "$id depends on $dep, which does not exist"
      elif [ "$dw" -ge "$w" ]; then add "$id (wave $w) depends on $dep in wave $dw — a dependency must be in a lower wave"; fi
    done
  done <<< "$rows"

  # 3. no overlapping Owns within one wave — the parallel-safety proof
  dupes=$(while IFS= read -r r; do
            o=$(fld "$r" 6); case "$o" in *read-only*|'') continue;; esac
            echo "$(fld "$r" 2) $o"
          done <<< "$rows" | sort | uniq -d)
  [ -n "$dupes" ] && add "two steps in the same wave write the same path: $(tr '\n' ';' <<<"$dupes")"
fi

# 5. every decision appears in a task
for d in $(grep -oE '^- \*\*D[0-9]+\*\*' "$f" | grep -oE 'D[0-9]+' || true); do
  # Match the ID as a word: "**D1 D2**" is as valid as "**D1** **D2**".
  grep -qE "(^|[^A-Za-z0-9])$d([^0-9]|\$)" <<<"$rows" || add "$d is decided but no implementation step references it"
done

# 6. inline user answer never promoted
awk '/^## Open questions/{o=1} /^### Answered/{o=0} /^## Notes from me/{o=0} o && /^ *> me:/{print NR}' "$f" \
  | grep -q . && add "an inline '> me:' answer is still under an open question — promote it to a Decision and strike the question"

# 7. no TBD once at stage 4
if grep -qi '^> \*\*Stage 4\*\*' "$f" && grep -q 'TBD' "$f"; then
  add "stage 4 reached but TBD markers remain"
fi

# 8. staleness — the implementation plan must be stamped with the decisions it was built from
stamp=$(grep -oE 'decisions:[0-9a-f]{4}' "$f" | head -1 | cut -d: -f2)
if [ -n "$rows" ]; then
  cur=$(sed -n '/^## Decisions/,/^## Open questions/p' "$f" | grep '^- \*\*D' | md5sum | cut -c1-4)
  if [ -z "$stamp" ]; then add "implementation plan is not stamped — add '*Built from D… · decisions:$cur*' under the heading"
  elif [ "$stamp" != "$cur" ]; then add "implementation plan predates the current decisions (stamp $stamp, now $cur) — revise it or re-stamp"; fi
fi

[ -z "$fail" ] && { echo "plan-lint: ok"; exit 0; }
printf 'plan-lint found problems in %s:\n%s' "$f" "$fail"
exit 1
