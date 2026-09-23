#!/usr/bin/env bash
# Resolve settings -> the actual worker names for this project.
#
# The whole point: the effort dial is a pure function of two values, so it is
# computed once here instead of being re-derived by the model from a table on
# every routing decision.
set -uo pipefail
D="${1:-$PWD}/.claude/teamlead"
S="$D/settings.md"

get() { grep -m1 "^$1:" "$S" 2>/dev/null | sed "s/^$1: *//" | tr -d '[:space:]'; }
effort=$(get effort); opus=$(get opus)
effort=${effort:-medium}; opus=${opus:-on-demand}
# A bad value can arrive by typo, hand edit or a stale settings file, so both
# dials are validated where they are READ, not only where they are written.
# Keep the raw strings: the fallback overwrites them, and the warning must quote
# what the user actually typed. Missing is not invalid — the defaults above
# already applied, so these only fire on a non-empty unknown value.
effort_bad=""; opus_bad=""

case "$effort" in
  low)     work=tl-sonnet-medium; scout=tl-sonnet-low;    esc=tl-opus-low;    ceil=tl-opus-high;   ban="" ;;
  xlow)    work=tl-sonnet-medium; scout=tl-sonnet-low;    esc=tl-opus-low;    ceil=tl-opus-medium; ban="*-high" ;;
  xmedium) work=tl-sonnet-medium; scout=tl-sonnet-medium; esc=tl-opus-medium; ceil=tl-opus-medium; ban="*-high" ;;
  high)    work=tl-opus-medium;   scout=tl-sonnet-high;   esc=tl-opus-high;   ceil=tl-opus-high;   ban="" ;;
  xhigh)   work=tl-opus-medium;   scout=tl-sonnet-high;   esc=tl-opus-high;   ceil=tl-opus-high;   ban="*-low" ;;
  medium)  work=tl-sonnet-high;   scout=tl-sonnet-medium; esc=tl-opus-medium; ceil=tl-opus-high;   ban="" ;;
  *)       effort_bad=$effort; effort=medium
           work=tl-sonnet-high;   scout=tl-sonnet-medium; esc=tl-opus-medium; ceil=tl-opus-high;   ban="" ;;
esac

case "$opus" in
  on-demand|role-dependant|always|never) ;;
  *) opus_bad=$opus; opus=on-demand ;;
esac

# Vision is exempt from both dials. Opus reads images best, so an image task goes
# to Opus regardless of the Opus policy — but capped at MEDIUM effort, never high,
# so the exemption stays cheap and cannot become a backdoor to the priciest tier.
vision=tl-opus-medium

# Opus Usage collapses the ladder independently of the dial.
if [ "$opus" = "never" ]; then
  case "$work" in tl-opus-*) work=tl-sonnet-high ;; esac
  esc=""; ban="${ban:+$ban, }tl-opus-*"
fi

# always is never's opposite pole: promote every worker to Opus at the
# effort-appropriate tier and ban Sonnet outright. Vision stays exempt as always.
if [ "$opus" = "always" ]; then
  case "$effort" in
    xlow|low)       work=tl-opus-low;    scout=tl-opus-low ;;
    medium|xmedium) work=tl-opus-medium; scout=tl-opus-low ;;
    high|xhigh)     work=tl-opus-high;   scout=tl-opus-medium ;;
  esac
  esc=$ceil
  ban="${ban:+$ban, }tl-sonnet-*"
fi

echo "effort: $effort · opus: $opus"
if [ -n "$esc" ]; then
  echo "Workhorse: $work · Scout: $scout · Escalate to: $esc (ceiling $ceil)"
else
  echo "Workhorse: $work · Scout: $scout · No Opus workers: a stuck worker reports its blocker, you reason through that one question, then re-brief a Sonnet worker."
fi
echo "Vision (images/screenshots/diagrams): $vision — always, exempt from the Opus policy and the effort dial. Never tl-opus-high for vision. Brief it to return a short finding, not a description of the whole image."
[ -n "$ban" ] && echo "BANNED, never dispatch: $ban (vision is the one exception)"
case "$opus" in
  on-demand)
    echo "Opus is escalation-only: every task starts on Sonnet, Opus only after a Sonnet worker actually fails." ;;
  role-dependant)
    # Without this line the setting produced output identical to the default, so
    # choosing it had no visible effect and the lead behaved as if on-demand.
    echo "Opus may be dispatched FIRST-CHOICE when the role calls for it — genuine architecture/design calls, ambiguous cross-system debugging — as well as via the retry ladder. Ordinary execution still starts on Sonnet." ;;
  always)
    echo "Every task goes to an Opus worker first-choice; Sonnet is not dispatched at all. The effort dial now only picks WHICH Opus tier." ;;
esac
[ -n "$effort_bad" ] && echo "INVALID SETTING: effort: $effort_bad does not exist. Routing above has degraded to effort: medium. Tell the user that option does not exist, name the valid levels — low, xlow, medium, xmedium, high, xhigh — and offer to re-open the effort picker."
[ -n "$opus_bad" ] && echo "INVALID SETTING: opus: $opus_bad does not exist. Routing above has degraded to opus: on-demand. Tell the user that option does not exist, name the valid modes — on-demand, role-dependant, always, never — and offer to re-open the Opus Usage picker."
exit 0
