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
effort=$(get effort); opus=$(get opus); prompting=$(get prompting)
effort=${effort:-medium}; opus=${opus:-on-demand}; prompting=${prompting:-sequential}

case "$effort" in
  low)     work=tl-sonnet-medium; scout=tl-sonnet-low;    esc=tl-opus-low;    ceil=tl-opus-high;   ban="" ;;
  xlow)    work=tl-sonnet-medium; scout=tl-sonnet-low;    esc=tl-opus-low;    ceil=tl-opus-medium; ban="*-high" ;;
  xmedium) work=tl-sonnet-medium; scout=tl-sonnet-medium; esc=tl-opus-medium; ceil=tl-opus-medium; ban="*-high" ;;
  high)    work=tl-opus-medium;   scout=tl-sonnet-high;   esc=tl-opus-high;   ceil=tl-opus-high;   ban="" ;;
  xhigh)   work=tl-opus-medium;   scout=tl-sonnet-high;   esc=tl-opus-high;   ceil=tl-opus-high;   ban="*-low" ;;
  *)       effort=medium
           work=tl-sonnet-high;   scout=tl-sonnet-medium; esc=tl-opus-medium; ceil=tl-opus-high;   ban="" ;;
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

echo "effort: $effort · opus: $opus · prompting: $prompting"
if [ -n "$esc" ]; then
  echo "Workhorse: $work · Scout: $scout · Escalate to: $esc (ceiling $ceil)"
else
  echo "Workhorse: $work · Scout: $scout · No Opus workers: a stuck worker reports its blocker, you reason through that one question, then re-brief a Sonnet worker."
fi
echo "Vision (images/screenshots/diagrams): $vision — always, exempt from the Opus policy and the effort dial. Never tl-opus-high for vision. Brief it to return a short finding, not a description of the whole image."
[ -n "$ban" ] && echo "BANNED, never dispatch: $ban (vision is the one exception)"
if [ "$opus" = "on-demand" ]; then
  echo "Opus is escalation-only: every task starts on Sonnet, Opus only after a Sonnet worker actually fails."
fi
exit 0
