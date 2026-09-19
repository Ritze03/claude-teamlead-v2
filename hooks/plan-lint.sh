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
# 'Done when' and 'Implementation plan' are both written at stage 4, from the same
# settled decisions, so before then they are simply absent. Both land ABOVE the two
# inboxes: 'Open questions' and 'Notes from me' are the user's half of the file and
# stay at the bottom, quick to reach and with nothing large growing underneath them.
order=$(grep '^## ' "$f" | sed 's/^## //')
canon=$'Goal\nContext\nDecisions\nDone when\nImplementation plan\nOpen questions\nNotes from me'
always=$'Goal\nContext\nDecisions\nOpen questions\nNotes from me'
bad=$(grep -vFx "$canon" <<<"$order" || true)
gone=$(grep -vFx "$order" <<<"$always" || true)
[ -n "$bad" ]  && add "unexpected section(s): $(tr '\n' ' ' <<<"$bad")"
[ -n "$gone" ] && add "missing section(s): $(tr '\n' ' ' <<<"$gone")"
# Only meaningful once the headings themselves are right, or it reports twice.
if [ -z "$bad" ] && [ -z "$gone" ] && [ "$order" != "$(grep -Fx "$order" <<<"$canon")" ]; then
  add "sections out of order. Want: Goal, Context, Decisions, [Done when, Implementation plan,] Open questions, Notes from me"
fi

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

# 5. every decision appears in a task — only once an implementation plan exists.
# Before stage 4 the table is legitimately empty and every decision would flag.
if [ -n "$rows" ]; then
  for d in $(grep -oE '^- \*\*D[0-9]+\*\*' "$f" | grep -oE 'D[0-9]+' || true); do
    # Match the ID as a word: "**D1 D2**" is as valid as "**D1** **D2**".
    grep -qE "(^|[^A-Za-z0-9])$d([^0-9]|\$)" <<<"$rows" || add "$d is decided but no implementation step references it"
  done
fi

# 6. inline user answer never promoted
awk '/^## Open questions/{o=1} /^### Answered/{o=0} /^## Notes from me/{o=0}
     o && /^ *> me:[[:space:]]*[^[:space:]]/{print NR}' "$f" \
  | grep -q . && add "an inline '> me:' answer is still under an open question — promote it to a Decision and strike the question"

# 7. at stage 4 the inboxes must be empty — Open questions and Notes from me are
# inboxes, not storage; a plan that still holds either is not finished planning.
if grep -qi '^> \*\*Stage 4\*\*' "$f"; then
  grep -q 'TBD' "$f" && add "stage 4 reached but TBD markers remain"
  [ -z "$rows" ] && add "stage 4 reached with no implementation plan — write the wave table above '## Open questions'"
  q=$(awk '/^## Open questions/{o=1;next} /^### Answered/{o=0} /^## /{o=0} o' "$f" \
      | grep -cE '^[[:space:]]*([0-9]+[.)]|[-*])[[:space:]]+\S') || q=0
  [ "$q" -gt 0 ] && add "stage 4 reached with $q open question(s) still unanswered — fold each answer into a Decision and strike the question into ### Answered"
  n=$(awk '/^## Notes from me/{o=1;next} /^## /{o=0} o' "$f" | grep -cE '\S') || n=0
  [ "$n" -gt 0 ] && add "stage 4 reached with $n line(s) left in 'Notes from me' — fold each into a Decision (or the Goal) and remove it"
  # Acceptance criteria must exist and say who checks each one, decided while
  # planning — settling it at the end is how everything becomes 'agent checks it'.
  dw=$(awk '/^## Done when/{o=1;next} /^## /{o=0} o' "$f")
  c=$(printf '%s' "$dw" | grep -cE '^[[:space:]]*-[[:space:]]*\[.\]') || c=0
  if [ "$c" -eq 0 ]; then
    add "stage 4 reached with no criteria under 'Done when' — add the section above '## Implementation plan' and say what must be true for this to be finished, as '- [ ] ...' items"
  else
    v=$(printf '%s' "$dw" | grep -cE 'verified by:[[:space:]]*(agent|user)') || v=0
    [ "$v" -lt "$c" ] && add "$((c - v)) of $c 'Done when' item(s) do not say who verifies them — mark each *verified by: agent* or *verified by: user*"
  fi
fi

# 9. a question with no recommendation. The lead has read the code and the user has
# not; a bare question hands the thinking to whoever has less context, and comes back
# as "I don't know, what do you think?". '*Your call:*' is the honest opt-out.
bare=$(awk '
  /^## Open questions/{o=1;next}
  /^### Answered/{o=0}
  /^## /{o=0}
  o {
    if ($0 ~ /^[[:space:]]*([0-9]+[.)]|[-*])[[:space:]]+[^[:space:]]/) {
      if (q && !s) n++
      # a short question may carry its suggestion on the same line
      q=1; s=($0 ~ /\*(Suggest|Your call):\*/)
    } else if ($0 ~ /\*(Suggest|Your call):\*/) s=1
  }
  END { if (q && !s) n++; print n+0 }' "$f")
[ "$bare" -gt 0 ] && add "$bare open question(s) have no '*Suggest:*' line — say what you would do and why, or mark it '*Your call:*' if it is genuinely theirs to decide"

# 8. staleness — the implementation plan must be stamped with the decisions it was built from
stamp=$(grep -oE 'decisions:[0-9a-f]{4}' "$f" | head -1 | cut -d: -f2)
if [ -n "$rows" ]; then
  cur=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$f" | grep '^- \*\*D' | md5sum | cut -c1-4)
  if [ -z "$stamp" ]; then add "implementation plan is not stamped — add '*Built from D… · decisions:$cur*' under the heading"
  elif [ "$stamp" != "$cur" ]; then add "implementation plan predates the current decisions (stamp $stamp, now $cur) — revise it or re-stamp"; fi
fi

[ -z "$fail" ] && { echo "plan-lint: ok"; exit 0; }
printf 'plan-lint found problems in %s:\n%s' "$f" "$fail"
exit 1
