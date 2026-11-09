#!/usr/bin/env bash
# Smoke test for the teamlead hooks. Run from the repo root: ./test.sh
# Covers the paths that broke during development, since those are the ones
# that break again.
set -uo pipefail
export CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
H="$CLAUDE_PLUGIN_ROOT/hooks"
B="$CLAUDE_PLUGIN_ROOT/scripts/board.py"
PL="$H/plan-lint.sh"
PS2="$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md"
SD="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/SKILL.md"
LINT="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/lint.sh"
# The suite runs hooks and board.py against fixture projects under $T. Both resolve
# a project by walking UP (git-common-dir), so a fixture that is not its own repo
# and sits inside a real work tree lands on that tree's real board — the incident
# of 2026-11-09: TMPDIR=<worktree>/.tl-scratch/tmp (the worker brief's own advice)
# put every fixture under a worker worktree, and the suite wrote the lead's real
# board.json and events.log. So the temp root must have no git work tree above it
# (git is what the resolvers walk; a bare .claude/teamlead ancestor, e.g. in $HOME,
# is never found by walking); otherwise fall back to $HOME/tmp, or refuse to run.
# Inherited project/agent identity is dropped for the same reason (tests that
# need them set them explicitly).
unset CLAUDE_PROJECT_DIR CLAUDE_AGENT_ID TL_HOOK
tl_tmp_unsafe() {   # 0 = unsafe: the dir or an ancestor is inside a git work tree
  local d; d=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  while :; do
    [ -e "$d/.git" ] && return 0
    [ "$d" = / ] && return 1
    d=$(dirname "$d")
  done
}
T=$(mktemp -d)
if tl_tmp_unsafe "$T"; then
  rm -rf "$T"
  mkdir -p "$HOME/tmp" && T=$(mktemp -d -p "$HOME/tmp") || T=
  if [ -z "$T" ] || tl_tmp_unsafe "$T"; then
    [ -n "$T" ] && rm -rf "$T"
    echo "test.sh: refusing to run: TMPDIR (${TMPDIR:-/tmp}) and \$HOME/tmp are both inside a git work tree; point TMPDIR at a plain directory" >&2
    exit 2
  fi
fi
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"   # anything a test spawns with mktemp stays inside the safe root
# Probe for the regression test at the bottom: report the chosen root, run nothing.
[ -z "${TL_TEST_PROBE_TMP:-}" ] || { echo "$T"; exit 0; }
# statusline.sh normally prints a cache and refreshes in the background; the
# assertions on its content want the computed segment, so compute inline. The
# cache behaviour itself is tested separately, with this unset.
export TEAMLEAD_STATUSLINE_SYNC=1
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1 (got $2, want $3)"; }

proj="$T/p"; mkdir -p "$proj/src"; cd "$proj"
git init -q; git config user.email t@t.t; git config user.name t
echo a > src/a.py; echo b > src/b.py; git add -A >/dev/null; git commit -qm init

ev() { echo "$1" | "$2" >"$T/out" 2>&1; echo $?; }
STOP='{"hook_event_name":"Stop","cwd":"'$proj'","stop_hook_active":false}'
LOOP='{"hook_event_name":"Stop","cwd":"'$proj'","stop_hook_active":true}'

echo "== inactive project must cost nothing =="
check "gate no-ops without the flag" "$(ev "$STOP" "$H/gate.sh")" 0

mkdir -p .claude/teamlead/.state; : > .claude/teamlead/.state/active
printf 'effort: medium\nopus: on-demand\n' > .claude/teamlead/settings.md

echo "== gate on a clean, empty project =="
check "no ledger, no changes -> silent" "$(ev "$STOP" "$H/gate.sh")" 0

echo "== ledger: workers paired by id, not counted =="
D='{"hook_event_name":"PreToolUse","cwd":"'$proj'","tool_name":"Agent","prompt_id":"p1","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"work"}}'
S1='{"hook_event_name":"SubagentStart","cwd":"'$proj'","agent_type":"teamlead:tl-sonnet-high","agent_id":"w1"}'
R1='{"hook_event_name":"SubagentStop","cwd":"'$proj'","agent_type":"teamlead:tl-sonnet-high","agent_id":"w1","last_assistant_message":"done"}'
INT='{"hook_event_name":"SubagentStop","cwd":"'$proj'","agent_type":"","agent_id":"x","last_assistant_message":"internal"}'
L=$proj/.claude/teamlead/.state/events.log
rm -f $L
ev "$D" "$H/record.sh" >/dev/null; ev "$S1" "$H/record.sh" >/dev/null
ev "$INT" "$H/record.sh" >/dev/null
check "dispatch recorded"        "$(grep -c 'dispatch' $L)" 1
check "start recorded"           "$(grep -c '  start ' $L)" 1
check "internal agent ignored"   "$(grep -c 'return' $L)" 0
outn(){ python3 "$B" ledger --project $proj | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["outstanding"]))'; }
check "one worker outstanding"   "$(outn)" 1
# A worker still running in the background is the intended shape, not a
# problem: the turn is meant to end and the lead re-invoked when it lands.
check "an outstanding worker does not block the gate" "$(ev "$STOP" "$H/gate.sh")" 0
check "  and it prints nothing"  "$(cat "$T/out")" ""
python3 "$B" status --project $proj > "$T/statout" 2>&1
grep -q 'workers still working' "$T/statout" && ok "  board.py status still lists it as working" || bad "  board.py status lists it as working"
check "loop guard releases"      "$(ev "$LOOP" "$H/gate.sh")" 0
ev "$R1" "$H/record.sh" >/dev/null
check "return clears it"         "$(outn)" 0
check "gate clear"               "$(ev "$STOP" "$H/gate.sh")" 0

echo "== a long-running worker is never aged out =="
rm -f $L
printf '2000-01-01T00:00:00Z  start     agent=tl-sonnet-high  id=slow\n' > $L
check "a 25-year-old start IS treated as abandoned" "$(outn)" 0
printf '%s  start     agent=tl-sonnet-high  id=slow2\n' "$(date -u -d '-90 minutes' +%Y-%m-%dT%H:%M:%SZ)" >> $L
check "a 90-minute run is still outstanding" "$(outn)" 1
rm -f $L

echo "== board: JSON is the truth, md is rendered =="
bp=$T/bp; mkdir -p $bp
bcmd(){ python3 "$B" "$@" --project $bp >"$T/bout" 2>&1; echo $?; }
check "add a task" "$(bcmd add --task A --agent tl-sonnet-low --owns src/a)" 0
check "add a second, disjoint" "$(bcmd add --task B --agent tl-sonnet-low --owns src/b)" 0
check "overlapping path refused at write time" "$(bcmd add --task C --agent tl-sonnet-low --owns src)" 1
grep -q 'overlapping paths' "$T/bout" && ok "  refusal names the overlap" || bad "  refusal names the overlap"
check "board.md was generated" "$([ -f $bp/.claude/teamlead/board.md ] && echo 0 || echo 1)" 0
grep -q 'GENERATED from .state/board.json' $bp/.claude/teamlead/board.md && ok "  md is marked generated" || bad "  md is marked generated"
check "merge with notes" "$(bcmd update --id 2 --state merged --notes 'swapped the loader')" 0
grep -q 'How it was solved' $bp/.claude/teamlead/board.md && ok "  how-it-was-solved recorded" || bad "  how-it-was-solved recorded"
check "finished task frees its path" "$(bcmd add --task D --agent tl-sonnet-low --owns src/b)" 0
check "check passes on a valid board" "$(bcmd check)" 0
printf 'hand edited\n' >> $bp/.claude/teamlead/board.md
check "hand-edit drift detected" "$(bcmd check)" 1
grep -q 'drifted' "$T/bout" && ok "  drift names the cause" || bad "  drift names the cause"
check "render repairs the drift" "$(bcmd render)" 0
check "check passes again" "$(bcmd check)" 0

echo "== D5/D13: board writes are serialised (lock race) and atomic =="
lp=$T/lock; mkdir -p $lp
lcmd(){ python3 "$B" "$@" --project $lp >"$T/lout" 2>&1; echo $?; }
bd=$(dirname "$B")
racer() {
  python3 -c "
import sys, time
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    time.sleep(0.5)
    orig(db, project)
board.save = slow
board.mutate(board.op_add, project='$lp', task='$1')
"
}
racer A & rp1=$!
racer B & rp2=$!
wait $rp1 $rp2
race_json="$lp/.claude/teamlead/.state/board.json"
nrows=$(python3 -c "import json; print(len(json.load(open('$race_json'))['tasks']))")
check "race: both concurrent adds landed as rows" "$nrows" 2
ids=$(python3 -c "import json; d=json.load(open('$race_json')); print(','.join(sorted(str(t['id']) for t in d['tasks'])))")
check "race: the two rows have distinct ids" "$ids" "1,2"
tmpleft=$(find "$lp/.claude/teamlead/.state" -maxdepth 1 -name '*.tmp*' 2>/dev/null | wc -l)
check "atomic save: no leftover tmp file in .state/" "$tmpleft" 0

echo "== D5: _atomic_write survives a crash mid-write (no truncated board.json) =="
crashp=$T/crash; mkdir -p $crashp
python3 "$B" add --task A --agent tl-sonnet-low --project $crashp >/dev/null
crash_json="$crashp/.claude/teamlead/.state/board.json"
before=$(cat "$crash_json")
python3 -c "
import sys, pathlib
sys.path.insert(0, '$bd')
import board
orig = pathlib.Path.write_text
def half(self, text, *a, **k):
    orig(self, text[:len(text)//2], *a, **k)
    raise RuntimeError('simulated crash')
pathlib.Path.write_text = half
try:
    board.mutate(board.op_add, project='$crashp', task='B')
except RuntimeError:
    pass
"
after=$(cat "$crash_json")
check "crash mid-write: board.json byte-identical to before the crash" "$after" "$before"
ntasks=$(python3 -c "import json; print(len(json.load(open('$crash_json'))['tasks']))")
check "crash mid-write: board.json still parses with exactly 1 task" "$ntasks" 1
mdsize=$(wc -c < "$crashp/.claude/teamlead/board.md")
[ "$mdsize" -gt 0 ] && ok "crash mid-write: board.md still exists and is non-empty" || bad "crash mid-write: board.md still exists and is non-empty"
find "$crashp/.claude/teamlead/.state" -maxdepth 1 -name '*.tmp*' -delete

echo "== QC1: render's load->save must not race a locked mutate() =="
rndp=$T/rndlock; mkdir -p $rndp
python3 "$B" add --project $rndp --task "renderable" --agent tl-sonnet-low --owns rnd/x >/dev/null  # id 1
render_mutate_racer() {
  python3 -c "
import sys, time
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    time.sleep(0.5)
    orig(db, project)
board.save = slow
board.mutate(board.op_update, project='$rndp', id=1, state='running', worker='X')
"
}
render_cli_racer() {
  python3 -c "
import sys, time
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    time.sleep(0.5)
    orig(db, project)
board.save = slow
# give the other racer time to acquire the lock and update its in-memory copy
# first (still short of its own delayed save) — without the fix, this is the
# window where render's unlocked load reads stale data; with it, render's
# own lock acquisition simply queues behind the mutate() and this sleep is
# immaterial. Makes the race deterministic instead of a coin flip.
time.sleep(0.1)
board.main(['render', '--project', '$rndp'])
"
}
render_mutate_racer >/dev/null & rr1=$!
render_cli_racer >/dev/null & rr2=$!
wait $rr1 $rr2
rnd_row=$(python3 -c "import json; d=json.load(open('$rndp/.claude/teamlead/.state/board.json')); t=[x for x in d['tasks'] if x['id']==1][0]; print(t['state']+','+str(t['worker']))")
check "race: mutate's write to running/worker=X survives render's unlocked load->save" "$rnd_row" "running,X"

echo "== D5: board_add's own MCP write path (_call, outside mutate()) is locked too =="
mcp_p=$T/lockmcp; mkdir -p $mcp_p
mcpracer() {
  python3 -c "
import sys, time, os
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    time.sleep(0.5)
    orig(db, project)
board.save = slow
os.environ['CLAUDE_PROJECT_DIR'] = '$mcp_p'
board._call('board_add', {'tasks': [{'task': '$1'}]})
"
}
mcpracer A & mp1=$!
mcpracer B & mp2=$!
wait $mp1 $mp2
mcp_json="$mcp_p/.claude/teamlead/.state/board.json"
mcp_nrows=$(python3 -c "import json; print(len(json.load(open('$mcp_json'))['tasks']))")
check "board_add race: both concurrent MCP adds landed as rows" "$mcp_nrows" 2
mcp_ids=$(python3 -c "import json; d=json.load(open('$mcp_json')); print(','.join(sorted(str(t['id']) for t in d['tasks'])))")
check "board_add race: the two rows have distinct ids" "$mcp_ids" "1,2"

echo "== D10: update usage guard =="
check "update without --id prints usage" "$(lcmd update --state running)" 1
grep -q '^usage: board.py update --id' "$T/lout" && ok "  usage line printed" || bad "  usage line printed"
grep -q Traceback "$T/lout" && bad "  no traceback printed" || ok "  no traceback printed"

echo "== D11: worker row field, JSON-only =="
wp=$T/lockw; mkdir -p $wp
wcmd(){ python3 "$B" "$@" --project $wp >"$T/wout" 2>&1; echo $?; }
check "add task W" "$(wcmd add --task W --agent tl-sonnet-low)" 0
check "set worker on id 1" "$(wcmd update --id 1 --worker abc123)" 0
w=$(python3 -c "import json; d=json.load(open('$wp/.claude/teamlead/.state/board.json')); print([t['worker'] for t in d['tasks'] if t['id']==1][0])")
check "worker field set in board.json" "$w" "abc123"
grep -q abc123 $wp/.claude/teamlead/board.md && bad "  worker id leaked into board.md" || ok "  worker id stays JSON-only, not in board.md"

echo "== board resolves a worktree to the main checkout =="
python3 "$B" add --project $bp --task "main-only" --agent tl-sonnet-low --owns src/zz >/dev/null 2>&1
git -C $bp init -q 2>/dev/null; git -C $bp config user.email t@t.t; git -C $bp config user.name t
echo x > $bp/f.txt; git -C $bp add -A >/dev/null 2>&1; git -C $bp commit -qm init 2>/dev/null
git -C $bp worktree add -q $bp/.claude/worktrees/agent-x -b wtx 2>/dev/null
main_open=$(python3 "$B" list --project $bp | python3 -c 'import json,sys;print(json.load(sys.stdin)["open"])')
wt_open=$(cd $bp/.claude/worktrees/agent-x && python3 "$B" list | python3 -c 'import json,sys;print(json.load(sys.stdin)["open"])')
check "worker in a worktree sees the main board" "$wt_open" "$main_open"

echo "== only the lead writes to the board =="
BF="$H/board-fence.sh"
bf(){ out=$(echo "$1" | "$BF"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }
W='"agent_id":"w1","agent_type":"teamlead:tl-sonnet-low",'
check "lead may write"            "$(bf '{"tool_name":"mcp__teamlead-board__board_update"}')" allow
check "worker write refused"      "$(bf '{'"$W"'"tool_name":"mcp__teamlead-board__board_update"}')" deny
check "worker add refused"        "$(bf '{'"$W"'"tool_name":"mcp__teamlead-board__board_add"}')" deny
check "worker may still read"     "$(bf '{'"$W"'"tool_name":"mcp__teamlead-board__board_list"}')" allow
check "unrelated tool untouched"  "$(bf '{'"$W"'"tool_name":"Bash"}')" allow
# The real, plugin-namespaced names as observed live — the earlier ones were guesses.
R=mcp__plugin_teamlead_teamlead-board
check "real namespaced update refused" "$(bf '{'"$W"'"tool_name":"'$R'__board_update"}')" deny
check "real namespaced add refused"    "$(bf '{'"$W"'"tool_name":"'$R'__board_add"}')" deny
check "real namespaced list allowed"   "$(bf '{'"$W"'"tool_name":"'$R'__board_list"}')" allow
m=$(jq -r '.hooks.PreToolUse[] | select(.matcher|test("board")) | .matcher' "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json")
mt(){ python3 -c "import re,sys; sys.exit(0 if re.match(sys.argv[1],sys.argv[2]) else 1)" "$m" "$1"; }
R2=mcp__plugin_teamlead_teamlead-board
if mt "${R2}__board_add" && mt "${R2}__board_update" && ! mt "${R2}__board_list"; then
  ok "  hooks.json matcher covers the real names"
else bad "  hooks.json matcher covers the real names"; fi

echo "== board renders a plan ref once =="
python3 "$B" add --project $bp --task "do a thing — I9" --agent tl-sonnet-low --owns src/qq --plan I9 >/dev/null
n=$(grep -o '— I9' $bp/.claude/teamlead/board.md | wc -l)
check "plan ref not duplicated" "$n" 1

echo "== help command exists and is accurate =="
SK="$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md"
grep -q '/teamlead help' "$SK" && ok "help is in the commands table" || bad "help is in the commands table"
grep -q '## Help text' "$SK" && ok "help text block exists" || bad "help text block exists"
# every command the help advertises must be real
for c in "/teamlead plan" "/teamlead brainstorm" "/teamlead superdoc" "/teamlead status" "/teamlead stop" "/teamlead board" "/teamlead plan continue"; do
  grep -q -- "$c" "$SK" || bad "help advertises '$c' but the skill does not define it"
done
ok "advertised commands all defined"
# the dials it names must match resolve.sh
# medium belongs in this loop: since resolve.sh was restructured it is an explicit
# case arm like the rest, not a bare default assignment.
for lvl in low xlow medium xmedium high xhigh; do
  grep -q "  $lvl)" "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" || bad "help names effort level '$lvl' that resolve.sh lacks"
done
ok "effort levels in help match resolve.sh"
# The old assertion here was `grep -q 'effort=medium' resolve.sh`, which stopped
# asserting anything once the default arm went away — it now matches only line 13's
# `effort=${effort:-medium}`. Assert the BEHAVIOUR instead: medium must route.
medp=$T/medium; mkdir -p $medp/.claude/teamlead
printf 'effort: medium\nopus: on-demand\n' > $medp/.claude/teamlead/settings.md
medout=$("$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $medp)
check "effort: medium routes to the medium tier" \
  "$(grep -m1 '^Workhorse:' <<<"$medout")" \
  "Workhorse: tl-sonnet-high · Scout: tl-sonnet-medium · Escalate to: tl-opus-medium (ceiling tl-opus-high)"
check "  and the banner summary says medium" "$(head -1 <<<"$medout")" "effort: medium · opus: on-demand"
# F9: a BARE `grep -q "$m"` here asserted nothing — every mode name also occurs in
# resolve.sh's prose (the vision line) and in the INVALID SETTING message, so the
# four words survive even when the mode is deleted from the validation `case`.
# Anchor to the arm that actually decides whether the value is accepted:
#   `  on-demand|role-dependant|always|never) ;;`
# Deleting a name from that alternation now fails here, which is the point.
for m in on-demand role-dependant always never; do
  grep -qE "^  ([a-z-]+\|)*$m(\|[a-z-]+)*\) *;;" "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" \
    || bad "opus mode '$m' is not an accepted value in resolve.sh's validation case arm"
done
ok "opus modes in help match resolve.sh"

# every opus mode must produce a distinguishable guidance line
rdp=$T/rd; mkdir -p $rdp/.claude/teamlead
for m in on-demand role-dependant always never; do
  printf 'effort: medium\nopus: %s\n' "$m" > $rdp/.claude/teamlead/settings.md
  "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $rdp > "$T/r-$m"
done
# F9 (sibling): these diffs would pass for the WRONG reason if a mode were dropped
# from the validation case — the output then differs only because of an injected
# INVALID SETTING line, i.e. the mode was rejected, not honoured. So assert first
# that every mode was ACCEPTED, then that the accepted modes still differ.
for m in on-demand role-dependant always never; do
  grep -q 'INVALID SETTING: opus:' "$T/r-$m" \
    && bad "opus: $m is rejected by resolve.sh as an invalid value" \
    || ok "opus: $m is accepted as a valid setting"
  check "  and the banner echoes it back" "$(head -1 < "$T/r-$m")" "effort: medium · opus: $m"
done
if diff -q "$T/r-on-demand" "$T/r-role-dependant" >/dev/null; then
  bad "role-dependant is indistinguishable from on-demand"
else ok "each opus mode gives distinct guidance"; fi
if diff -q "$T/r-on-demand" "$T/r-always" >/dev/null; then
  bad "always is indistinguishable from on-demand"
else ok "always gives distinct guidance from on-demand"; fi

echo "== resolve.sh: an invalid dial value degrades to the default and says so =="
# A bad value must never take the banner down with it: the routing line below has to
# stay usable, so the dial falls back and the complaint is appended last.
ivp=$T/invalid; mkdir -p $ivp/.claude/teamlead
rs(){ printf "$1" > $ivp/.claude/teamlead/settings.md; "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $ivp; }

ivout=$(rs 'effort: turbo\nopus: on-demand\n')
grep -q 'INVALID SETTING' <<<"$ivout" && ok "effort: turbo -> INVALID SETTING" || bad "effort: turbo -> INVALID SETTING"
grep -q 'INVALID SETTING: effort: turbo does not exist' <<<"$ivout" && ok "  quotes back what was actually typed" || bad "  quotes back what was actually typed"
grep -q 'degraded to effort: medium' <<<"$ivout" && ok "  names the default it fell back to" || bad "  names the default it fell back to"
ivlvls=$(grep 'INVALID SETTING: effort' <<<"$ivout")
miss=""; for lvl in low xlow medium xmedium high xhigh; do
  grep -qE "(^| |, )$lvl(,| |$)" <<<"$ivlvls" || miss="$miss $lvl"; done
[ -z "$miss" ] && ok "  lists all six valid levels" || bad "  lists all six valid levels (missing:$miss)"
grep -q '^Workhorse: ' <<<"$ivout" && ok "  routing still printed — the banner stays usable" || bad "  routing still printed"
# The summary must show the CORRECTED value, never the raw one: a summary reading
# 'effort: turbo' would contradict the Workhorse line directly beneath it.
check "  the summary line shows the corrected value, not the typo" "$(head -1 <<<"$ivout")" "effort: medium · opus: on-demand"

ivout=$(rs 'effort: medium\nopus: banana\n')
grep -q 'INVALID SETTING: opus: banana does not exist' <<<"$ivout" && ok "opus: banana -> INVALID SETTING naming banana" || bad "opus: banana -> INVALID SETTING naming banana"
grep -q 'degraded to opus: on-demand' <<<"$ivout" && ok "  names the default it fell back to" || bad "  names the default it fell back to"
ivmodes=$(grep 'INVALID SETTING: opus' <<<"$ivout")
miss=""; for m in on-demand role-dependant always never; do
  grep -qE "(^| |, )$m(,| |$)" <<<"$ivmodes" || miss="$miss $m"; done
[ -z "$miss" ] && ok "  lists all four valid modes" || bad "  lists all four valid modes (missing:$miss)"
grep -q '^Workhorse: ' <<<"$ivout" && ok "  routing still printed" || bad "  routing still printed"
check "  the summary line shows the corrected mode" "$(head -1 <<<"$ivout")" "effort: medium · opus: on-demand"

ivout=$(rs 'effort: turbo\nopus: banana\n')
check "both dials invalid: two warnings" "$(grep -c 'INVALID SETTING' <<<"$ivout")" 2
check "  and the summary is fully corrected" "$(head -1 <<<"$ivout")" "effort: medium · opus: on-demand"

# Absent is not invalid: an unconfigured project already gets the defaults, and
# complaining about a file that was never written is noise.
rm -f $ivp/.claude/teamlead/settings.md
ivout=$("$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $ivp)
grep -q 'INVALID SETTING' <<<"$ivout" && bad "a MISSING settings.md must be silent" || ok "a MISSING settings.md is silent"
: > $ivp/.claude/teamlead/settings.md
ivout=$("$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $ivp)
grep -q 'INVALID SETTING' <<<"$ivout" && bad "an EMPTY settings.md must be silent" || ok "an EMPTY settings.md is silent"
check "  and it still routes on the defaults" "$(head -1 <<<"$ivout")" "effort: medium · opus: on-demand"

echo "== SKILL.md: the Commands table and the help fence must name the same command SET =="
# Two hand-written copies of the same list is deliberate — the table is written for
# the model, the fence is printed verbatim to the user — so the drift is killed by
# this test rather than by generating one from the other.
#
# Both extractors cut a command at the first placeholder or at the description
# gutter (a run of 2+ spaces), which is what makes the table's
# `brainstorm <agents> <iterations> <topic>` and the fence's `brainstorm <n> <r> <t>`
# compare equal. Cutting at the placeholder is load-bearing, not cosmetic: the
# fence's brainstorm line has only ONE space before its gloss, so a gutter-only
# rule silently loses that command (and the older `/teamlead( [a-z]+)*` rule would
# instead swallow any gloss that began with a lowercase word).
#
# F5: both anchors used to be too tight, so a plausible reformat of one copy made
# a command VANISH from that copy's set — and a vanished command on BOTH sides of
# a set comparison is invisible. QC demonstrated three misses: a bold table cell
# (`| **`/teamlead x`** |`, a style used elsewhere in these docs), a table row with
# no space after the leading pipe (valid markdown), and a fence line indented three
# spaces instead of two. The anchors below accept any first-cell decoration before
# the backtick, and any indent depth, and the COUNT assertions underneath make an
# unmatched row a failure rather than a silent skip.
#
# The fence is read only between COMMANDS and PLAN MODE: loosening `^  ` to `^ +`
# would otherwise sweep up the deeply-indented `/teamlead plan continue` prose line
# inside the PLAN MODE block, which is narrative, not a command listing.
cmdset_table_raw(){ awk '/^## Commands/,/^## Help text/' "$1" \
  | grep -oP '^\|[^|]*`\K/teamlead[^`]*' | sed -E 's/\s*[<[].*$//'; }
cmdset_table_rows(){ awk '/^## Commands/,/^## Help text/' "$1" \
  | grep '^|' | grep -vcE '^\|[-| :]+$|^\| *command *\|'; }
cmdset_fence_src(){ awk '/^## Help text/,/^## Project setup/' "$1" | awk '/^COMMANDS/,/^PLAN MODE/'; }
cmdset_fence_raw(){ cmdset_fence_src "$1" \
  | grep -oP '^ +\K/teamlead.*' | sed -E 's/(\s{2,}|\s*[<[]).*$//'; }
cmdset_fence_rows(){ cmdset_fence_src "$1" | grep -cP '^ +/'; }
cmdset_table(){ cmdset_table_raw "$1" | sort -u; }
cmdset_fence(){ cmdset_fence_raw "$1" | sort -u; }
cmdset_table "$SK" > "$T/cs-table"; cmdset_fence "$SK" > "$T/cs-fence"
check "both copies are non-empty (the extractors still match the file's shape)" \
  "$([ -s "$T/cs-table" ] && [ -s "$T/cs-fence" ] && echo ok || echo empty)" ok
# F5: a row the extractor cannot parse must be LOUD, not skipped.
check "every Commands-table row yields a command (none silently skipped)" \
  "$(cmdset_table_raw "$SK" | wc -l)" "$(cmdset_table_rows "$SK")"
check "every help-fence command line yields a command (none silently skipped)" \
  "$(cmdset_fence_raw "$SK" | wc -l)" "$(cmdset_fence_rows "$SK")"
only_t=$(comm -23 "$T/cs-table" "$T/cs-fence" | tr '\n' ' ')
only_f=$(comm -13 "$T/cs-table" "$T/cs-fence" | tr '\n' ' ')
[ -z "$only_t" ] && ok "every Commands-table command is in the help fence" \
  || bad "in the Commands table but MISSING from the help fence:$( echo " $only_t" | sed 's/ *$//')"
[ -z "$only_f" ] && ok "every help-fence command is in the Commands table" \
  || bad "in the help fence but MISSING from the Commands table:$( echo " $only_f" | sed 's/ *$//')"
# Pin the set itself too, so a command added to BOTH copies still gets looked at here.
check "the shared set is exactly the commands that exist today" \
  "$(tr '\n' ' ' < "$T/cs-table")" \
  "/teamlead /teamlead board /teamlead board clean /teamlead board drop /teamlead brainstorm /teamlead effort /teamlead help /teamlead opus /teamlead plan /teamlead plan continue /teamlead settings /teamlead status /teamlead stop /teamlead superdoc /teamlead superdoc map "
# F5: README.md carries a THIRD hand-written copy of the same list (## Commands plus
# ## Dials) and had no test at all. It is the project's front door, so a command that
# exists only there — or only not there — is a user-visible lie. Same extractor, same
# placeholder rule; the two tables are read as one range because the dials are
# commands too and SKILL.md lists them in a single table.
rm_cmds(){ awk '/^## Commands/,/^\*\*Vision/' "$CLAUDE_PLUGIN_ROOT/README.md" \
  | grep -oP '^\|[^|]*`\K/teamlead[^`]*' | sed -E 's/\s*[<[].*$//'; }
rm_rows(){ awk '/^## Commands/,/^\*\*Vision/' "$CLAUDE_PLUGIN_ROOT/README.md" \
  | grep '^|' | grep -vcE '^\|[-| :]+$|^\| *\| *\|$'; }
rm_cmds | sort -u > "$T/cs-readme"
check "  every README command row yields a command (none silently skipped)" \
  "$(rm_cmds | wc -l)" "$(rm_rows)"
only_r=$(comm -13 "$T/cs-table" "$T/cs-readme" | tr '\n' ' ')
only_sk=$(comm -23 "$T/cs-table" "$T/cs-readme" | tr '\n' ' ')
[ -z "$only_r" ] && ok "  README advertises no command SKILL.md lacks" \
  || bad "  in README but MISSING from SKILL.md's Commands table:$(echo " $only_r" | sed 's/ *$//')"
[ -z "$only_sk" ] && ok "  README advertises every command SKILL.md defines" \
  || bad "  in SKILL.md's Commands table but MISSING from README:$(echo " $only_sk" | sed 's/ *$//')"
# A third source: board.py's own usage line, so `/teamlead board <sub>` cannot name a
# subcommand the script does not implement.
python3 "$B" no-such-command --project $T >"$T/bcmds" 2>&1
bsubs=$(grep -m1 '^commands: ' "$T/bcmds")
for s in clean drop; do
  if grep -q "^/teamlead board $s$" "$T/cs-table" && grep -qE "(: |, )$s(,|$)" <<<"$bsubs"; then
    ok "  /teamlead board $s is implemented as board.py '$s'"
  else bad "  /teamlead board $s is implemented as board.py '$s' (board.py says: $bsubs)"; fi
done

echo "== SKILL.md: the board-drop worktree confirmation names a RUNNABLE source =="
# The second confirmation has to name which worktrees hold unmerged commits, and for
# a long time the file said so without ever saying how to find that out. A grep for
# the word "worktree" passes on that broken text, so this test does two things a
# grep cannot: it EXECUTES the command SKILL.md documents, against a fixture with one
# clean worktree and one holding an unmerged commit, and it matches the output shapes
# SKILL.md quotes against what state.sh really printed. Quoting a string state.sh
# does not print, or documenting a command that does not run, fails here.
wcsec=$T/wc-section
awk '/^- \*\*Removing those worktrees/,/^- `drop` deliberately leaves/' "$SK" | head -n -1 > $wcsec
[ -s $wcsec ] && ok "the drop worktree-confirmation bullet is still findable" \
  || bad "the drop worktree-confirmation bullet is still findable"
wccmd=$(grep -m1 'state\.sh' $wcsec | sed 's/^ *//')
[ -n "$wccmd" ] && ok "  and it names hooks/state.sh as the source of that list" \
  || bad "  it names NO source — hooks/state.sh appears nowhere in the bullet"
grep -qF '.claude/teamlead/.state/plugin-root' <<<"$wccmd" \
  && ok "  spelled via .state/plugin-root (CLAUDE_PLUGIN_ROOT is unset in the lead's shell)" \
  || bad "  the documented command does not read .state/plugin-root: $wccmd"

# A real project: master, one clean merged worktree, one with a commit of its own.
wcp=$T/wcproj; mkdir -p $wcp/.claude/teamlead/.state
echo "$CLAUDE_PLUGIN_ROOT" > $wcp/.claude/teamlead/.state/plugin-root
git -C $wcp init -q; git -C $wcp config user.email t@t.t; git -C $wcp config user.name t
git -C $wcp commit -q --allow-empty -m base
git -C $wcp worktree add -q $wcp/wt-clean -b wtclean 2>/dev/null
git -C $wcp worktree add -q $wcp/wt-work -b wtwork 2>/dev/null
git -C $wcp/wt-work commit -q --allow-empty -m unmerged
wcout=$(cd $wcp && eval "$wccmd" 2>&1)
grep -qE 'safe to remove\): .*/wt-clean$' <<<"$wcout" \
  && ok "  running it verbatim clears the clean, merged worktree" \
  || bad "  running it verbatim clears the clean, merged worktree (got: $wcout)"
grep -qE 'HOLDING WORK .*/wt-work$' <<<"$wcout" \
  && ok "  and flags the worktree holding an unmerged commit" \
  || bad "  and flags the worktree holding an unmerged commit (got: $wcout)"
grep 'safe to remove' <<<"$wcout" | grep -qE '/wt-work$' \
  && bad "  the unmerged worktree must NEVER be called safe to remove" \
  || ok "  the unmerged worktree is never called safe to remove"

# The quoted shapes must be the ones state.sh actually emits. <branch>, <path> and
# the commit count are the only placeholders; the rest compares literally.
grep -oP '^    \Kworktree .*' $wcsec > $T/wc-shapes
check "  SKILL.md quotes all three output shapes" "$(wc -l < $T/wc-shapes)" "3"
wcmatch(){ python3 -c '
import re,sys
rx=re.escape(sys.argv[1]).replace("<branch>","[^,)]+").replace("<why>",".+").replace("<path>",".+")
print("yes" if re.search("^  "+rx+"$",sys.stdin.read(),re.M) else "no")' "$1"; }
while read -r shape; do
  case "$shape" in
    *"CANNOT BE CHECKED"*)
      # Not reproducible from a healthy fixture, so pin it against the script text.
      grep -qF "${shape% <path>}" "$H/state.sh" \
        && ok "  the CANNOT-BE-CHECKED shape is verbatim from hooks/state.sh" \
        || bad "  SKILL.md quotes a CANNOT-BE-CHECKED line state.sh never prints: $shape" ;;
    *)
      check "  state.sh really prints: $shape" "$(wcmatch "$shape" <<<"$wcout")" yes ;;
  esac
done < $T/wc-shapes
# <why> is a placeholder, so pin its four documented values against the script that
# composes them — otherwise the bullet could list reasons state.sh never emits.
for why in 'uncommitted changes' 'commit(s) not in' 'status check FAILED' 'unmerged-commit check FAILED'; do
  if grep -qF "$why" $wcsec && grep -qF "$why" "$H/state.sh"; then
    ok "  HOLDING WORK reason '$why' is documented AND emitted by state.sh"
  else bad "  HOLDING WORK reason '$why' is missing from SKILL.md or from hooks/state.sh"; fi
done

# 'safe to remove' is the ONLY clearance; the other two shapes both forbid deletion.
wcflat=$(tr '\n' ' ' < $wcsec)
grep -qF 'safe to remove' $wcsec \
  && grep -qE 'HOLDING WORK.*CANNOT BE CHECKED|CANNOT BE CHECKED.*HOLDING WORK' <<<"$wcflat" \
  && ok "  the bullet names the one clearing string and both forbidding ones" \
  || bad "  the bullet does not distinguish the clearing string from the forbidding ones"
# The carve-out to "Do not re-check any of it" (:18-23) must be stated on both sides,
# or the two instructions contradict each other at exactly the destructive moment.
grep -qE 'Do not re-check' "$SK" && grep -A3 'Do not re-check' "$SK" | grep -qi 'exception' \
  && ok "  the injected-state section flags the exception to 'Do not re-check'" \
  || bad "  'Do not re-check any of it' still contradicts the drop-time re-check"
grep -qi 're-check' $wcsec \
  && ok "  and the drop bullet states the carve-out where it is used" \
  || bad "  the drop bullet never reconciles itself with 'Do not re-check any of it'"

echo "== status line segment =="
SL="$H/statusline.sh"
slp=$T/sl; mkdir -p $slp/.claude/teamlead/.state; cd $slp; git init -q
git config user.email t@t.t; git config user.name t; echo x > f.txt; git add -A >/dev/null; git commit -qm init
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
check "silent when teamlead is inactive" "$out" ""
: > $slp/.claude/teamlead/.state/active
echo "$CLAUDE_PLUGIN_ROOT" > $slp/.claude/teamlead/.state/plugin-root
python3 "$B" add --project $slp --task t1 --agent tl-sonnet-low --owns src/a >/dev/null
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q 'teamlead' <<<"$out" && ok "shows a segment when active" || bad "shows a segment when active"
grep -q '1 open' <<<"$out" && ok "  counts open tasks" || bad "  counts open tasks ($out)"
git -C $slp worktree add -q $slp/.claude/worktrees/agent-s -b ws 2>/dev/null
out=$(echo '{"workspace":{"current_dir":"'$slp'/.claude/worktrees/agent-s"}}' | bash "$SL")
grep -q '1 open' <<<"$out" && ok "  works from inside a worktree" || bad "  works from inside a worktree"
# Empty input legitimately falls back to $PWD; it must not error either way.
out=$(cd /tmp && echo '{}' | bash "$SL" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && ok "  empty input outside a project: silent, no error" || bad "  empty input outside a project (rc=$rc out=$out)"
out=$(echo 'not json' | bash "$SL" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "  survives malformed input" || bad "  survives malformed input (rc=$rc)"
# teamlead supports non-git projects; the segment must not require git.
ngp=$T/nogit; mkdir -p $ngp/.claude/teamlead/.state; : > $ngp/.claude/teamlead/.state/active
echo "$CLAUDE_PLUGIN_ROOT" > $ngp/.claude/teamlead/.state/plugin-root
python3 "$B" add --project $ngp --task ng --agent tl-sonnet-low --owns src/n >/dev/null
out=$(echo '{"workspace":{"current_dir":"'$ngp'"}}' | bash "$SL")
grep -q '1 open' <<<"$out" && ok "  works in a NON-git teamlead project" || bad "  works in a NON-git teamlead project (got: $out)"

# planning mode: driven by the plan file's stage header, not the pointer alone
mkdir -p $slp/.claude/teamlead/plan
pf=$slp/.claude/teamlead/plan/topic.md
printf '# T\n\n> **Stage 3** — working it out\n' > $pf
echo "$pf" > $slp/.claude/teamlead/.state/active-plan
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q "Planning: topic" <<<"$out" && ok "  names planning mode and the plan" || bad "  names planning mode and the plan ($out)"
grep -q 'stage 3/7' <<<"$out" && ok "  shows stage out of total" || bad "  shows stage out of total"
grep -q 'working it out' <<<"$out" && ok "  says what the stage is for" || bad "  says what the stage is for"
# the label must follow the NUMBER, not stale header prose
sed -i 's/Stage 3/Stage 4/' $pf
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q 'implementation plan' <<<"$out" && ok "  label tracks the number, not the prose" || bad "  label tracks the number ($out)"
grep -q 'Go' <<<"$out" && ok "  stage 4 flags that it is waiting on you" || bad "  stage 4 flags waiting"
sed -i 's/Stage 4/Stage 3/' $pf
for n in 5:building\ it 6:verifying 7:your\ turn\ to\ test; do
  sed -i "s/Stage [0-9]/Stage ${n%%:*}/" $pf
  out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
  grep -q "stage ${n%%:*}/7 ${n#*:}" <<<"$out" && ok "  stage ${n%%:*} shows '${n#*:}'" || bad "  stage ${n%%:*} label ($out)"
  # The pointer surviving the handoff is the whole fix: clearing it here is what
  # made the session dangle once implementation started.
  [ -f $slp/.claude/teamlead/.state/active-plan ] && ok "  stage ${n%%:*} keeps the plan active" || bad "  stage ${n%%:*} keeps the plan active"
done
grep -q 'Planning: topic' <<<"$out" && bad "  stage 7 should not still say Planning" || ok "  past stage 4 it reads 'Plan', not 'Planning'"
grep -q 'Your turn' <<<"$out" && ok "  stage 7 flags that it is waiting on you" || bad "  stage 7 flags waiting"
sed -i 's/Stage [0-9]/Stage 8/' $pf
echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL" >/dev/null
[ -f $slp/.claude/teamlead/.state/active-plan ] && bad "  a stage past 7 is dropped" || ok "  a stage past 7 is dropped"
echo "$pf" > $slp/.claude/teamlead/.state/active-plan
echo "$slp/.claude/teamlead/plan/gone.md" > $slp/.claude/teamlead/.state/active-plan
echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL" >/dev/null
[ -f $slp/.claude/teamlead/.state/active-plan ] && bad "  dangling pointer cleared" || ok "  dangling pointer cleared"

# colour + the ⚠ flag
printf 'hand edited\n' >> $slp/.claude/teamlead/board.md
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q '⚠' <<<"$out" && ok "  flags a real problem" || bad "  flags a real problem"
grep -q $'\033\[38;5;' <<<"$out" && ok "  emits colour" || bad "  emits colour"
python3 "$B" render --project $slp >/dev/null
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q '⚠' <<<"$out" && bad "  ⚠ clears when fixed" || ok "  ⚠ clears when fixed"
cd $proj

echo "== watcher re-baselines on restart =="
wp=$T/wre; mkdir -p $wp/.claude/teamlead/plan
pfw=$wp/.claude/teamlead/plan/t.md
printf 'before\n' > $pfw
setsid nohup bash "$H/watch-plan.sh" $wp $pfw > $wp/o1 2>&1 </dev/null & disown 2>/dev/null
sleep 1; w1pid=$(cat $wp/.claude/teamlead/.state/plan-watch.pid 2>/dev/null); [ -n "$w1pid" ] && kill "$w1pid" 2>/dev/null; sleep 1
printf 'the agent rewrote everything\nwhile the watcher was off\n' > $pfw
setsid nohup bash "$H/watch-plan.sh" $wp $pfw > $wp/o2 2>&1 </dev/null & disown 2>/dev/null
sleep 4
[ -s $wp/o2 ] && bad "restart replays the agent's own write ($(head -1 $wp/o2))" || ok "restart does not replay the agent's write"
snapw=$wp/.claude/teamlead/.state/snap/t.md
cmp -s $pfw $snapw && ok "  snapshot re-baselined to current content" || bad "  snapshot re-baselined"
w2pid=$(cat $wp/.claude/teamlead/.state/plan-watch.pid 2>/dev/null); [ -n "$w2pid" ] && kill "$w2pid" 2>/dev/null; true

echo "== a cancelled worker can be closed out =="
fp=$T/forget; mkdir -p $fp/.claude/teamlead/.state; : > $fp/.claude/teamlead/.state/active
NOWF=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  dispatch  agent=teamlead:tl-sonnet-medium  desc=scout\n%s  start     agent=teamlead:tl-sonnet-medium  id=k1\n' "$NOWF" "$NOWF" > $fp/.claude/teamlead/.state/events.log
nout(){ python3 "$B" ledger --project $fp | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["outstanding"]))'; }
check "killed worker counts as working" "$(nout)" 1
atype=$(python3 "$B" ledger --project $fp | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["agents"]["k1"])')
check "its agent type is parsed from the start line" "$atype" "teamlead:tl-sonnet-medium"
python3 "$B" forget --project $fp >/dev/null
check "forget closes it out" "$(nout)" 0
grep -q '  cancel    id=k1' $fp/.claude/teamlead/.state/events.log && ok "  appends a cancel, does not rewrite history" || bad "  appends a cancel"
grep -q '  start     agent=teamlead:tl-sonnet-medium  id=k1' $fp/.claude/teamlead/.state/events.log && ok "  the original start is still there" || bad "  original start kept"
printf '%s  start     agent=teamlead:tl-sonnet-low  id=k2\n%s  start     agent=teamlead:tl-sonnet-low  id=k3\n' "$NOWF" "$NOWF" >> $fp/.claude/teamlead/.state/events.log
python3 "$B" forget k2 --project $fp >/dev/null
check "forget <id> closes only that one" "$(nout)" 1

echo "== a save is recorded; a read is not =="
tp=$T/touch; mkdir -p $tp/.claude/teamlead/plan
tpf=$tp/.claude/teamlead/plan/t.md; printf 'a\n' > $tpf
setsid nohup bash "$H/watch-plan.sh" $tp $tpf >/dev/null 2>&1 </dev/null & disown 2>/dev/null
sleep 2
cat $tpf >/dev/null; bash "$H/plan-lint.sh" $tpf >/dev/null 2>&1; sleep 2
[ -f $tp/.claude/teamlead/.state/plan-touched ] && bad "reading the file must not count as the user touching it" || ok "reads and lint do not mark it touched"
printf 'a\nuser edit\n' > $tpf; sleep 4
[ -f $tp/.claude/teamlead/.state/plan-touched ] && ok "a real save marks it touched" || bad "a real save marks it touched"
tw=$(cat $tp/.claude/teamlead/.state/plan-watch.pid 2>/dev/null); [ -n "$tw" ] && kill "$tw" 2>/dev/null; true
grep -q 'Do not block on the user opening the file' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md" && ok "skill forbids gating on 'opened'" || bad "skill forbids gating on 'opened'"

echo "== 👀 tells you whether edits are being watched =="
wq=$T/eye; mkdir -p $wq/.claude/teamlead/{plan,.state}
: > $wq/.claude/teamlead/.state/active
echo "$CLAUDE_PLUGIN_ROOT" > $wq/.claude/teamlead/.state/plugin-root
pfq=$wq/.claude/teamlead/plan/q.md
printf '# Q\n\n> **Stage 3** — working it out\n' > $pfq
echo "$pfq" > $wq/.claude/teamlead/.state/active-plan
eye(){ echo '{"workspace":{"current_dir":"'$wq'"}}' | bash "$SL"; }
grep -q '👀' <<<"$(eye)" && bad "no watcher yet, must not claim watching" || ok "silent when no watcher"
setsid nohup bash "$H/watch-plan.sh" $wq $pfq >/dev/null 2>&1 </dev/null & disown 2>/dev/null
sleep 2
grep -q '👀' <<<"$(eye)" && ok "shows 👀 while watching" || bad "shows 👀 while watching"
# Kill by the recorded pid, not a pgrep pattern: -f matches any command line
# containing the path, including this script's own.
wpid=$(cat $wq/.claude/teamlead/.state/plan-watch.pid 2>/dev/null)
[ -n "$wpid" ] && kill "$wpid" 2>/dev/null
for _ in 1 2 3 4 5; do kill -0 "$wpid" 2>/dev/null || break; sleep 1; done
grep -q '👀' <<<"$(eye)" && bad "must drop 👀 once the watcher stops" || ok "drops 👀 when the watcher stops"
echo 999999 > $wq/.claude/teamlead/.state/plan-watch.pid
grep -q '👀' <<<"$(eye)" && bad "a stale pid must not claim watching" || ok "a stale pid does not claim watching"
[ -f $wq/.claude/teamlead/.state/plan-watch.pid ] && bad "  stale pid cleaned" || ok "  stale pid cleaned"

echo "== plan skill hands the watcher off with control =="
grep -q 'watcher follows who has control' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md" && ok "documents the handoff" || bad "documents the handoff"
grep -q 'plan-watch' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md" && ok "  records the task id to survive compaction" || bad "  records the task id"

echo "== superdoc stays at the root, and its @-refs are verified =="
grep -q 'Do not also copy it into' "$SD" && ok "says not to duplicate into .claude/" || bad "says not to duplicate into .claude/"
grep -q 'does not exist' "$LINT" && ok "  detects a dangling @-ref (lint.sh)" || bad "  detects a dangling @-ref"
grep -q 'no longer exists' "$SD" && ok "  health-check audits @-refs too" || bad "  health-check audits @-refs"
# (the detection snippet itself is run against fixtures in the force-load budget section)

echo "== superdoc: default folder yields to an explicit user request; privacy rule present =="
grep -q 'explicitly asks in plain text for another folder' "$SD" && ok "SKILL: an explicit user folder request wins" || bad "SKILL: user folder request"
! grep -q 'Always. No alternative' "$SD" && ok "  no 'always, no alternative' left" || bad "  stale 'always' wording"
grep -q 'Privacy' "$SD" && ok "  SKILL tells the lead to put privacy in briefs" || bad "  SKILL privacy line"
grep -q '^DOC=superdoc' "$SD" && grep -q 'test -d "\$DOC"' "$SD" && ok "  Step 1 detection snippet uses \$DOC" || bad "  Step 1 detection snippet uses \$DOC"
! grep -q 'test -d superdoc' "$SD" && ! grep -q "grep -oE '@superdoc/" "$SD" && ok "  Step 1 snippet no longer hard-codes superdoc/" || bad "  Step 1 snippet still hard-codes superdoc/"
BR="$CLAUDE_PLUGIN_ROOT/skills/teamlead-brainstorm/SKILL.md"
grep -q '<doc root>/brainstorm/' "$BR" && ! grep -q 'save\*\* to `superdoc/brainstorm' "$BR" && ok "  brainstorm saves under the doc root" || bad "  brainstorm saves under the doc root"
grep -q 'Part 4a — Privacy' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/playbook.md" && ok "playbook: privacy rule" || bad "playbook: privacy rule"
grep -q 'Privacy scan' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/playbook.md" && ok "  audit greps for leaks" || bad "  audit privacy scan"

grep -q 'docs/.*superdoc:start' <(grep -A3 'After a `/clear`' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md" | tr '\n' ' ') && ok "plan: after-/clear reads docs/ and the superdoc:start folder" || bad "plan: after-/clear doc folders"

PSK="$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md"
grep -q 'Read the docs, too' "$PSK" && grep -A6 'Read the docs, too' "$PSK" | tr '\n' ' ' | grep -q 'superdoc:start' && ok "plan: the stage-4 audit reads the project docs" || bad "plan: stage-4 audit docs"
grep -q 'project docs\*\* for the areas the plan touches' "$PSK" && ok "  stage 3 scouting covers the docs" || bad "  stage 3 scouting docs"
TLS="$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md"
grep -A12 'Check the docs before you board and dispatch' "$TLS" | tr '\n' ' ' | grep -q 'read the pages that matter yourself.*touch.*writing dispatch then waits' && ok "teamlead: docs read by the lead before a writing dispatch" || bad "teamlead: docs read before writing dispatch"
grep -q "after that Go I'll offer" "$TLS" && ok "  help text: the /clear offer comes after the Go" || bad "  help text /clear offer"

echo "== the @-budget rule keeps its reasoning =="
PB="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/playbook.md"
LINT="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/lint.sh"
lintin() { local d=$1; shift; (cd "$d" && "$LINT" "$@"); }   # run lint.sh from inside a fixture dir
grep -q 'nothing else, ever' "$PB" && ok "the exact set is still mandated" || bad "the exact set is still mandated"
grep -q 'does not suggest a file, it \*pastes\* it' "$PB" && ok "  explains @ pastes the file" || bad "  explains @ pastes the file"
grep -q 'for the whole session' "$PB" && grep -q 'carries its own copy' "$PB" && ok "  names the cost: whole session, every request, every worker" || bad "  names the cost: whole session, every request, every worker"
grep -q 'permanent tax' "$SD" && ok "  the lead is told to hold the line at QC" || bad "  lead told to hold the line"

echo "== superdoc: TERMINOLOGY.md entries are pointers (contract v3) =="
SKEL=$(awk '/^### `superdoc\/meta\/TERMINOLOGY.md`/{f=1;next} /^### /{f=0} f' "$PB")
printf '%s' "$SKEL" | grep -q 'Keep every entry short' && ok "rule text is inside the TERMINOLOGY skeleton" || bad "rule text missing from the TERMINOLOGY skeleton"
printf '%s' "$SKEL" | grep -q 'about 200 characters' && printf '%s' "$SKEL" | grep -q 'trim it to this form instead of' && ok "  rule: ~200 chars, details on the linked page, amend by trimming" || bad "  rule: size guide / trim wording"
printf '%s' "$SKEL" | grep -qF -- '- **Term** — what it is, in one line. See `superdoc/features/term.md`.' && ok "  skeleton example shows the pointer shape" || bad "  skeleton example line"
printf '%s' "$SKEL" | grep -q '^\*Why:\*' && ok "  skeleton has its *Why:*" || bad "  skeleton *Why:*"
grep -q 'entries are pointers: none over about 300 characters' "$PB" && ok "Part 8 gate: entries are pointers" || bad "Part 8 gate: TERMINOLOGY entries bullet"
grep -q '\*\*TERMINOLOGY.md entry length\*\* (the specific case' "$PB" && ok "Part 9 audit: oversized-entry bullet" || bad "Part 9 audit: oversized-entry bullet"
grep -q 'never delete information that exists nowhere else' "$PB" && ok "Part 10: trim moves detail to the page first" || bad "Part 10: trim wording"
PBN=$(tr '\n' ' ' < "$PB" | sed 's/  */ /g'); SDN=$(tr '\n' ' ' < "$SD" | sed 's/  */ /g')
printf '%s' "$PBN" | grep -q 'v2 → v3' && printf '%s' "$PBN" | grep -q 'The upgrade step itself rewrites no entries' && printf '%s' "$PBN" | grep -q 'trimmed by the repair phase that follows it' && ok "Part 6: upgrade step rewrites no entries, the repair phase trims them" || bad "Part 6: upgrade sentence"
printf '%s' "$PBN" | grep -q 'the dispatcher applies the upgrade automatically (SKILL.md Step 1b)' && printf '%s' "$PBN" | grep -q 'apply each version.s step in order' && printf '%s' "$PBN" | grep -q 'never a regeneration; existing files are not rebuilt from the skeletons' && ok "Part 6: upgrade is automatic, in order, incremental" || bad "Part 6: automatic upgrade wording"
printf '%s' "$PBN" | grep -q 'the newest contract is assumed to be the best available' && ok "Part 6: has its *Why:* (newest assumed best)" || bad "Part 6: upgrade *Why:*"
printf '%s' "$PBN" | grep -q 'an older marker here means it failed: still report it' && ok "Part 9: older marker at audit time = failed upgrade, still reported" || bad "Part 9: marker bullet"
printf '%s' "$PBN" | grep -q 'Part 6, is a separate step that runs before the audit; the audit itself writes nothing' && printf '%s' "$PBN" | grep -q 'Do not write to any file in this mode' && ok "Part 9: audit stays write-free, upgrade is a separate step" || bad "Part 9: report-only distinction"
STEP1B=$(awk '/^## Step 1b/{f=1;next} /^## /{f=0} f' "$SD" | tr '\n' ' ' | sed 's/  */ /g')
[ -n "$STEP1B" ] && ok "SKILL: Step 1b exists" || bad "SKILL: Step 1b missing"
printf '%s' "$STEP1B" | grep -q 'without offering or asking' && printf '%s' "$STEP1B" | grep -q 'one writing worker' && printf '%s' "$STEP1B" | grep -q 'worktree' && ok "SKILL Step 1b: automatic, one writing worker in a worktree" || bad "SKILL Step 1b: automatic/worker wording"
printf '%s' "$STEP1B" | grep -q 'in order (v2 → v3, then every later one)' && printf '%s' "$STEP1B" | grep -q 'N ≥ M' && printf '%s' "$STEP1B" | grep -q 'sed -n 3p' && ok "SKILL Step 1b: compares with playbook line 3, in order, N >= M is a no-op" || bad "SKILL Step 1b: version compare / ordering"
printf '%s' "$STEP1B" | grep -q 'in \*\*one line\*\*' && printf '%s' "$STEP1B" | grep -q 'never silent' && ok "SKILL Step 1b: tells the user in one line, never silent" || bad "SKILL Step 1b: one-line notice"
printf '%s' "$STEP1B" | grep -q 'not rebuilt from skeletons' && printf '%s' "$STEP1B" | grep -q 'entries are not rewritten' && ok "SKILL Step 1b: incremental, entries untouched" || bad "SKILL Step 1b: incremental wording"
printf '%s' "$STEP1B" | grep -q 'marker `none`.*not an upgrade.*hand-written' && ok "SKILL Step 1b: no marker = hand-written docs, not an upgrade" || bad "SKILL Step 1b: no-marker guard"
printf '%s' "$STEP1B" | grep -q '^\*Why:\*\|\*Why:\* the newest contract is assumed to be the best available' && ok "SKILL Step 1b: has its *Why:*" || bad "SKILL Step 1b: *Why:*"
printf '%s' "$SDN" | grep -q 'Present → \*\*Step 1b\*\* (automatic upgrade check), then \*\*HEALTH-CHECK\*\*' && ok "SKILL Step 1: routing runs the upgrade check before the health check" || bad "SKILL Step 1: routing line"
printf '%s' "$SDN" | grep -q 'Step 4 — REPAIR (automatic, after the audit)' && printf '%s' "$SDN" | grep -q 'Runs right after Step 3.s audit, in the same run, without offering or asking' && printf '%s' "$SDN" | grep -q 'Only if the user literally asks for a report only' && ok "SKILL Step 4: automatic after the audit, report-only only on a literal ask" || bad "SKILL Step 4: automatic repair wording"
printf '%s' "$SDN" | grep -q 'the Step 1b upgrade has already run before it' && printf '%s' "$SDN" | grep -q 'upgrade failed: report it as a finding' && ok "SKILL Step 3: audit report-only, older marker = failed upgrade" || bad "SKILL Step 3: upgrade wording"
# No offer / ask-first wording about upgrades may remain (a cleanup offer is fine).
stale=$(printf '%s\n%s\n' "$PBN" "$SDN" | grep -oiE 'offer(s|ed|ing)? (the |a )?(version |contract )?upgrade|upgrade offer|never apply it unasked|unasked|accepted upgrade|upgrade is offered|offers? a version upgrade' | grep -vi '^$' | head -5)
check "no offer/unasked wording about upgrades in SKILL.md or the playbook" "$stale" ""
stale2=$(printf '%s\n%s\n' "$PBN" "$SDN" | grep -oiE 'offer the cleanup|Never auto-fix|only on explicit ask|REPAIR the user asks for|only when the user asks|stays a REPAIR' | head -5)
check "no 'offer the cleanup' / 'Never auto-fix' / ask-first repair wording left" "$stale2" ""
check "playbook line 3 names contract v4" "$(sed -n 3p "$PB")" '`superdoc: v4`'
check "Part 6 marker example matches line 3" "$(grep -o '<!-- superdoc:start v[0-9]* -->' "$PB" | sort -u)" "<!-- superdoc:start v4 -->"
check "Part 6 compare sentence names v4" "$(tr '\n' ' ' < "$PB" | grep -o 'the `superdoc: v[0-9]*` on line 3')" 'the `superdoc: v4` on line 3'
check "Part 6: there are exactly two marker examples (Part 5 and Part 6), both v4" "$(grep -c '<!-- superdoc:start v4 -->' "$PB")" "2"
printf '%s' "$PBN" | grep -q '\*\*v2 → v3:\*\*' && printf '%s' "$PBN" | grep -q '\*\*v3 → v4:\*\* re-install `superdoc/claude-instructions/documentation.md` verbatim from the assets (Part 7, Read + Write tools)' && printf '%s' "$PBN" | grep -q 'Nothing else changes in the project' && ok "Part 6: keeps the v2 → v3 step and has the v3 → v4 step (re-install documentation.md)" || bad "Part 6: v3 → v4 step"
printf '%s' "$STEP1B" | grep -q 'v3 → v4: re-installed documentation.md' && ok "SKILL Step 1b: example one-liner is the v3 → v4 upgrade" || bad "SKILL Step 1b: example line"

echo "== superdoc: anonymized docs (contract v4) =="
DOCM="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/assets/documentation.md"
DOCN=$(tr '\n' ' ' < "$DOCM" | sed 's/  */ /g')
printf '%s' "$DOCN" | grep -q '## Write docs anonymized' && printf '%s' "$DOCN" | grep -q 'like a filed bug report' && printf '%s' "$DOCN" | grep -q 'hostnames or machine names' && printf '%s' "$DOCN" | grep -q 'MAC addresses or serials' && printf '%s' "$DOCN" | grep -q '`<client>`, `<server>`, `<host>`, `\$HOME`' && printf '%s' "$DOCN" | grep -q 'as software concepts are fine' && ok "documentation.md: carries the anonymize rule" || bad "documentation.md: anonymize rule"
awk '/^## /{h=$0} /Write docs anonymized/{a=NR} /^## Update after you change/{u=NR} END{exit !(a&&u)}' "$DOCM" && ok "  anonymize section sits beside 'Update after you change' (own ## heading)" || bad "  anonymize section heading placement"
[ "$(wc -c < "$DOCM")" -lt 6144 ] && ok "  documentation.md stays small (force-loaded): $(wc -c < "$DOCM")B < 6 KB" || bad "  documentation.md grew past 6 KB ($(wc -c < "$DOCM")B)"
P4A=$(awk '/^### Part 4a/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$P4A" | grep -q 'like a filed bug report' && printf '%s' "$P4A" | grep -q 'machine names' && printf '%s' "$P4A" | grep -q 'client/server machines or network' && printf '%s' "$P4A" | grep -q 'MAC addresses' && printf '%s' "$P4A" | grep -q 'Logs, command output' && printf '%s' "$P4A" | grep -q 'Repo-relative paths only' && ok "playbook Part 4a: client/server and machine names, network, MAC/serials, logs; old bullets kept" || bad "playbook Part 4a wording"
printf '%s' "$SDN" | grep -q 'like a filed bug report' && printf '%s' "$SDN" | grep -q 'hostnames or machine names' && printf '%s' "$SDN" | grep -q "client/server machines or network" && ok "SKILL brief line: same terms" || bad "SKILL brief line terms"
grep -q 'client/server names of the user.s own machines or' "$PB" && ok "Part 8 box names client/server and machine names" || bad "Part 8 privacy box"
# Identity-values pass: run the real Part 9 command against fixtures with INVENTED identity values.
IDCMD=$(grep -o 'for v in "\$(hostname.*; done' "$PB" | head -1)
[ -n "$IDCMD" ] && ok "Part 9: identity-values command is a single line" || bad "Part 9: identity-values command missing"
idd=$T/idscan; mkdir -p $idd/superdoc $idd/home
printf '[user]\n\tname = Tester Persona\n' > $idd/home/gitconfig       # no user.email on purpose: empty values must be skipped
printf '# Net\n\nrun ssh admin@TestHost-01 to reach it\n' > $idd/superdoc/leaky-host.md
printf '# Who\n\nwritten by tester persona\n' > $idd/superdoc/leaky-name.md
printf '# Login\n\nsession of testuser-77\n' > $idd/superdoc/leaky-user.md
printf '# Clean\n\nA client talks to a server over HTTP.\n' > $idd/superdoc/clean.md
printf '# Project\n\nSee superdoc/clean.md\n' > $idd/CLAUDE.md
idrun() { ( cd $idd && hostname() { echo testhost-01; } && export USER=testuser-77 GIT_CONFIG_GLOBAL=$idd/home/gitconfig GIT_CONFIG_NOSYSTEM=1 && eval "$(printf '%s' "$IDCMD" | sed 's#<doc-root>#superdoc#')" ); }
check "identity grep flags exactly the three leaky docs (hostname, user, git name; case-insensitive), by file:line" "$(idrun | sort | tr '\n' '|')" "superdoc/leaky-host.md:3|superdoc/leaky-name.md:3|superdoc/leaky-user.md:3|"
check "  output never contains an identity value" "$(idrun | grep -ci 'testhost-01\|testuser-77\|tester persona')" "0"
check "  a clean doc is not flagged (an empty git email is skipped, not matched everywhere)" "$(idrun | grep -c 'clean.md')" "0"
check "  CLAUDE.md is scanned too" "$(printf 'ref testhost-01\n' >> $idd/CLAUDE.md; idrun | grep -c '^CLAUDE.md:')" "1"
PRV=$(tr '\n' ' ' < "$PB" | sed 's/  */ /g')
printf '%s' "$PRV" | grep -q '\*\*Identity values of this machine\*\*' && printf '%s' "$PRV" | grep -q 'case-insensitive, fixed strings, empty values skipped' && printf '%s' "$PRV" | grep -q 'A short or generic value' && printf '%s' "$PRV" | grep -q '\*\*Judgement pass:\*\*' && printf '%s' "$PRV" | grep -q 'never quoting the value' && ok "Part 9: identity pass, false-positive note, judgement pass, no quoting" || bad "Part 9: privacy second pass wording"
grep -qF '(sk|ghp|xox[bp]|AKIA)[-_A-Za-z0-9]{12,}|(token|secret|api[_-]?key|password)[ :=]+\S{8,}' "$PB" && grep -qF "CLAUDE.md | cut -d: -f1,2" "$PB" && ok "  Part 9: the token/secret regex stays as a judgement scan (file:line only)" || bad "  Part 9: token regex missing"
printf '%s' "$PRV" | grep -q 'the leak checks are `lint.sh`' && printf '%s' "$PRV" | grep -q 'every error is a finding' && ! grep -q "grep -rnE '/home/|/Users/" "$PB" && ok "  Part 9: privacy scan points at lint.sh, no second copy of the path/email/IP regex" || bad "  Part 9: privacy scan wording"
printf '%s' "$PRV" | grep -q '\*\*Privacy leak\*\* (a Part 9 finding): replace the value with a placeholder' && printf '%s' "$PRV" | grep -q 'Rewriting history or force-pushing is the user.s decision, never done automatically' && ok "Part 10: leak -> placeholder automatically, history rewrite stays the user's" || bad "Part 10: privacy leak bullet"
# Repo hygiene: no real identity values may live in this repo's tracked skill files.
hyg=0
for rv in "$(hostname 2>/dev/null)" "$(git config user.email 2>/dev/null)"; do
  if [ "${#rv}" -ge 5 ] && grep -rqiF -e "$rv" "$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc" "$CLAUDE_PLUGIN_ROOT/CHANGELOG.md"; then hyg=1; fi
done
check "repo hygiene: superdoc skill files and CHANGELOG carry no real hostname or git email of the runner" "$hyg" "0"

echo "== superdoc: audit-then-fix, agents own the docs (contract v4) =="
printf '%s' "$SDN" | grep -q 'Superdoc is for agents, not the user' && printf '%s' "$SDN" | grep -q 'never ask the user what is right for the docs or whether they would like a change' && ok "SKILL: ownership statement" || bad "SKILL: ownership statement"
printf '%s' "$PBN" | grep -q 'owned by agents; the user never has to read or touch them' && ok "playbook intro: ownership statement" || bad "playbook intro: ownership statement"
printf '%s' "$DOCN" | grep -q 'written for agents and owned by agents; the user never has to read or touch them' && printf '%s' "$DOCN" | grep -q 'never ask the user what is right for the docs' && ok "documentation.md: ownership statement" || bad "documentation.md: ownership statement"
printf '%s' "$SDN" | grep -q 'Only three things go to the user' && printf '%s' "$SDN" | grep -q 'rewriting git history or force-pushing over a leak that is already committed' && printf '%s' "$SDN" | grep -q 'no marker, which is hand-written docs someone else owns' && printf '%s' "$SDN" | grep -q 'facts only the user knows' && ok "SKILL: the three exceptions are named (history rewrite, no-marker docs, user-only facts)" || bad "SKILL: exceptions"
printf '%s' "$PBN" | grep -q 'Only three things go to the user' && ok "playbook intro: names the same three exceptions" || bad "playbook intro: exceptions"
STEP3=$(awk '/^## Step 3/{f=1;next} /^## /{f=0} f' "$SD" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$STEP3" | grep -q 'The audit phase is read-only' && printf '%s' "$STEP3" | grep -q 'in the same run, go straight to Step 4: dispatch the repairs' && printf '%s' "$STEP3" | grep -q 'No offer, no question' && printf '%s' "$STEP3" | grep -q 'privacy leaks first' && ok "SKILL Step 3: read-only audit, then repairs dispatched automatically, leaks first" || bad "SKILL Step 3: audit-then-fix wording"
printf '%s' "$STEP3" | grep -q '^.*\*Why:\* the user said "agents should know that the superdoc is for THEM' && ok "SKILL Step 3: has its *Why:* (the user's reasoning)" || bad "SKILL Step 3: *Why:*"
printf '%s' "$STEP3" | grep -q 'in git history and whether it was pushed' && ok "SKILL Step 3: history exception is reported to the user" || bad "SKILL Step 3: history report"
printf '%s' "$SDN" | grep -q 'Never rewrite git history or force-push' && printf '%s' "$SDN" | grep -q 'move to the linked page first' && ok "SKILL Step 4: history untouched, move-before-trim kept" || bad "SKILL Step 4: history/trim"
printf '%s' "$PRV" | grep -q 'Runs automatically right after the audit, in the same run, with no offer and no question' && printf '%s' "$PRV" | grep -q 'The named items are the audit.s findings' && ok "Part 10: runs automatically on the audit's findings" || bad "Part 10: automatic scope"
printf '%s' "$PRV" | grep -q 'never delete information that exists nowhere else' && printf '%s' "$PRV" | grep -q 'confirm it really holds the content' && ok "Part 10: move-before-trim unchanged" || bad "Part 10: move-before-trim"
printf '%s' "$PRV" | grep -q 'leave a single greppable `STALE:` marker' && ok "Part 10: STALE: marker stays for what cannot be fixed now" || bad "Part 10: STALE marker"
printf '%s' "$PRV" | grep -q 'Part 9 — AUDIT (read-only phase)' && printf '%s' "$PRV" | grep -q 'Do not write to any file in this mode' && ok "Part 9: audit phase stays read-only" || bad "Part 9: read-only phase"
printf '%s' "$PRV" | grep -q 'default to `manual`, the safest' && ! printf '%s' "$PRV" | grep -q 'surface it rather than picking one' && ok "Part 7: version-policy variant is decided (default manual), not surfaced" || bad "Part 7: variant decision"
printf '%s' "$SDN" | grep -q 'Decide the path yourself from the repo, never by asking' && ! printf '%s' "$SDN" | grep -q 'Ask the tier' && ! printf '%s' "$SDN" | grep -qF '**ask if unsure**' && ok "SKILL Step 2: path and tier are decided, not asked" || bad "SKILL Step 2: asks the user"

echo "== superdoc: one page per capability (contract v4) =="
printf '%s' "$DOCN" | grep -q 'A new feature, backend or subsystem gets its own page' && ok "documentation.md: new capability gets its own page" || bad "documentation.md: own-page line"
P2=$(awk '/^## Part 2/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$P2" | grep -q 'One page per capability, each in its own file' && printf '%s' "$P2" | grep -q 'never a section tacked onto another page' && ok "Part 2: one page per capability rule" || bad "Part 2: one-page rule"
P3=$(awk '/^### `superdoc\/<capability>\/<name>.md`/{f=1;next} /^### /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$P3" | grep -q 'one capability per page' && ok "Part 3 feature-page skeleton: one capability per page" || bad "Part 3 skeleton: one capability per page"
printf '%s' "$SDN" | grep -q 'MAP one worker per capability folder' && printf '%s' "$SDN" | grep -q 'one page per capability' && printf '%s' "$SDN" | grep -q 'one `features/\*.md` per real capability' && ok "SKILL Step 2b: one worker per capability folder, one page per capability" || bad "SKILL Step 2b wording"
printf '%s' "$PRV" | grep -q 'One page per capability: no page covers several unrelated' && ok "Part 8: one-page-per-capability box" || bad "Part 8: one-page box"
printf '%s' "$PRV" | grep -q '\*\*Page size and scope\*\*' && printf '%s' "$PRV" | grep -q 'a judgement call, not a hard limit' && ok "Part 9: page size and scope bullet (judgement, not a hard limit)" || bad "Part 9: page size bullet"
SZCMD=$(grep -o "find <doc-root> -type f -name '\*.md' -size +12288c -exec wc -c {} \\\\;" "$PB" | head -1)
[ -n "$SZCMD" ] && ok "Part 9: page-size command is a single line" || bad "Part 9: page-size command missing"
szd=$T/pagesize; mkdir -p $szd/superdoc/features
head -c 12000 /dev/zero | tr '\0' 'a' > $szd/superdoc/features/small.md
head -c 13000 /dev/zero | tr '\0' 'b' > $szd/superdoc/features/big.md
head -c 20000 /dev/zero | tr '\0' 'c' > $szd/superdoc/features/huge.txt
szout=$(cd $szd && eval "$(printf '%s' "$SZCMD" | sed 's#<doc-root>#superdoc#')")
check "page-size command flags only the .md over 12 KB, with its size" "$szout" "13000 superdoc/features/big.md"
printf '%s' "$PRV" | grep -q '\*\*Splitting a page\*\*' && printf '%s' "$PRV" | grep -q 'move the content into them \*\*verbatim\*\*' && printf '%s' "$PRV" | grep -q "Fix every link and \`@\`-ref" && printf '%s' "$PRV" | grep -q 'README.md. index and the overview.s module map' && printf '%s' "$PRV" | grep -q 'confirm nothing was lost' && ok "Part 10: splitting moves verbatim, fixes links/@-refs/index/module map, confirms before cutting" || bad "Part 10: splitting bullet"
printf '%s' "$PRV" | grep -q 'When an entry.s detail has no page yet, it gets its own new page' && ok "Part 10: TERMINOLOGY trim creates a page when none exists" || bad "Part 10: trim creates page"
printf '%s' "$PRV" | grep -q 'collapses it back into .CLAUDE.md.' && ok "Part 0/9: scaffolding-only superdoc is collapsed by repair, not proposed" || bad "Part 0/9: collapse"
tdoc=$T/termaudit; mkdir -p $tdoc/meta
{ printf '# Terminology\n\n## Terms\n\n- **Short** — a one-liner. See `superdoc/features/short.md`.\n- **Long** — '; head -c 400 /dev/zero | tr '\0' 'x'; printf '\n'; } > $tdoc/meta/TERMINOLOGY.md
check "Part 9: no second copy of the entry-length awk in the playbook or SKILL.md" "$(grep -c 'function flush' "$PB" "$SD" | tr '\n' ' ' | sed "s#$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/##g")" "playbook.md:0 SKILL.md:0 "
hits=$(cd $T && "$LINT" --doc termaudit | grep 'TERMINOLOGY entry')
check "Part 9 (lint.sh) flags exactly the long entry" "$(printf '%s\n' "$hits" | sed 's/: warn.*//; s#termaudit/##')" "meta/TERMINOLOGY.md:6"
# #12: entries hard-wrapped over several lines are summed, not judged by their first line.
wdoc=$T/termwrap; mkdir -p $wdoc/meta
{
  printf '# Terminology\n\nrule text, not an entry\n\n## Terms\n\n'
  printf -- '- **Wrapped** — first line is short\n'                                    # line 7: wraps to 3 x 130 = ~410
  for i in 1 2 3; do printf '  %s\n' "$(head -c 130 /dev/zero | tr '\0' 'w')"; done
  printf -- '- **Tiny** — a short entry. See `superdoc/features/tiny.md`.\n'            # line 11
  printf -- '- **Small** — short but wrapped\n  %s\n' "$(head -c 80 /dev/zero | tr '\0' 's')"   # line 12: ~120
  printf -- '- **Cut** — ends at a heading\n'                                           # line 14
  for i in 1 2 3; do printf '  %s\n' "$(head -c 130 /dev/zero | tr '\0' 'c')"; done
  printf '\n## More\n\n'
  printf -- '- **Last** — final entry, no trailing heading\n'                         # last entry of the file
  for i in 1 2 3; do printf '  %s\n' "$(head -c 130 /dev/zero | tr '\0' 'z')"; done
} > $wdoc/meta/TERMINOLOGY.md
whits=$(cd $T && "$LINT" --doc termwrap | grep 'TERMINOLOGY entry' | sed 's/^[^:]*:\([0-9]*\): warn: TERMINOLOGY entry over ~300 characters (\([0-9]*\) chars)$/\1 \2/')
lnum() { grep -n -- "^- \*\*$1" $wdoc/meta/TERMINOLOGY.md | cut -d: -f1; }
check "Part 9 (lint.sh): a wrapped entry is flagged at its start line, summed over its lines; a short wrapped entry is not; an entry before a heading and the last entry of the file are flushed" \
  "$(printf '%s\n' "$whits" | awk '{printf "%s=%s ", $1, ($2>390 && $2<470)?"long":"odd:"$2}')" \
  "$(lnum Wrapped)=long $(lnum Cut)=long $(lnum Last)=long "

echo "== superdoc: force-load budget check (Step 1 snippet, Step 3, Part 8/9/10) =="
grep -q 'force-load budget' <(tr '[:upper:]' '[:lower:]' < "$PB") && grep -q '^- \*\*Force-load budget:\*\*' "$PB" && ok "Part 9 audit: force-load budget bullet" || bad "Part 9 audit: force-load budget bullet"
tr '\n' ' ' < "$PB" | sed 's/  */ /g' | grep -q 'never flag them for trimming' && ok "  verbatim installs listed, left out of the total, never flagged" || bad "  verbatim installs wording"
grep -q '^- \[ \] Force-load budget:' "$PB" && ok "Part 8 gate: force-load budget box" || bad "Part 8 gate: force-load budget box"
tr '\n' ' ' < "$PB" | sed 's/  */ /g' | grep -q 'Trimming a force-loaded file.*never delete information that exists nowhere else' && ok "Part 10: move-before-trim covers any force-loaded file" || bad "Part 10: move-before-trim wording"
tr '\n' ' ' < "$SD" | sed 's/  */ /g' | grep -q 'force-load bloat.*The audit phase is read-only.*That covers force-load bloat and oversized TERMINOLOGY entries' && ok "SKILL Step 3: bloat is audited, then repaired automatically" || bad "SKILL Step 3: bloat wording"
SNIP=$(awk '/^\*\*Run this with Bash as your first action/{f=1} f&&/^```bash/{g=1;next} g&&/^```/{exit} g' "$SD")
# Step 1 runs lint.sh through the plugin-root state file; the fixtures get that file, so the real
# snippet (detection lines + the lint.sh call) is what is exercised, end to end.
snip() { mkdir -p "$1/.claude/teamlead/.state"; printf '%s\n' "$CLAUDE_PLUGIN_ROOT" > "$1/.claude/teamlead/.state/plugin-root"; (cd "$1" && bash -c "$SNIP" 2>&1); }
mkgloss() { # file entries chars-per-entry: a glossary of "- **Tn** — xxxx" entries (invented content)
  { printf '# Terminology\n\n## Terms\n\n'
    for i in $(seq 1 "$2"); do printf -- '- **T%s** — ' "$i"; head -c "$3" /dev/zero | tr '\0' 'x'; printf '\n'; done; } > "$1"
}
mkfix() { # dir claude-bytes entries chars-per-entry ; CLAUDE.md + glossary + one project-owned file + the two verbatim installs
  mkdir -p "$1/superdoc/meta" "$1/superdoc/claude-instructions"
  head -c "$2" /dev/zero | tr '\0' 'c' > "$1/CLAUDE.md"
  printf '\n@superdoc/meta/TERMINOLOGY.md\n@superdoc/claude-instructions/changelog.md\n@superdoc/claude-instructions/documentation.md\n@superdoc/claude-instructions/documentation-version-policy.md\n' >> "$1/CLAUDE.md"
  mkgloss "$1/superdoc/meta/TERMINOLOGY.md" "$3" "$4"
  head -c 5300 /dev/zero | tr '\0' 'l' > "$1/superdoc/claude-instructions/changelog.md"
  head -c 2900 /dev/zero | tr '\0' 'd' > "$1/superdoc/claude-instructions/documentation.md"
  head -c 2300 /dev/zero | tr '\0' 'v' > "$1/superdoc/claude-instructions/documentation-version-policy.md"
}
nwarn() { printf '%s\n' "$1" | grep -c '⚠'; }
mkfix $T/fl_ok 4200 40 110          # healthy: ~5 KB glossary of short entries
mkfix $T/fl_short 4200 100 110      # ~12 KB glossary of short entries: counted total over 20 KB, no entry long
mkfix $T/fl_big 4200 100 510        # real-world shape: ~51 KB glossary of long entries
out_ok=$(snip $T/fl_ok); out_short=$(snip $T/fl_short); out_big=$(snip $T/fl_big)
check "budget: healthy tree prints its 5 files, no warning, no note" "$(printf '%s\n' "$out_ok" | grep -c '^force-loaded: ')/$(nwarn "$out_ok")/$(printf '%s\n' "$out_ok" | grep -c '^note:')" "5/0/0"
want_ok=$(cat $T/fl_ok/CLAUDE.md $T/fl_ok/superdoc/meta/TERMINOLOGY.md $T/fl_ok/superdoc/claude-instructions/changelog.md | wc -c)
check "budget: the total counts CLAUDE.md, the glossary and project files, and leaves the verbatim installs out" "$(printf '%s\n' "$out_ok" | grep '^force-loaded total: ')" "force-loaded total: ${want_ok}B"
check "  verbatim installs are listed, marked as such, with their own sum" "$(printf '%s\n' "$out_ok" | grep -c 'verbatim install: listed, not counted')/$(printf '%s\n' "$out_ok" | grep '^verbatim installs: ')" "2/verbatim installs: 5200B (listed above, not in the total)"
printf '%s\n' "$out_ok" | grep -q 'superdoc/meta/TERMINOLOGY.md [0-9]*B (glossary: judged by entry length' && ok "  the glossary is labelled as judged by entry length" || bad "  glossary label"
check "budget: a 12 KB glossary of short entries gets no file-size warning" "$([ "$(wc -c < $T/fl_short/superdoc/meta/TERMINOLOGY.md)" -gt 8192 ] && echo over8k)/$(printf '%s\n' "$out_short" | grep -c '⚠.*over 8 KB')" "over8k/0"
check "budget: total over 20 KB with every entry short is a note, not a warning" "$(nwarn "$out_short")/$(printf '%s\n' "$out_short" | grep -c '^note: force-loaded total is .*over 20 KB')" "0/1"
check "budget: a 51 KB glossary of long entries warns once on its entries, with the count (not on file size)" "$(printf '%s\n' "$out_big" | grep '⚠' | grep -v 'force-loaded total' | sed 's/ (an entry.*//;s#superdoc/meta/TERMINOLOGY.md#TERM#')" "⚠ TERM has 100 entries over ~300 characters"
printf '%s\n' "$out_big" | grep -q '^    .*TERMINOLOGY.md:5: 5[0-9][0-9] chars$' && ok "  and lists the entries with line and length" || bad "  entry listing ($(printf '%s\n' "$out_big" | sed -n 1,12p))"
check "  and the total is flagged too (entries are long, so it is a finding)" "$(printf '%s\n' "$out_big" | grep -c '^⚠ force-loaded total is .*over 20 KB')/$(printf '%s\n' "$out_big" | grep -c '^note:')" "1/0"
# #11: an @-ref inside a code span is prose, not a force-load; real refs are still found, and
# the size loop uses the same pattern as the dangling-ref loop.
btk=$T/fl_bt; mkdir -p $btk/superdoc/meta
head -c 30000 /dev/zero | tr '\0' 'n' > $btk/superdoc/meta/BIG.md
{ printf 'See `@superdoc/meta/NOPE.md` and `@superdoc/meta/BIG.md` for the loading rule.\n'
  printf '@superdoc/meta/START.md\n'
  printf 'read @superdoc/meta/AFTERSPACE.md now\n'
  printf '(@superdoc/meta/PAREN.md)\n'
  printf 'in a span `@superdoc/meta/NOPE.md` and then @superdoc/meta/MIXED.md\n'
  printf '@superdoc/meta/GONE.md\n'; } > $btk/CLAUDE.md
out_bt=$(snip $btk)
check "refs: backticked @-refs give no warning; real refs at line start, after a space, in parens and after a span all do" \
  "$(printf '%s\n' "$out_bt" | grep -o 'force-loads [^ ]*' | sed 's#force-loads superdoc/meta/##' | sort | tr '\n' ' ')" "AFTERSPACE.md GONE.md MIXED.md PAREN.md START.md "
check "refs: a backticked ref to an existing file is not force-loaded in the size report either" "$(printf '%s\n' "$out_bt" | grep -c 'BIG.md')" "0"
printf 'x @superdoc/meta/a.md\n' > $btk/CLAUDE.md
check "refs: the capture group leaves a clean path (a real ref after a space is checked as superdoc/meta/a.md)" "$(snip $btk | grep -o 'force-loads [^ ]*')" "force-loads superdoc/meta/a.md"
dang=$T/fl_dang; mkfix $dang 500 10 100; rm $dang/superdoc/claude-instructions/documentation.md
out_d=$(snip $dang); rc=$?
check "budget: dangling ref does not crash the snippet" "$rc" "0"
printf '%s\n' "$out_d" | grep -q 'force-loads superdoc/claude-instructions/documentation.md — that file does not exist' && printf '%s\n' "$out_d" | grep -q '^force-loaded total: ' && ok "  dangling ref flagged, total still printed" || bad "  dangling ref output ($out_d)"
printf '%s\n' "$out_ok" | grep -q '^superdoc marker: none$' && ok "marker line: a CLAUDE.md without the guarded block prints none" || bad "marker line: none ($(printf '%s\n' "$out_ok" | grep marker))"
mkdir -p $T/fl_mk; printf '# P\n<!-- superdoc:start v2 -->\n@superdoc/x.md\n<!-- superdoc:end -->\n' > $T/fl_mk/CLAUDE.md
check "marker line: prints the installed vN" "$(snip $T/fl_mk | grep '^superdoc marker:')" "superdoc marker: v2"
mkdir -p $T/fl_none; out_n=$(snip $T/fl_none); rc=$?
check "budget: absent CLAUDE.md does not crash" "$rc/$(printf '%s\n' "$out_n" | grep -c '⚠')" "0/0"
printf '%s\n' "$out_n" | grep -q '^superdoc marker: none$' && ok "marker line: absent CLAUDE.md prints none" || bad "marker line: absent CLAUDE.md"
printf '%s\n' "$out_n" | grep -q '^force-loaded total: 0B$' && ok "  absent CLAUDE.md totals 0B" || bad "  absent CLAUDE.md total ($out_n)"

echo "== superdoc: glossary judged by entry length, wording kept consistent (#13) =="
P9=$(awk '/^## Part 9/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
P8=$(awk '/^## Part 8/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
P10=$(awk '/^## Part 10/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$P9" | grep -q 'except `TERMINOLOGY.md` (judged by entry length' && printf '%s' "$P9" | grep -q 'leave them out of the total' && printf '%s' "$P9" | grep -q 'list them in the size report, marked as such' && ok "Part 9: TERMINOLOGY exempt from the 8 KB flag; verbatim installs listed, not counted" || bad "Part 9: accounting wording"
printf '%s' "$P9" | grep -q 'a healthy tree counts around 10 KB' && ! printf '%s' "$P9$P8$SDN" | grep -q 'around 15 KB' && ok "Part 9: healthy figure matches the new counting (10 KB), the old 15 KB is gone" || bad "Part 9: healthy figure"
printf '%s' "$P9" | grep -q 'Ask yourself, not the user, whether every term has to be known on every task' && printf '%s' "$P9" | grep -q "moves to that feature's page, which is a repair you make yourself" && printf '%s' "$P9" | grep -q 'Never delete a term just to meet a number' && printf '%s' "$P9" | grep -q 'never split the file into a core list and a linked list' && printf '%s' "$P9" | grep -q 'only works if the force-loaded list is complete' && ok "Part 9: the every-entry-short note (agents decide; never delete; never core/linked split)" || bad "Part 9: note wording"
printf '%s' "$P10" | grep -q 'Never delete a term just to meet a number, and never split the glossary into a core list and a linked list' && ok "Part 10: states both prohibitions too" || bad "Part 10: prohibitions"
printf '%s' "$P8" | grep -q 'except `TERMINOLOGY.md`' && printf '%s' "$P8" | grep -q 'wrapped lines counted' && printf '%s' "$P8" | grep -q 'The file has no size limit of its own' && ok "Part 8: gate boxes agree (glossary by entry length, wrapped lines counted)" || bad "Part 8: gate boxes"
SD3=$(awk '/^## Step 3/{f=1;next} /^## /{f=0} f' "$SD" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$SD3" | grep -q 'is judged by entry length' && printf '%s' "$SD3" | grep -q 'left out of the 20 KB total' && printf '%s' "$SD3" | grep -q 'every glossary entry short is a note, not a `⚠`' && ok "SKILL Step 3: same accounting" || bad "SKILL Step 3: accounting wording"
printf '%s' "$SDN" | grep -q 'A `note:` (total over 20 KB while every glossary entry is short) is not a `⚠`' && ok "SKILL Step 1: explains the note" || bad "SKILL Step 1: note explanation"
check "SKILL Step 1: only calls lint.sh --force-load; REF, LONG, refs() and the size loop are not copied there" "$(printf '%s\n' "$SNIP" | grep -c 'lint.sh" --doc "\$DOC" --force-load')/$(printf '%s\n' "$SNIP" | grep -cE '^REF=|^LONG=|^refs\(\)|grep -oE|wc -c|function flush')" "1/0"
check "lint.sh: REF, LONG, refs() and the force-load size loop are each defined once" "$(grep -c '^REF=' "$LINT")/$(grep -c '^LONG=' "$LINT")/$(grep -c '^refs() ' "$LINT")/$(grep -c 'wc -c' "$LINT")" "1/1/1/1"
check "SKILL Step 1 keeps the detection lines (present, wired, marker, gitignored)" "$(printf '%s\n' "$SNIP" | grep -c 'superdoc: present\|CLAUDE.md: wired\|superdoc marker:\|GITIGNORED')" "4"

echo "== superdoc: everyday rules reach agents, local details have a home (#14, #15) =="
check "documentation.md: 'Renamed / moved / removed' line absorbs the grep-the-docs rule (no extra line)" "$(printf '%s' "$DOCN" | grep -c 'Renamed / moved / removed.*grep the docs for the old name in the same commit')" "1"
printf '%s' "$DOCN" | grep -q 'by symbol (`file:symbol`), not line number; line numbers go stale' && ok "documentation.md: reference code by symbol, not line number" || bad "documentation.md: symbol rule"
printf '%s' "$DOCN" | grep -q '`.claude/local/` (git-ignored: add it to `.gitignore` first' && printf '%s' "$DOCN" | grep -q 'refer to it generically; secrets go nowhere in the repo' && ok "documentation.md: local details go to .claude/local/, ignored, referred to generically" || bad "documentation.md: local home"
[ "$(wc -c < "$DOCM")" -lt 6144 ] && ok "  documentation.md still under 6 KB after the additions ($(wc -c < "$DOCM")B)" || bad "  documentation.md over 6 KB"
P4A=$(awk '/^### Part 4a/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$P4A" | grep -q 'Local details have a home: `.claude/local/`' && printf '%s' "$P4A" | grep -q "add \`.claude/local/\` to the repo's \`.gitignore\`" && printf '%s' "$P4A" | grep -q 'git check-ignore -q .claude/local/x' && printf '%s' "$P4A" | grep -q "main checkout's absolute\*\* \`.claude/local/\` path in the repair row's \`owns\`" && printf '%s' "$P4A" | grep -q 'Reports never carry the values' && ok "Part 4a: .claude/local/ home, how it is ignored, per-checkout caveat via absolute owns, reports without values" || bad "Part 4a: local home wording"
printf '%s' "$P10" | grep -q 'Move before you replace' && printf '%s' "$P10" | grep -q 'first goes to `.claude/local/<topic>.md`' && printf '%s' "$P10" | grep -q 'A \*\*secret\*\* (token, password, key, `.env` value) is never copied anywhere: remove it' && ok "Part 10: useful local value moves to .claude/local/ before the placeholder; secrets are removed" || bad "Part 10: move-before-replace"
printf '%s' "$P10" | grep -q 'whether the repo is public (`gh repo view --json visibility`' && printf '%s' "$P10" | grep -q 'any exposed credential must be rotated first, because a history rewrite does not undo exposure' && printf '%s' "$P10" | grep -q 'Rewriting history or force-pushing is the user.s decision, never done automatically' && ok "Part 10: leak step (history, public or not, rotate credentials first, rewrite stays the user's call)" || bad "Part 10: leak step"
S4=$(awk '/^## Step 4/{f=1;next} /^## /{f=0} f' "$SD" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$S4" | grep -q "after anything useful in it has moved to \`.claude/local/\`" && printf '%s' "$S4" | grep -q "main checkout's absolute\*\* \`.claude/local/\` path, so put that path in the repair row's \`owns\`" && printf '%s' "$S4" | grep -q 'whether the repo is public' && printf '%s' "$S4" | grep -q 'any exposed credential must be rotated first' && printf '%s' "$S4" | grep -q 'the decision stays with them' && ok "SKILL Step 4: .claude/local/ via the main checkout's absolute owns; public/rotate/history report" || bad "SKILL Step 4: leak and local wording"
printf '%s' "$S4" | grep -q 'Do not trust "read Part 4a"\.' && printf '%s' "$S4" | grep -q 'carries the rule text itself\*\*' && printf '%s' "$S4" | grep -q 're-runs the Part 9 privacy scans on the result' && printf '%s' "$S4" | grep -q 'the identity-values pass' && ok "SKILL Step 4: privacy-repair brief carries the rule text; QC re-runs the Part 9 scans" || bad "SKILL Step 4: brief carries rule / QC rescans"

echo "== superdoc: lint.sh (leak checks, drift checks, modes) (#14, #15) =="
[ -x "$LINT" ] && ok "lint.sh exists and is executable" || bad "lint.sh missing or not executable"
SENT=sentinelzq9   # a unique value: it must never appear in any output of any mode
mklf() { rm -rf "$1"; mkdir -p "$1/superdoc/architecture" "$1/superdoc/features" "$1/superdoc/meta"; printf '# P\n' > "$1/CLAUDE.md"; }
LF=$T/lf; mklf $LF
{ printf '# Leaks\n'
  printf 'a /home/%s/x\n' $SENT; printf 'b /Users/%s/x\n' $SENT; printf 'c C:\\Users\\%s\\x\n' $SENT
  printf 'd %s@corp-%s.io\n' $SENT $SENT
  printf 'e 10.77.66.55\n'; printf 'f 172.20.66.55\n'; printf 'g 192.168.66.55\n'; printf 'h 169.254.66.55\n'; printf 'i 100.70.66.55\n'
  printf 'j 8.77.66.55\n'; printf 'k /mnt/%s/x\n'  $SENT; } > $LF/superdoc/features/leak.md
printf '# A\nsee main.py:42 and util.go:7\n' > $LF/superdoc/architecture/a.md
printf '# F\nsee main.py:42 here is fine\n' > $LF/superdoc/features/f.md
out_lf=$(lintin $LF 2>&1); rc_lf=$?
for kv in "2:error: home path" "3:error: home path" "4:error: home path" "5:error: email" "6:error: private IP" "7:error: private IP" "8:error: private IP" "9:error: private IP" "10:error: private IP" "11:warn: public IP" "12:warn: host path"; do
  printf '%s\n' "$out_lf" | grep -qx "superdoc/features/leak.md:${kv%%:*}: ${kv#*:}" && ok "  lint: leak.md line ${kv%%:*} is '${kv#*:}'" || bad "  lint: leak.md line ${kv%%:*} should be '${kv#*:}' ($out_lf)"
done
check "lint: errors make the exit status 1" "$rc_lf" "1"
check "lint: a line reference is a warning in architecture/ only" "$(printf '%s\n' "$out_lf" | grep 'line reference' | sed 's/: warn.*//')" "superdoc/architecture/a.md:2"
printf '%s\n' "$out_lf" | grep -q '^fix: replace each flagged value with a placeholder' && printf '%s\n' "$out_lf" | grep -q '\.claude/local/' && printf '%s\n' "$out_lf" | grep -q 'superdoc-lint: allow.*true false positives only.*never for a real value' && ok "lint: after errors, one fix line (placeholder, .claude/local/) and the allow marker is documented as false-positive-only" || bad "lint: fix lines ($out_lf)"
check "lint: no message asks the user anything about docs" "$(printf '%s\n' "$out_lf" | grep -ci 'ask the user\|would you\|do you want\|?$')" "0"
check "lint: the sentinel value never appears in the output (whole tree)" "$(printf '%s\n' "$out_lf" | grep -c "$SENT\|corp-\|77.66.55")" "0"
check "lint: no source line is echoed (only path:line: sev: kind)" "$(printf '%s\n' "$out_lf" | grep -vcE '^(superdoc/|CLAUDE.md)[^ ]*:[0-9]+: (error|warn): [A-Za-z ~()@0-9-]+$|^(fix|note|hint): |^superdoc-lint: ')" "0"

# --- allowlist and the listed false positives: each on its own, each must be silent -----------
fpc() { # label line
  mklf $T/fp; printf '# T\n%s\n' "$2" > $T/fp/superdoc/features/t.md
  local o; o=$(lintin $T/fp 2>&1); [ -z "$o" ] && ok "  lint no finding: $1" || bad "  lint false positive: $1 ($o)"
}
fpc "loopback 127.0.0.1" "bind 127.0.0.1 and 127.9.9.9"
fpc "0.0.0.0" "listen on 0.0.0.0"
fpc "localhost and ::1" "http://localhost:3000 and ::1"
fpc "documentation ranges" "192.0.2.7 198.51.100.9 203.0.113.250"
fpc "example.com/.org/.net emails" "a@example.com b@example.org c@mail.example.net"
fpc "*.example *.invalid *.test *.localhost emails" "a@x.example b@x.invalid c@x.test d@x.localhost"
fpc "noreply addresses" "noreply@corp.io and 1234+bob@users.noreply.github.com"
fpc "git@host: SSH remote" "git clone git@github.com:org/repo.git"
fpc "placeholder homes /home/user /home/you /home/username" "/home/user/x /home/you/x /home/username/x"
fpc "placeholder homes /home/<name> /home/\$USER /Users/you /Users/<name>" '/home/<name>/x /home/$USER/x /home/${USER}/x /Users/you/x /Users/<name>/x'
fpc "placeholder Windows home" 'C:\Users\<name>\x and C:\Users\Public\x'
fpc "generic system paths" "/usr/lib/x /etc/hosts /tmp/x /dev/null /proc/1 /bin/sh /var/log/x"
fpc "version string v10.0.0.1" "v10.0.0.1 and version 192.168.1.1 and >=10.0.0.1 and ^172.16.0.1"
fpc "longer dotted number 1.10.0.1.2" "1.10.0.1.2 and 10.0.0.1.5"
fpc "invalid octets 999.1.1.1" "999.1.1.1 and 300.1.1.1 and 1.2.3"
fpc "retina filenames" "icon@2x.png and logo@3x.webp"
fpc "npm scopes and versions" "@scope/pkg@1.2.3 and lodash@4.17.21 and pkg@1.2.3-beta.rc and next@canary"
fpc "@-mentions" "thanks @octocat and @media screen"
fpc "URL with @ that is not an email" "https://user:pw@host.org/path and ssh://git@gitlab.corp.io/x.git"
fpc "URLs that look like /home/ paths" "https://example.com/home/page/x and https://foo.org/Users/list/ and docs/home/x/y"
fpc "the RFC ranges themselves" "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"
fpc "superdoc-lint: allow skips a line" "/home/$SENT/x 10.9.9.9 a@corp.io <!-- superdoc-lint: allow -->"
fpc "/opt/homebrew and WSL /mnt/c" "/opt/homebrew/bin /mnt/c/x"
fpc "textbook placeholder public IPs" "1.1.1.1 8.8.8.8 1.2.3.4"
fpc "the QC repro: metadata IP and a@b.com" "ping 169.254.169.254, mail a@b.com"
fpc "placeholder email domains" "a@test.com b@domain.com c@email.com d@company.com e@acme.com f@yourcompany.com g@mycompany.com h@yourdomain.com i@foo.com j@bar.com k@foo.bar l@bar.baz m@host.tld"
fpc "a one-letter first label is a placeholder domain" "x@y.io and a@b.co.uk"
fpc "cloud metadata, Docker bridge, QEMU user net" "169.254.169.254 172.17.0.1 10.0.2.2"
fpc "network-address CIDR blocks" "10.0.0.0/16 172.17.0.0/16 10.0.1.0/24 192.168.4.0/24 (10.0.0.0/8)."
fpc "WSL placeholders: Public, <name>, you, a plain drive path" '/mnt/c/Users/Public/x /mnt/c/Users/<name>/x /mnt/c/Users/you/x /mnt/c/Windows/x'
check "lint WSL home: the value is never printed" "$(mklf $T/tp; printf '# T\n/mnt/c/Users/%s/x\n' $SENT > $T/tp/superdoc/features/t.md; lintin $T/tp 2>&1 | grep -c "$SENT")" "0"
tpc() { # label line expected
  mklf $T/tp; printf '# T\n%s\n' "$2" > $T/tp/superdoc/features/t.md
  local o; o=$(lintin $T/tp 2>&1 | grep ':2: ' | sed 's/^[^:]*:2: //'); check "  lint finds: $1" "$o" "$3"
}
tpc "file:// home path" "file:///home/$SENT/x" "error: home path"
tpc "quoted home path" "\"/home/$SENT/x\"" "error: home path"
tpc "mailto email" "mailto:$SENT@corp.io" "error: email"
tpc "ssh user@private-ip" "ssh $SENT@10.9.9.9" "error: private IP"
tpc "private IP in a URL" "http://10.9.9.9:8080/x" "error: private IP"
tpc "private IP in a blockquote" "> 10.9.9.9" "error: private IP"
tpc "private host address with a CIDR suffix" "10.4.4.5/24" "error: private IP"
tpc "192.168.1.5/24 is a host, not a network block" "192.168.1.5/24" "error: private IP"
tpc "a private host IP is still an error (192.168.1.1)" "192.168.1.1" "error: private IP"
tpc "a private host IP is still an error (10.0.0.1)" "10.0.0.1" "error: private IP"
tpc "a bare .0 address with no /N is still an error" "10.0.0.0" "error: private IP"
tpc "a real-looking email at a two-letter host" "$SENT@ab.com" "error: email"
tpc "WSL home /mnt/c/Users/NAME/x" "/mnt/c/Users/$SENT/x" "error: home path"
tpc "WSL home /mnt/d/users/NAME (lowercase, no trailing slash)" "cd /mnt/d/users/$SENT" "error: home path"
tpc "172.32 is public, not private" "172.32.0.1" "warn: public IP"
tpc "/srv host path" "/srv/www" "warn: host path"
tpc "a real home next to a placeholder" "/home/you/x and /home/$SENT/y" "error: home path"
mklf $T/bin; printf '# T\nsecret /home/%s/x\0\001\002 binary\n' $SENT > $T/bin/superdoc/features/b.bin; printf 'x\n' > $T/bin/superdoc/features/ok.md
check "lint: binary files are skipped" "$(lintin $T/bin 2>&1)" ""

# --- exit codes, usage, silence ------------------------------------------------------------------
mklf $T/wo; printf '# T\n/mnt/nas/x\n' > $T/wo/superdoc/features/w.md
out_wo=$(lintin $T/wo 2>&1); check "lint: warnings only: exit 0, still printed" "$?/$(printf '%s\n' "$out_wo" | grep -c ': warn: host path')" "0/1"
lintin $T/wo --bogus >/dev/null 2>&1; check "lint: unknown argument is exit 2" "$?" "2"
lintin $T/wo --staged --files x >/dev/null 2>&1; check "lint: two modes is exit 2" "$?" "2"
lintin $T/wo --doc >/dev/null 2>&1; check "lint: --doc without a value is exit 2" "$?" "2"
printf '<!-- superdoc:start v4 -->\n' > $T/wo/CLAUDE.md   # --range is a commit-time mode: it only runs in a wired project
lintin $T/wo --range nodots >/dev/null 2>&1; check "lint: --range without A..B is exit 2" "$?" "2"
check "lint: the usage error text carries no doc value" "$(lintin $T/wo --bogus 2>&1 | grep -c "$SENT")" "0"
mkdir -p $T/nosd; printf '# P\nno docs here\n' > $T/nosd/CLAUDE.md
out_ns=$(lintin $T/nosd 2>&1); check "lint: no doc root and no marker: exit 0, silent" "$?/$out_ns" "0/"
out_ns=$(lintin $T/nosd --files CLAUDE.md 2>&1); check "lint: ... also with --files" "$?/$out_ns" "0/"
lintin $LF --files >/dev/null 2>&1; check "lint: --files with no files is a quiet exit 0" "$?" "0"

# --- --files: all checks, report only the given files ---------------------------------------------
printf '# G\n/home/%s/y\n' $SENT > $LF/superdoc/features/other.md
printf '# Out\n/home/%s/y\n' $SENT > $LF/notes.md
out_f=$(lintin $LF --files superdoc/features/other.md notes.md 2>&1); rc_f=$?
check "lint --files: reports the given doc file only (old debt in leak.md stays quiet; a file outside the doc tree is ignored)" "$(printf '%s\n' "$out_f" | grep -c '^superdoc/features/other.md:2: error: home path$')/$(printf '%s\n' "$out_f" | grep -c 'leak.md\|notes.md')/$rc_f" "1/0/1"
check "lint --files: a file outside the doc tree alone is ignored entirely" "$(lintin $LF --files notes.md 2>&1; echo rc=$?)" "rc=0"
check "lint --files: a cwd-relative path works from inside a subdirectory" "$(cd $LF/superdoc/features && "$LINT" --files other.md 2>&1 | grep -c '^superdoc/features/other.md:2: error')" "1"
check "lint --files: the sentinel is not in the output" "$(printf '%s\n' "$out_f" | grep -c "$SENT")" "0"
# repo-wide force-load findings report only when a force-loaded file is among the files
FL=$T/lfl; mklf $FL; head -c 21000 /dev/zero | tr '\0' 'c' > $FL/CLAUDE.md; printf '# x\n' > $FL/superdoc/features/x.md
check "lint all: an over-budget CLAUDE.md is a warning (file size and total)" "$(lintin $FL 2>&1 | grep -c '^CLAUDE.md:1: warn: force-loaded')" "2"
check "lint --files: ... not reported when no force-loaded file is given" "$(lintin $FL --files superdoc/features/x.md 2>&1 | wc -c | tr -d ' ')" "0"
check "lint --files: ... reported when CLAUDE.md is given" "$(lintin $FL --files CLAUDE.md 2>&1 | grep -c '^CLAUDE.md:1: warn: force-loaded')" "2"
# dangling @-ref (with its line), glossary entry, README coverage
DR=$T/ldr; mklf $DR
printf '# P\n\nread @superdoc/meta/TERMINOLOGY.md and @superdoc/gone.md\nin a span `@superdoc/nope.md` is prose\n' > $DR/CLAUDE.md
{ printf '# Terminology\n\n## Terms\n\n- **Long** — '; head -c 400 /dev/zero | tr '\0' 'x'; printf '\n- **Short** — fine.\n'; } > $DR/superdoc/meta/TERMINOLOGY.md
printf '# README\n\n- [A](architecture/a.md)\n' > $DR/superdoc/README.md
printf '# a\n' > $DR/superdoc/architecture/a.md; printf '# b\n' > $DR/superdoc/features/b.md
mkdir -p $DR/superdoc/claude-instructions; printf '# d\n' > $DR/superdoc/claude-instructions/documentation.md
out_dr=$(lintin $DR 2>&1); rc_dr=$?
check "lint all: a dangling @-ref is reported on its CLAUDE.md line, a backticked one is not" "$(printf '%s\n' "$out_dr" | grep ': warn: dangling' | sed 's/: warn.*//')" "CLAUDE.md:3"
check "lint all: a TERMINOLOGY entry over ~300 characters is a warning at its line" "$(printf '%s\n' "$out_dr" | grep 'TERMINOLOGY entry' | sed 's/: warn.*//')" "superdoc/meta/TERMINOLOGY.md:5"
check "lint all: pages missing from README.md are reported; README.md itself and the claude-instructions/ installs (not in this README) are not" "$(printf '%s\n' "$out_dr" | grep 'not listed' | sed 's/: warn.*//' | sort | tr '\n' ' ')" "superdoc/features/b.md:1 superdoc/meta/TERMINOLOGY.md:1 "
check "lint all: warnings alone leave the exit status 0" "$rc_dr" "0"
printf '# README\n\n- [A](architecture/a.md)\n## claude-instructions/\n- [D](claude-instructions/documentation.md)\n' > $DR/superdoc/README.md
printf '# d2\n' > $DR/superdoc/claude-instructions/documentation-version-policy.md
check "lint all: once README.md lists claude-instructions/, an unlisted install is a finding too" "$(lintin $DR 2>&1 | grep 'not listed' | grep -c version-policy)" "1"
# a page listed in <doc>/README.md or in any README of its own directory chain counts as listed
RC=$T/lrc; mklf $RC; mkdir -p $RC/superdoc/features/sub $RC/superdoc/architecture
printf '# README\n\n- [A](architecture/a.md)\n' > $RC/superdoc/README.md
printf '# a\n' > $RC/superdoc/architecture/a.md
for f in b c; do printf '# x\n' > $RC/superdoc/features/$f.md; done
printf '# d\n' > $RC/superdoc/features/sub/d.md; printf '# e\n' > $RC/superdoc/features/sub/e.md
check "README listing: with only the root README, every page below the doc root that it does not name is reported" "$(lintin $RC 2>&1 | grep 'not listed' | sed 's/: warn.*//; s#superdoc/##' | sort | tr '\n' ' ')" "features/b.md:1 features/c.md:1 features/sub/d.md:1 features/sub/e.md:1 "
printf '# Features\n\n- [B](b.md)\n- [D](sub/d.md)\n' > $RC/superdoc/features/README.md
printf '# Sub\n\n- [E](e.md)\n' > $RC/superdoc/features/sub/README.md
check "README listing: a page named in the README of its own directory (b.md in features/README.md, sub/d.md from above, e.md in sub/README.md) is listed; c.md is still not" "$(lintin $RC 2>&1 | grep 'not listed' | sed 's/: warn.*//; s#superdoc/##' | sort | tr '\n' ' ')" "features/c.md:1 "
printf '# Arch\n\n- [C](c.md)\n' > $RC/superdoc/architecture/README.md
check "README listing: a README in another directory does not list the page" "$(lintin $RC 2>&1 | grep 'not listed' | sed 's/: warn.*//; s#superdoc/##' | sort | tr '\n' ' ')" "features/c.md:1 "
printf '# README\n\n- [C](features/c.md)\n' >> $RC/superdoc/README.md
check "README listing: the doc-root README still lists a page by its path" "$(lintin $RC 2>&1 | grep -c 'not listed')" "0"
check "README listing: the per-directory README files themselves are never reported" "$(lintin $RC 2>&1 | grep -c 'README.md:1: warn')" "0"
rm $DR/superdoc/README.md
check "lint all: no README.md, no 'not listed' findings" "$(lintin $DR 2>&1 | grep -c 'not listed')" "0"
check "lint --files: the dangling ref is reported when CLAUDE.md is given, not otherwise" "$(lintin $DR --files CLAUDE.md 2>&1 | grep -c ': warn: dangling')/$(lintin $DR --files superdoc/features/b.md 2>&1 | grep -c ': warn: dangling')" "1/0"
check "lint --force-load: the Step 1 report, labelled files and total" "$(lintin $T/fl_ok --doc superdoc --force-load | grep -c '^force-loaded')" "6"

# --- custom doc root -----------------------------------------------------------------------------------
CD=$T/lcd; rm -rf $CD; mkdir -p $CD/handbook/meta $CD/handbook/features
printf '# P\n@handbook/meta/TERMINOLOGY.md\n' > $CD/CLAUDE.md
printf '# T\n' > $CD/handbook/meta/TERMINOLOGY.md; printf '/home/%s/x\n' $SENT > $CD/handbook/features/l.md
check "lint: the doc root is derived from the @.../meta/TERMINOLOGY.md ref in CLAUDE.md" "$(lintin $CD 2>&1 | grep -c '^handbook/features/l.md:1: error: home path$')" "1"
printf '# P\n@handbook/claude-instructions/documentation.md\n' > $CD/CLAUDE.md; rm $CD/handbook/meta/TERMINOLOGY.md
check "lint: ... or from a @.../claude-instructions/ ref" "$(lintin $CD 2>&1 | grep -c '^handbook/features/l.md:1: error')" "1"
printf '# P\nnothing\n' > $CD/CLAUDE.md
check "lint: --doc names the folder explicitly (trailing slash too)" "$(lintin $CD --doc handbook 2>&1 | grep -c '^handbook/features/l.md:1: error')/$(lintin $CD --doc handbook/ 2>&1 | grep -c '^handbook/features/l.md:1: error')" "1/1"
check "lint: without --doc and without any ref or marker, handbook/ is not guessed" "$(lintin $CD 2>&1)" ""
mkdir -p $CD/superdoc; printf 'x\n' > $CD/superdoc/p.md
check "lint: superdoc/ wins over a derived folder" "$(printf '# P\n@handbook/meta/TERMINOLOGY.md\n' > $CD/CLAUDE.md; lintin $CD 2>&1 | grep -c handbook)" "0"
printf '# P\n<!-- superdoc:start v4 -->\n@superdoc/gone.md\n<!-- superdoc:end -->\n' > $CD/CLAUDE.md; rm -rf $CD/superdoc
check "lint: a superdoc marker without a doc folder still checks CLAUDE.md (dangling ref)" "$(lintin $CD 2>&1 | grep -c '^CLAUDE.md:3: warn: dangling')" "1"

# --- git modes: --staged and --range ----------------------------------------------------------------------
gfix() { # dir : a git repo with superdoc/
  rm -rf "$1"; mkdir -p "$1/superdoc/features" "$1/sub"; (cd "$1" && git init -q && git config user.email t@t.t && git config user.name t && git config commit.gpgsign false)
}
GS=$T/lgs; gfix $GS
printf '# T\nold /home/olddebt/x\nclean\n' > $GS/superdoc/features/leak.md; printf '<!-- superdoc:start v4 -->\n' > $GS/CLAUDE.md
(cd $GS && git add -A && git commit -qm base)
printf '# T\nnew %s@corp-%s.io\nold /home/olddebt/x\nclean\nadded 10.77.66.55\n' $SENT $SENT > $GS/superdoc/features/leak.md
printf 'outside /home/%s/x\n' $SENT > $GS/sub/outside.md
printf '# P\nclaude /home/%s/x\n' $SENT >> $GS/CLAUDE.md
(cd $GS && git add superdoc CLAUDE.md sub)
printf 'unstaged 10.1.1.1\n' >> $GS/superdoc/features/leak.md
out_s=$(lintin $GS --staged 2>&1); rc_s=$?
check "lint --staged: only lines ADDED in the index, with real line numbers (old debt on untouched lines is quiet; unstaged and out-of-tree changes ignored)" "$(printf '%s\n' "$out_s" | grep ': error' | sort | tr '\n' ' ')" "CLAUDE.md:3: error: home path superdoc/features/leak.md:2: error: email superdoc/features/leak.md:5: error: private IP "
check "lint --staged: exit 1, sentinel and source text never printed" "$rc_s/$(printf '%s\n' "$out_s" | grep -c "$SENT\|corp-\|77.66.55\|olddebt")" "1/0"
check "lint --staged: no commit is mentioned (it is not a range finding)" "$(printf '%s\n' "$out_s" | grep -c 'commit')" "0"
check "lint --staged: works from a subdirectory (cwd-relative root)" "$(cd $GS/sub && "$LINT" --staged 2>&1 | grep -c ': error')" "3"
check "lint --staged: nothing staged is a quiet exit 0" "$(cd $GS && git reset -q && "$LINT" --staged 2>&1; echo rc=$?)" "rc=0"
# hunk headers: an insert in the middle of a file and an append at the end
printf '# T\nold /home/olddebt/x\nclean\nl4\nl5\nl6\n' > $GS/superdoc/features/m.md; (cd $GS && git add superdoc/features/m.md && git commit -qm m)
printf '# T\nold /home/olddebt/x\nins a\nins 10.88.2.2\nclean\nl4\nl5\nl6\nn9 10.88.1.1\n' > $GS/superdoc/features/m.md
(cd $GS && git add superdoc/features/m.md)
check "lint --staged: line numbers follow the hunk headers (insert in the middle, append at the end)" "$(lintin $GS --staged 2>&1 | grep 'features/m.md' | sed 's/^[^:]*://; s/: error.*//' | tr '\n' ' ')" "4 9 "
(cd $GS && git commit -qm m2)

# --range: the net diff is clean, the pushed commits are not
GR=$T/lgr; gfix $GR
printf '<!-- superdoc:start v4 -->\n' > $GR/CLAUDE.md; printf '# T\nclean\n' > $GR/superdoc/features/a.md; (cd $GR && git add -A && git commit -qm c1)
c1=$(cd $GR && git rev-parse HEAD)
printf '# T\nclean\nleak /home/%s/x\n' $SENT > $GR/superdoc/features/a.md; (cd $GR && git commit -qam c2)
c2s=$(cd $GR && git log -1 --format=%h)
printf '# T\nclean\n' > $GR/superdoc/features/a.md; (cd $GR && git commit -qam c3)
out_r=$(lintin $GR --range "$c1..HEAD" 2>&1); rc_r=$?
check "lint --range: a value added in one commit and removed in a later one is still found (not the net diff), with the commit" "$(printf '%s\n' "$out_r" | grep ': error')" "superdoc/features/a.md:3: error: home path (commit $c2s)"
check "lint --range: exit 1, the sentinel is never printed" "$rc_r/$(printf '%s\n' "$out_r" | grep -c "$SENT")" "1/0"
printf '%s\n' "$out_r" | grep -q '^fix: .*local commit.*repairing the file does not remove it.*rewritten before pushing.*user.s decision.*lead' && ok "lint --range: a finding in a commit gets the rewrite-the-commit fix line (the user's decision, via the lead)" || bad "lint --range: commit fix line ($out_r)"
check "lint --range: the net diff of the same range is clean (a net-diff check would have missed it)" "$(cd $GR && git diff $c1 HEAD -- superdoc CLAUDE.md | grep -c "$SENT")" "0"
check "lint --range: a range after the leaking commits is clean" "$(lintin $GR --range "HEAD~1..HEAD" 2>&1; echo rc=$?)" "rc=0"
check "lint --range: a leak in a commit at or before A is old debt, not reported" "$(lintin $GR --range "$c2s..HEAD" 2>&1 | grep -c ': error')" "0"
# root commit and the empty-tree start
GT=$T/lgt; gfix $GT
printf '# T\nroot /home/%s/x\n' $SENT > $GT/superdoc/features/r.md; printf '<!-- superdoc:start v4 -->\n' > $GT/CLAUDE.md; (cd $GT && git add -A && git commit -qm root)
rs=$(cd $GT && git log -1 --format=%h); et=$(cd $GT && git hash-object -t tree /dev/null)
check "lint --range: the root commit is scanned from the empty tree" "$(lintin $GT --range "$et..HEAD" 2>&1 | grep ': error')" "superdoc/features/r.md:2: error: home path (commit $rs)"
check "lint --range: ... and from an all-zero start (new branch)" "$(lintin $GT --range "0000000000000000000000000000000000000000..HEAD" 2>&1 | grep -c "(commit $rs)")" "1"
lintin $GT --range "nosuchrev..HEAD" >/dev/null 2>&1; check "lint --range: an unknown revision is exit 2" "$?" "2"
check "lint: no leak text from any mode (range, whole tree, --files, --staged)" "$( { lintin $GT --range "$et..HEAD"; lintin $GT; lintin $GT --files superdoc/features/r.md; lintin $GT --staged; } 2>&1 | grep -c "$SENT")" "0"
# a repo with no superdoc: silent, in every mode
GN=$T/lgn; gfix $GN; rm -rf $GN/superdoc; printf '# P\nmail a@corp.io /home/x1/y\n' > $GN/CLAUDE.md; (cd $GN && git add -A && git commit -qm n)
check "lint: a git repo with no superdoc folder and no marker is silent, exit 0, in every mode" "$( { lintin $GN; lintin $GN --staged; lintin $GN --range "HEAD..HEAD"; lintin $GN --files CLAUDE.md; } 2>&1; echo rc=$?)" "rc=0"

# --- git hook environment and linked worktrees ---------------------------------------------------------------
GH=$T/lgh; gfix $GH; printf '<!-- superdoc:start v4 -->\n' > $GH/CLAUDE.md; printf '# T\nclean\n' > $GH/superdoc/features/a.md; (cd $GH && git add -A && git commit -qm base)
printf '#!/bin/sh\nexec "%s" --staged\n' "$LINT" > $GH/.git/hooks/pre-commit; chmod +x $GH/.git/hooks/pre-commit
printf '# T\nclean\nleak /home/%s/x\n' $SENT > $GH/superdoc/features/a.md
out_h=$(cd $GH/sub && git add ../superdoc && git commit -qm leak 2>&1); rc_h=$?
check "lint as a pre-commit hook (commit run from a subdirectory): blocks the commit, names file:line:kind, prints no value" "$([ $rc_h -ne 0 ] && echo blocked)/$(printf '%s\n' "$out_h" | grep -c '^superdoc/features/a.md:3: error: home path$')/$(printf '%s\n' "$out_h" | grep -c "$SENT")" "blocked/1/0"
printf '# T\nclean\nleak /home/%s/x <!-- superdoc-lint: allow -->\n' $SENT > $GH/superdoc/features/a.md
(cd $GH && git add superdoc && git commit -qm ok >/dev/null 2>&1); check "lint as a pre-commit hook: superdoc-lint: allow lets a true false positive through" "$(cd $GH && git log --oneline | wc -l | tr -d ' ')" "2"
# the hook env set by hand (GIT_DIR, GIT_INDEX_FILE relative to the root)
printf '# T\nclean\nleak /home/%s/x <!-- superdoc-lint: allow -->\nagain 10.5.5.5\n' $SENT > $GH/superdoc/features/a.md; (cd $GH && git add superdoc)
check "lint with GIT_DIR/GIT_INDEX_FILE set (relative, as a hook sees them): still finds the staged line" "$(cd $GH && GIT_DIR=.git GIT_INDEX_FILE=.git/index "$LINT" --staged 2>&1 | grep -c '^superdoc/features/a.md:4: error: private IP')" "1"
(cd $GH && git reset -q && git checkout -q superdoc)
# linked worktree
(cd $GH && git worktree add -q $T/lgh-wt -b wt >/dev/null 2>&1)
printf '# T\nwt 10.6.6.6\n' > $T/lgh-wt/superdoc/features/a.md; (cd $T/lgh-wt && git add superdoc)
check "lint works from a linked worktree (and its subdirectories): --staged and the whole tree" "$(cd $T/lgh-wt && "$LINT" --staged 2>&1 | grep -c '^superdoc/features/a.md:2: error: private IP')/$(mkdir -p $T/lgh-wt/sub && cd $T/lgh-wt/sub && "$LINT" 2>&1 | grep -c '^superdoc/features/a.md:2: error: private IP')" "1/1"
check "lint --range works from a linked worktree" "$(cd $T/lgh-wt && git commit -q --no-verify -m wt >/dev/null 2>&1; "$LINT" --range 'HEAD~1..HEAD' 2>&1 | grep -c '(commit ')" "1"

# --- Step 1 and Part 9 reuse lint.sh -------------------------------------------------------------------------
grep -q 'lint.sh" --doc "\$DOC" --force-load' "$SD" && ok "SKILL Step 1: the force-load report is lint.sh --force-load" || bad "SKILL Step 1: lint.sh call"
printf '%s' "$SDN" | grep -q 'starting from `lint.sh` output' && ok "SKILL Step 3: audits start from lint.sh output" || bad "SKILL Step 3: lint.sh"
P9=$(awk '/^## Part 9/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
P8=$(awk '/^## Part 8/{f=1;next} /^## /{f=0} f' "$PB" | tr '\n' ' ' | sed 's/  */ /g')
printf '%s' "$P9" | grep -q 'Start from `lint.sh` output' && printf '%s' "$P9" | grep -q 'never the value' && printf '%s' "$P9" | grep -q 'superdoc-lint: allow. is skipped: for a true false positive only, never for a real value' && ok "Part 9: starts from lint.sh, never the value, the allow marker is for false positives only" || bad "Part 9: lint.sh bullet"
printf '%s' "$P8" | grep -q '`lint.sh` run first' && ok "Part 8: gate starts from lint.sh" || bad "Part 8: lint.sh box"
printf '%s' "$P9" | grep -q 'lint.sh. lists every entry over ~300 characters' && printf '%s' "$P9" | grep -q 'Keep every entry short' && ok "Part 9: the TERMINOLOGY bullet points at lint.sh and keeps the short-entry-rule check" || bad "Part 9: TERMINOLOGY bullet"
printf '%s' "$P9" | grep -q 'Identity values of this machine' && ok "Part 9: the identity-values pass stays in the playbook (a script cannot know)" || bad "Part 9: identity pass"
printf '%s' "$P9" | grep -q 'never quoting the value' && ok "Part 9: the never-quote-the-value rule is kept" || bad "Part 9: never quote"

echo "== superdoc: bare home paths and --push (lint.sh) =="
BH=$T/lbh; mklf $BH; (cd $BH && git init -q)
bhc() { # label line want(0|1)
  printf '# T\n%s\n' "$2" > $BH/superdoc/features/t.md
  local n; n=$(lintin $BH 2>&1 | grep -c ': error: home path$'); check "lint bare home path: $1" "$n" "$3"
}
bhc "cd /home/NAME is an error" "cd /home/$SENT" 1
bhc "/Users/NAME at a word boundary is an error" "open /Users/$SENT now" 1
bhc "(/home/NAME) in parentheses is an error" "see (/home/$SENT)" 1
bhc "/home/NAME. at the end of a sentence is an error" "it lives in /home/$SENT." 1
bhc "/home/NAME/ with a slash still is" "cd /home/$SENT/x" 1
bhc "the allowlist still applies (/home/user, /home/username)" "cd /home/user and /home/username" 0
bhc "a placeholder is not a name (/home/<name>, /home/\$USER, /home/{u}, /home/...)" 'cd /home/<name> /home/$USER /home/{u} /home/...' 0
bhc "a path character before the slash excludes it (example.com/home/NAME, a/home/NAME)" "see example.com/home/$SENT and a/home/$SENT" 0
bhc "/home alone and /homes/NAME are not host paths" "cd /home/ and /homes/$SENT" 0
bhc "superdoc-lint: allow skips the line" "cd /home/$SENT <!-- superdoc-lint: allow -->" 0
check "lint bare home path: the value is never printed" "$(printf '# T\ncd /home/%s\n' $SENT > $BH/superdoc/features/t.md; lintin $BH 2>&1 | grep -c "$SENT")" "0"

# --push REF REMOTE: only the commits no remote-tracking ref of REMOTE has
PR=$T/lpr; PRR=$T/lpr-remote.git; gfix $PR; git init -q --bare $PRR; (cd $PR && git remote add origin $PRR)
printf '<!-- superdoc:start v4 -->\n' > $PR/CLAUDE.md; printf '# T\nold /home/olddebt/x\nclean\n' > $PR/superdoc/features/a.md
(cd $PR && git add -A && git commit -qm base && git push -q origin HEAD:refs/heads/master >/dev/null 2>&1; git fetch -q origin)
(cd $PR && git checkout -qb nb && printf 'new\n' >> $PR/superdoc/features/a.md && git commit -qam clean)
check "lint --push: a new branch with a clean commit does not scan the old debt (exit 0, silent)" "$(lintin $PR --push nb origin 2>&1; echo rc=$?)" "rc=0"
(cd $PR && printf 'cd /home/%s\n' $SENT >> superdoc/features/a.md && git commit -qam leak)
pushout=$(lintin $PR --push nb origin 2>&1); pushrc=$?
check "lint --push: a leaking commit on the new branch is found, with the commit, exit 1" "$pushrc/$(printf '%s\n' "$pushout" | grep -c '^superdoc/features/a.md:5: error: home path (commit ')/$(printf '%s\n' "$pushout" | grep -c "$SENT\|olddebt")" "1/1/0"
check "lint --push: an unknown remote name falls back to all remote-tracking refs (still not the old debt)" "$(lintin $PR --push nb nosuchremote 2>&1 | grep -c ': error')" "1"
lintin $PR --push nosuchref origin >/dev/null 2>&1; check "lint --push: a bad ref is exit 2" "$?" "2"
lintin $PR --push nb >/dev/null 2>&1; check "lint --push: a missing REMOTE is exit 2" "$?" "2"

echo "== superdoc enforcement: native git hooks (Layer A) =="
# wired project, teamlead active, one clean commit
sgmk() {
  gfix "$1"; printf '# P\n<!-- superdoc:start v4 -->\n<!-- superdoc:end -->\n' > "$1/CLAUDE.md"
  printf '# A\nclean\n' > "$1/superdoc/features/a.md"
  mkdir -p "$1/.claude/teamlead/.state"; : > "$1/.claude/teamlead/.state/active"
  (cd "$1" && git add CLAUDE.md superdoc && git commit -qm base)
}
sgrestore() { # dir [source]
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"s1","cwd":"%s"}' "${2:-startup}" "$1" | env -u CLAUDE_PROJECT_DIR "$H/restore.sh" 2>&1
}
sgleakline() { printf 'cd /home/%s\n' $SENT; }
W=$T/sgw; sgmk $W
out_r1=$(sgrestore $W)
check "stubs: pre-commit, pre-merge-commit and pre-push are installed, executable, marked" "$(for h in pre-commit pre-merge-commit pre-push; do [ -x $W/.git/hooks/$h ] && grep -q '^# managed by teamlead' $W/.git/hooks/$h && printf y; done)" "yyy"
check "stubs: installing prints nothing about superdoc" "$(printf '%s\n' "$out_r1" | grep -c 'superdoc')" "0"
ino1=$(stat -c %i $W/.git/hooks/pre-push); out_r1b=$(sgrestore $W resume); ino2=$(stat -c %i $W/.git/hooks/pre-push)
check "stubs: a second session start with the same plugin root rewrites nothing" "$ino1" "$ino2"
mkdir -p $T/plugv2/skills/teamlead-superdoc; cp "$LINT" $T/plugv2/skills/teamlead-superdoc/lint.sh
printf '%s\n' "$(printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"s1","cwd":"%s"}' $W | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT=$T/plugv2 "$H/restore.sh" 2>&1 | grep -c 'superdoc')" > $T/sg_v2out
check "stubs: a new plugin root (version change) re-writes all three, pointing at the new lint.sh; no message" "$(grep -c "$T/plugv2/skills/teamlead-superdoc/lint.sh" $W/.git/hooks/pre-commit $W/.git/hooks/pre-merge-commit $W/.git/hooks/pre-push | tr '\n' ' ' | sed "s#$W/.git/hooks/##g")/$(cat $T/sg_v2out)" "pre-commit:1 pre-merge-commit:1 pre-push:1 /0"
sgrestore $W startup >/dev/null   # back to the real plugin root
# foreign hook, core.hooksPath
SF=$T/sgforeign; sgmk $SF; printf '#!/bin/sh\necho foreign-hook\n' > $SF/.git/hooks/pre-push; chmod +x $SF/.git/hooks/pre-push
out_f=$(sgrestore $SF)
check "stubs: a hook without the marker is never overwritten" "$(grep -c foreign-hook $SF/.git/hooks/pre-push)/$(grep -c 'managed by teamlead' $SF/.git/hooks/pre-push)" "1/0"
check "stubs: the others are still installed, and ONE line names the hook that could not be" "$([ -x $SF/.git/hooks/pre-commit ] && printf y)/$(printf '%s\n' "$out_f" | grep -c '^\[teamlead\] superdoc: could not install the git hook(s): pre-push ')" "y/1"
SH=$T/sghp; sgmk $SH; (cd $SH && git config core.hooksPath .githooks)
out_h=$(sgrestore $SH)
check "stubs: core.hooksPath set installs nothing and says so in one line" "$(ls $SH/.git/hooks | grep -c '^pre-[a-z-]*$')/$(printf '%s\n' "$out_h" | grep -c '^\[teamlead\] superdoc: core.hooksPath is set')" "0/1"
# fail open
SO=$T/sgopen; sgmk $SO; mkdir -p $T/plugv3
printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"s1","cwd":"%s"}' $SO | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT=$T/plugv3 "$H/restore.sh" >/dev/null 2>&1
printf 'cd /home/%s\n' $SENT >> $SO/superdoc/features/a.md
out_o=$(cd $SO && git commit -qam 'leak but no lint.sh' 2>&1); rc_o=$?
check "stubs: lint.sh gone (plugin uninstalled) fails OPEN with a stderr note: the commit goes through" "$rc_o/$(printf '%s\n' "$out_o" | grep -c 'lint.sh not found, leak check skipped')" "0/1"
# unwired: nothing installed, nothing blocks, even with an unmarked superdoc/ holding a leak
UW=$T/sguw; sgmk $UW; printf '# P\n' > $UW/CLAUDE.md; (cd $UW && git commit -qam unwire)
out_u=$(sgrestore $UW)
printf 'cd /home/%s\n' $SENT >> $UW/superdoc/features/a.md
out_uc=$(cd $UW && git commit -qam 'unmarked docs are not ours' 2>&1); rc_uc=$?
check "unwired (no superdoc:start): no hooks installed, no message, the commit is not blocked" "$(ls $UW/.git/hooks | grep -c '^pre-[a-z-]*$')/$(printf '%s\n' "$out_u" | grep -c 'superdoc')/$rc_uc" "0/0/0"
# stubs left behind after the project is unwired: unmarked superdoc/ is someone else's docs and never blocks
uwk() { # dir variant : a wired project with native stubs, then unwired (variant: unmark | nofile; an older branch with hand-written docs is the same state: no marker in the work tree)
  sgmk "$1"; sgrestore "$1" >/dev/null
  case $2 in
    unmark) printf '# P\n' > "$1/CLAUDE.md"; (cd "$1" && git add CLAUDE.md && git commit -qm unmark --no-verify) ;;
    nofile) (cd "$1" && git rm -q CLAUDE.md && git commit -qm nofile --no-verify) ;;
  esac
  printf 'cd /home/%s\n' $SENT >> "$1/superdoc/features/a.md"
}
for uv in unmark nofile; do
  UK=$T/sguk-$uv; uwk $UK $uv
  out_uk=$(cd $UK && git add superdoc && git commit -qm "leak in unmarked docs" 2>&1); rc_uk=$?
  check "unwired ($uv): the native pre-commit stub left in .git/hooks does not block a staged leak" "$rc_uk/$(printf '%s\n' "$out_uk" | grep -c ': error')/$(printf '%s\n' "$out_uk" | grep -c "$SENT")" "0/0/0"
done
UK=$T/sguk-unmark; printf 'cd /home/%s\n' $SENT >> $UK/superdoc/features/a.md; (cd $UK && git add superdoc)
out_uk=$(lintin $UK --staged 2>&1); check "lint --staged on an unmarked project: silent, exit 0" "$?/$out_uk" "0/"
out_uk=$(lintin $UK --range "HEAD~1..HEAD" 2>&1); check "lint --range on an unmarked project: silent, exit 0 (even for a bad revision)" "$?/$out_uk/$(lintin $UK --range nosuchrev..HEAD 2>&1; echo $?)" "0//0"
out_uk=$(lintin $UK --push master origin 2>&1); check "lint --push on an unmarked project: silent, exit 0" "$?/$out_uk" "0/"
out_uk=$(lintin $UK --doc superdoc --staged 2>&1); check "lint --doc superdoc --staged on an unmarked project: an explicit --doc still runs (exit 1, kind printed, no value)" "$?/$(printf '%s\n' "$out_uk" | grep -c ': error: home path$')/$(printf '%s\n' "$out_uk" | grep -c "$SENT")" "1/1/0"
check "lint: whole tree, --files and --force-load on an unmarked project are unchanged (audits use them)" "$(lintin $UK 2>&1 | grep -c ': error: home path')/$(lintin $UK --files superdoc/features/a.md 2>&1 | grep -c ': error: home path')/$(lintin $UK --force-load 2>&1 | grep -c '^force-loaded total')" "2/2/1"
check "lint --staged on a wired project still blocks (marker present)" "$(cd $T/sguk-unmark && printf '# P\n<!-- superdoc:start v4 -->\n' > CLAUDE.md && git add CLAUDE.md && "$LINT" --staged 2>&1 | grep -c ': error: home path$')" "1"

# a real commit
n0=$(cd $W && git rev-list --count HEAD)
sgleakline >> $W/superdoc/features/a.md
out_c=$(cd $W && git add superdoc && git commit -qm leak 2>&1); rc_c=$?
check "commit with a seeded leak is blocked: names file:line:kind, prints no value, the commit does not exist" "$([ $rc_c -ne 0 ] && echo blocked)/$(printf '%s\n' "$out_c" | grep -c '^superdoc/features/a.md:3: error: home path$')/$(printf '%s\n' "$out_c" | grep -c "$SENT")/$(cd $W && git rev-list --count HEAD)" "blocked/1/0/$n0"
printf '# A\nclean\nmore\n' > $W/superdoc/features/a.md
(cd $W && git add superdoc && git commit -qm clean >/dev/null 2>&1); check "a clean commit goes through" "$(cd $W && git rev-list --count HEAD)" "$((n0+1))"
# from a linked worktree: hooks live in the common dir
(cd $W && git worktree add -q $T/sgw-wt -b wtb >/dev/null 2>&1)
sgleakline >> $T/sgw-wt/superdoc/features/a.md
out_wt=$(cd $T/sgw-wt && git add superdoc && git commit -qm leak 2>&1); rc_wt=$?
check "commit from a linked worktree is blocked by the hook in the common dir" "$([ $rc_wt -ne 0 ] && echo blocked)/$(printf '%s\n' "$out_wt" | grep -c '^superdoc/features/a.md:[0-9]*: error: home path$')" "blocked/1"
(cd $T/sgw-wt && git reset -q && git checkout -q -- superdoc); printf 'wt\n' >> $T/sgw-wt/superdoc/features/a.md
(cd $T/sgw-wt && git commit -qam 'clean in a worktree' >/dev/null 2>&1); check "  ... and a clean commit there goes through" "$(cd $T/sgw-wt && git log --oneline | grep -c 'clean in a worktree')" "1"

# a real non-fast-forward merge
base_w=$(cd $W && git rev-parse HEAD)
(cd $W && git checkout -qb feat && sgleakline >> superdoc/features/a.md && git commit -qa --no-verify -m featleak && git checkout -q master)
printf 'x\n' > $W/src.txt; (cd $W && git add src.txt && git commit -qm diverge)
head_m=$(cd $W && git rev-parse HEAD)
out_m=$(cd $W && git merge feat -m merge 2>&1); rc_m=$?
(cd $W && git merge --abort >/dev/null 2>&1; git reset -q --hard)
check "a real non-ff merge that brings in a leak is blocked (pre-merge-commit), value not printed, HEAD unmoved" "$([ $rc_m -ne 0 ] && echo blocked)/$(printf '%s\n' "$out_m" | grep -c ': error: home path')/$(printf '%s\n' "$out_m" | grep -c "$SENT")/$([ "$(cd $W && git rev-parse HEAD)" = "$head_m" ] && echo same)" "blocked/1/0/same"
(cd $W && git checkout -q -b okb $base_w && printf 'c\n' > superdoc/features/c.md && git add superdoc && git commit -qm okc && git checkout -q master)
(cd $W && git merge okb -m okmerge >/dev/null 2>&1); check "a real non-ff merge of a clean branch is allowed" "$(cd $W && git log -1 --format=%p | wc -w | tr -d ' ')" "2"
# git runs no hook for a fast-forward: why superdoc-guard.sh exists
(cd $W && git checkout -q -b fff && sgleakline >> superdoc/features/c.md && git commit -qa --no-verify -m ffleak && git checkout -q master && git reset -q --hard HEAD)
(cd $W && git checkout -q -B ffm master && git merge -q --ff-only fff >/dev/null 2>&1); check "a fast-forward merge runs no native hook (so it is not blocked there: the Bash guard covers it)" "$(cd $W && git log -1 --format=%s)" "ffleak"
(cd $W && git checkout -q master && git branch -qD ffm)

# a real push to a local bare remote
PW=$T/sgp; PWR=$T/sgp-remote.git; sgmk $PW; git init -q --bare $PWR; (cd $PW && git remote add origin $PWR)
sgrestore $PW >/dev/null
(cd $PW && git push -q origin HEAD:refs/heads/master >/dev/null 2>&1); r0=$(cd $PWR && git rev-parse master 2>/dev/null)
check "a clean push is allowed" "$([ -n "$r0" ] && echo pushed)" "pushed"
(cd $PW && git fetch -q origin && git branch -q -u origin/master)
sgleakline >> $PW/superdoc/features/a.md; (cd $PW && git commit -qa --no-verify -m leak)
printf '# A\nclean\n' > $PW/superdoc/features/a.md; (cd $PW && git commit -qa -m 'removed again' >/dev/null 2>&1)
out_p=$(cd $PW && git push origin master 2>&1); rc_p=$?
check "add-then-remove across commits still blocks the push (each commit is read, not the net diff); the remote is unchanged; no value printed" "$([ $rc_p -ne 0 ] && echo blocked)/$(printf '%s\n' "$out_p" | grep -c ': error: home path (commit ')/$([ "$(cd $PWR && git rev-parse master)" = "$r0" ] && echo same)/$(printf '%s\n' "$out_p" | grep -c "$SENT")" "blocked/1/same/0"
(cd $PW && git reset -q --hard origin/master && printf 'ok\n' >> superdoc/features/a.md && git commit -qam ok >/dev/null 2>&1)
(cd $PW && git push -q origin master >/dev/null 2>&1); check "a clean push after resetting the leak away is allowed" "$([ "$(cd $PWR && git rev-parse master)" = "$(cd $PW && git rev-parse HEAD)" ] && echo pushed)" "pushed"
# old debt on the remote, then new branches
PD=$T/sgd; PDR=$T/sgd-remote.git; sgmk $PD; git init -q --bare $PDR; (cd $PD && git remote add origin $PDR)
sgleakline >> $PD/superdoc/features/a.md; (cd $PD && git commit -qa -m olddebt --no-verify && git push -q --no-verify origin HEAD:refs/heads/master >/dev/null 2>&1 && git fetch -q origin)
sgrestore $PD >/dev/null
(cd $PD && git checkout -qb nb1 && printf 'more\n' > superdoc/features/b.md && git add superdoc && git commit -qm clean >/dev/null 2>&1)
out_nb=$(cd $PD && git push origin nb1 2>&1); rc_nb=$?
check "a NEW branch does not block on old debt that the remote already has" "$rc_nb/$([ -n "$(cd $PDR && git rev-parse -q --verify refs/heads/nb1)" ] && echo pushed)" "0/pushed"
(cd $PD && git checkout -qb nb2 && printf 'cd /home/%s\n' $SENT > superdoc/features/b.md && git add superdoc && git commit -qm newleak --no-verify)
out_nb2=$(cd $PD && git push origin nb2 2>&1); rc_nb2=$?
check "  ... but a new branch whose own commit leaks is blocked" "$([ $rc_nb2 -ne 0 ] && echo blocked)/$(printf '%s\n' "$out_nb2" | grep -c ': error: home path (commit ')/$(printf '%s\n' "$out_nb2" | grep -c "$SENT")/$([ -z "$(cd $PDR && git rev-parse -q --verify refs/heads/nb2)" ] && echo absent)" "blocked/1/0/absent"
out_del=$(cd $PD && git push origin --delete nb1 2>&1); check "  ... and deleting a remote branch is not scanned" "$?" "0"

echo "== superdoc enforcement: the Bash guard (Layer B) =="
sgguard() { # dir command -> hook output; the hook is fed the real PreToolUse shape
  jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | env -u CLAUDE_PROJECT_DIR "$H/superdoc-guard.sh" 2>&1
}
sgverdict() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
check "hooks.json: exactly one Bash PreToolUse matcher, running superdoc-guard.sh" "$(jq -r '[.hooks.PreToolUse[]|select(.matcher=="Bash")]|map(.hooks[].command)|join(",")' "$H/hooks.json")" '${CLAUDE_PLUGIN_ROOT}/hooks/superdoc-guard.sh'
[ -x "$H/superdoc-guard.sh" ] && ok "superdoc-guard.sh is executable" || bad "superdoc-guard.sh is not executable"
G=$T/sgg; sgmk $G    # wired, NO native hooks installed (restore never ran): the guard is the only cover
sgleakline >> $G/superdoc/features/a.md; (cd $G && git add superdoc)
g1=$(sgguard $G 'git commit --no-verify -m leak')
check "guard: git commit --no-verify with a staged leak is denied" "$(sgverdict "$g1")" "deny"
check "  the reason names file:line:kind and never the value" "$(printf '%s' "$g1" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c '^superdoc/features/a.md:3: error: home path$')/$(printf '%s' "$g1" | grep -c "$SENT")" "1/0"
check "  the reason is a message to the agent, not a question to the user" "$(printf '%s' "$g1" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -ci 'would you\|do you want\|ask the user')" "0"
check "guard: the deny JSON has the shape board-fence.sh uses (PreToolUse event name)" "$(printf '%s' "$g1" | jq -r .hookSpecificOutput.hookEventName)" "PreToolUse"
check "guard: git -C DIR commit, from another cwd, is denied" "$(sgverdict "$(sgguard $T "git -C $G commit --no-verify -m x")")" "deny"
check "guard: cd DIR && git commit, from another cwd, is denied" "$(sgverdict "$(sgguard $T "cd $G && git commit --no-verify -m x")")" "deny"
check "guard: a chained command (git add . && git commit) is parsed too" "$(sgverdict "$(sgguard $G 'git add -A && git commit --no-verify -m x')")" "deny"
check "guard: staged-only leak, command is git commit -m with a message mentioning push" "$(sgverdict "$(sgguard $G 'git commit -m "docs: do not git push yet"')")" "deny"
check "guard: unrelated Bash is silent (ls, git status, git log, grep commit)" "$(for c in 'ls -la' 'git status' 'git log --oneline' 'grep -rn commit .' 'echo git push'; do sgguard $G "$c"; done | wc -c | tr -d ' ')" "0"
(cd $G && git reset -q && git checkout -q -- superdoc)
check "guard: nothing staged, git commit is silent" "$(sgguard $G 'git commit -m nothing' | wc -c | tr -d ' ')" "0"
sgleakline >> $G/superdoc/features/a.md   # tracked, modified, NOT staged
check "guard: git commit -am sees what -a will stage (unstaged tracked leak) and denies" "$(sgverdict "$(sgguard $G 'git commit -am x')")/$(sgverdict "$(sgguard $G 'git commit -m x -a')")/$(sgverdict "$(sgguard $G 'git commit -ma')")" "deny/deny/"
check "guard: the temporary index is cleaned up" "$(ls $G/.git | grep -c 'tl-guard')" "0"
(cd $G && git checkout -q -- superdoc)
printf 'fine\n' >> $G/superdoc/features/a.md; (cd $G && git add superdoc)
check "guard: a clean staged commit is silent" "$(sgguard $G 'git commit --no-verify -m clean' | wc -c | tr -d ' ')" "0"
(cd $G && git commit -qm clean >/dev/null 2>&1)
# merges: a fast-forward is where git runs no hook
(cd $G && git checkout -qb ffleak && sgleakline >> superdoc/features/a.md && git commit -qa -m ffleak --no-verify && git checkout -q master)
g_ff=$(sgguard $G 'git merge ffleak')
check "guard: a fast-forward merge of a leaking branch is denied (no native hook exists for it)" "$(sgverdict "$g_ff")/$(printf '%s' "$g_ff" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c ': error: home path (commit ')/$(printf '%s' "$g_ff" | grep -c "$SENT")" "deny/1/0"
check "  git merge --no-ff -m x BRANCH and git merge --squash BRANCH likewise" "$(sgverdict "$(sgguard $G 'git merge --no-ff -m x ffleak')")/$(sgverdict "$(sgguard $G 'git merge --squash ffleak')")" "deny/deny"
check "  git merge --abort and an unknown ref are silent" "$(sgguard $G 'git merge --abort'; sgguard $G 'git merge nosuchbranch')" ""
(cd $G && git checkout -qb okff && printf 'ok\n' > superdoc/features/z.md && git add superdoc && git commit -qm ok --no-verify && git checkout -q master)
check "guard: merging a clean branch is silent" "$(sgguard $G 'git merge okff' | wc -c | tr -d ' ')" "0"
# pushes: with and without an upstream
GP=$T/sggp; GPR=$T/sggp-remote.git; sgmk $GP; git init -q --bare $GPR; (cd $GP && git remote add origin $GPR && git push -q origin HEAD:refs/heads/master >/dev/null 2>&1 && git fetch -q origin)
sgleakline >> $GP/superdoc/features/a.md; (cd $GP && git commit -qa -m leak --no-verify)
check "guard: git push of a new branch (no upstream) scans its own commits and denies" "$(sgverdict "$(sgguard $GP 'git push origin HEAD')")/$(sgverdict "$(sgguard $GP 'git push')")" "deny/deny"
(cd $GP && git branch -q -u origin/master)
check "guard: git push with an upstream scans @{u}..HEAD and denies; git push origin master too" "$(sgverdict "$(sgguard $GP 'git push')")/$(sgverdict "$(sgguard $GP 'git push origin master --no-verify')")" "deny/deny"
check "guard: deleting a remote branch is silent" "$(sgguard $GP 'git push origin --delete old' | wc -c | tr -d ' ')" "0"
(cd $GP && git reset -q --hard origin/master)
check "guard: nothing to push is silent" "$(sgguard $GP 'git push' | wc -c | tr -d ' ')" "0"
# not wired, and what it cannot parse
check "guard: an unwired project is never touched (leak staged, unmarked CLAUDE.md)" "$(printf 'cd /home/%s\n' $SENT >> $UW/superdoc/features/a.md; (cd $UW && git add superdoc); sgguard $UW 'git commit --no-verify -m x' | wc -c | tr -d ' ')" "0"
check "guard: an unresolvable cd target, a variable, a missing dir all pass silently" "$(sgguard $G 'cd "$SOMEWHERE" && git commit --no-verify -m x'; sgguard $G 'git -C /nonexistent/dir commit -m x'; sgguard /nonexistent 'git commit -m x')" ""
check "guard: not Bash (another tool name) is ignored" "$(jq -n --arg d $G '{tool_name:"Read",cwd:$d,tool_input:{command:"git commit"}}' | "$H/superdoc-guard.sh" 2>&1)" ""
check "guard: malformed stdin passes silently" "$(printf 'git commit {not json' | "$H/superdoc-guard.sh" 2>&1; echo rc=$?)" "rc=0"
check "guard: the sentinel never appears in any guard output above" "$( { sgguard $G 'git merge ffleak'; sgguard $GP 'git push origin HEAD'; } | grep -c "$SENT")" "0"

echo "== superdoc enforcement: findings once, on merge (gate.sh check 8) =="
sgstop() { printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$1" | env -u CLAUDE_PROJECT_DIR "$H/gate.sh" >"$T/sgout" 2>&1; echo $?; }
S=$T/sgs; sgmk $S
printf '# O\nold /mnt/%s/debt\n' olddebt > $S/superdoc/features/old.md; (cd $S && git add superdoc && git commit -qm olddebt)
check "gate: first run (no state file) is silent and records HEAD" "$(sgstop $S)/$(cat $T/sgout | wc -c | tr -d ' ')/$([ "$(cat $S/.claude/teamlead/.state/superdoc-lint-head)" = "$(cd $S && git rev-parse HEAD)" ] && echo head)" "0/0/head"
check "gate: no new commit is silent" "$(sgstop $S)/$(cat $T/sgout | wc -c | tr -d ' ')" "0/0"
(cd $S && git checkout -qb b1 && printf '# C\nclean\n' > superdoc/features/c.md && git add superdoc && git commit -qm c --no-verify && git checkout -q master && git merge -q --no-ff -m m1 b1)
check "gate: a clean merge is silent, and old debt in a file the merge did not touch is not reported" "$(sgstop $S)/$(cat $T/sgout | wc -c | tr -d ' ')" "0/0"
printf 'x\n' > $S/src.txt; (cd $S && git add src.txt && git commit -qm nondoc)
check "gate: a commit that touches no doc file is silent" "$(sgstop $S)/$(cat $T/sgout | wc -c | tr -d ' ')" "0/0"
(cd $S && git checkout -qb b2 && printf '# B\nsee /mnt/%s/x\n' $SENT > superdoc/features/b.md && git add superdoc && git commit -qm b --no-verify && git checkout -q master && git merge -q --no-ff -m m2 b2)
rc_g=$(sgstop $S)
check "gate: a merge that brings a warning fires: blocks, names file:line:kind, tells the agent it is theirs to judge, never asks the user" "$rc_g/$(grep -c '^ *superdoc/features/b.md:2: warn: host path$' $T/sgout)/$(grep -c 'do not ask the user' $T/sgout)/$(grep -c "$SENT" $T/sgout)" "2/1/1/0"
check "  the touched file's findings only: old debt in the untouched file is not in it" "$(grep -c 'old.md' $T/sgout)" "0"
check "  a warning-only finding carries no 'repair now, do not push' text" "$(grep -c 'got past the commit hooks' $T/sgout)" "0"
check "  it fires ONCE: the next Stop is silent and the state moved to HEAD" "$(sgstop $S)/$(cat $T/sgout | wc -c | tr -d ' ')/$([ "$(cat $S/.claude/teamlead/.state/superdoc-lint-head)" = "$(cd $S && git rev-parse HEAD)" ] && echo head)" "0/0/head"
(cd $S && git checkout -qb b3 && printf '# E\n' > superdoc/features/e.md && sgleakline >> superdoc/features/e.md && git add superdoc && git commit -qm e --no-verify && git checkout -q master && git merge -q --no-ff -m m3 b3)
rc_e=$(sgstop $S)
check "gate: an error in the merged range says a leak got past the commit hooks: repair now, do not push, and the history rewrite is the user's" "$rc_e/$(grep -c '^ *superdoc/features/e.md:2: error: home path (commit [0-9a-f]*)$' $T/sgout)/$(grep -c 'got past the commit hooks' $T/sgout)/$(grep -c 'do not push' $T/sgout)/$(grep -c "Rewriting history is theirs to decide" $T/sgout)/$(grep -c "$SENT" $T/sgout)" "2/1/1/1/1/0"
check "  and it fires once" "$(sgstop $S)" "0"
printf '%s\n' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > $S/.claude/teamlead/.state/superdoc-lint-head
check "gate: a recorded commit that is not an ancestor resets to HEAD and says nothing" "$(sgstop $S)/$(cat $T/sgout | wc -c | tr -d ' ')/$([ "$(cat $S/.claude/teamlead/.state/superdoc-lint-head)" = "$(cd $S && git rev-parse HEAD)" ] && echo head)" "0/0/head"
(cd $S && git checkout -qb b4 && printf '# D\nsee /mnt/%s/x\n' $SENT > superdoc/features/d.md && git add superdoc && git commit -qm d --no-verify && git checkout -q master && git merge -q --no-ff -m m4 b4)
mkdir -p $T/sgfake; printf '#!/bin/sh\nexit 124\n' > $T/sgfake/timeout; chmod +x $T/sgfake/timeout
last_before=$(cat $S/.claude/teamlead/.state/superdoc-lint-head)
rc_to=$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' $S | env -u CLAUDE_PROJECT_DIR PATH="$T/sgfake:$PATH" "$H/gate.sh" >"$T/sgout" 2>&1; echo $?)
check "gate: a lint timeout is quiet and leaves the state unadvanced" "$rc_to/$(cat $T/sgout | wc -c | tr -d ' ')/$([ "$(cat $S/.claude/teamlead/.state/superdoc-lint-head)" = "$last_before" ] && echo unmoved)" "0/0/unmoved"
check "  the next Stop retries and shows the finding" "$(sgstop $S)/$(grep -c '^ *superdoc/features/d.md:2: warn: host path$' $T/sgout)" "2/1"
check "gate: stop_hook_active still short-circuits" "$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":true}' $S | env -u CLAUDE_PROJECT_DIR "$H/gate.sh" >/dev/null 2>&1; echo $?)" "0"
US=$T/sgus; sgmk $US; printf '# P\n' > $US/CLAUDE.md; (cd $US && git commit -qam unwire)
sgstop $US >/dev/null; (cd $US && git checkout -qb x && printf 'cd /home/%s\n' $SENT > superdoc/features/a.md && git commit -qam x --no-verify && git checkout -q master && git merge -q --no-ff -m mx x)
check "gate: an unwired project is silent and records no state" "$(sgstop $US)/$(cat $T/sgout | wc -c | tr -d ' ')/$(ls $US/.claude/teamlead/.state | grep -c superdoc-lint-head)" "0/0/0"
# --- gate: pre-filter, errors only from the range, warnings from the files, 40-line cap ---------------
sgmerge() { # dir branch file content... : a branch that writes the files (content: printf %b), merged --no-ff into master
  local d=$1 b=$2; shift 2
  (cd "$d" && git checkout -qb "$b" && while [ $# -gt 0 ]; do mkdir -p "$(dirname "$1")"; printf '%b' "$2" > "$1"; git add -- "$1"; shift 2; done && git commit -qm "$b" --no-verify && git checkout -q master && git merge -q --no-ff -m "m-$b" "$b")
}
sgstate() { [ "$(cat $1/.claude/teamlead/.state/superdoc-lint-head)" = "$(cd $1 && git rev-parse HEAD)" ] && echo head || echo unmoved; }
# a wrapper plugin root that logs every lint.sh call, then runs the real one
FR=$T/sgfr; mkdir -p $FR/skills/teamlead-superdoc; ln -s "$CLAUDE_PLUGIN_ROOT/hooks" $FR/hooks; ln -s "$CLAUDE_PLUGIN_ROOT/scripts" $FR/scripts
printf '#!/bin/sh\necho "$*" >> "%s"\nexec bash "%s" "$@"\n' "$T/sgcalls" "$LINT" > $FR/skills/teamlead-superdoc/lint.sh
sgstopfr() { printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$1" | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT=$FR "$H/gate.sh" >"$T/sgout" 2>&1; echo $?; }
PF=$T/sgpf; sgmk $PF; sgstopfr $PF >/dev/null
files30=(); for i in $(seq 1 30); do files30+=("src/x$i.txt" "x\n"); done
: > $T/sgcalls
sgmerge $PF bpf1 "${files30[@]}" superdoc/features/n.md '# N\nclean\n' CLAUDE.md '<!-- superdoc:start v4 -->\nedited\n'
check "gate pre-filter: a merge with 30 non-doc files and one doc file hands lint only CLAUDE.md and the doc file" "$(sgstopfr $PF)/$(grep -c '^--files -- ' $T/sgcalls)/$(grep -- '--files' $T/sgcalls | grep -c 'src/')/$(grep -- '--files' $T/sgcalls | grep -c 'CLAUDE.md superdoc/features/n.md\|superdoc/features/n.md CLAUDE.md')" "0/1/0/1"
: > $T/sgcalls
sgmerge $PF bpf2 "${files30[@]}" other/z.md 'z\n'
check "gate pre-filter: a merge that touches no doc file never calls lint --files or --range, and still advances the state" "$(sgstopfr $PF)/$(grep -c -- '--files\|--range' $T/sgcalls)/$(cat $T/sgout | wc -c | tr -d ' ')/$(sgstate $PF)" "0/0/0/head"
check "gate pre-filter: the doc root is asked of lint.sh (--print-doc-root), not re-derived in the gate" "$(grep -c '^--print-doc-root$' $T/sgcalls)" "1"
check "lint --print-doc-root: prints the doc root, exit 0, no other output" "$(lintin $PF --print-doc-root 2>&1; echo rc=$?)" "superdoc
rc=0"
HB=$T/sghb; gfix $HB; rmdir $HB/superdoc/features $HB/superdoc; mkdir -p $HB/handbook/meta $HB/handbook/features; printf '# P\n<!-- superdoc:start v4 -->\n@handbook/meta/TERMINOLOGY.md\n<!-- superdoc:end -->\n' > $HB/CLAUDE.md
printf '# T\n' > $HB/handbook/meta/TERMINOLOGY.md; printf '# a\n' > $HB/handbook/features/a.md
mkdir -p $HB/.claude/teamlead/.state; : > $HB/.claude/teamlead/.state/active; (cd $HB && git add CLAUDE.md handbook && git commit -qm base); sgstopfr $HB >/dev/null
check "lint --print-doc-root: derives a non-default doc root from the @-ref in CLAUDE.md" "$(lintin $HB --print-doc-root)" "handbook"
: > $T/sgcalls
sgmerge $HB bhb1 handbook/features/h.md "# H\nsee /mnt/$SENT/x\n" docs/q.md 'q\n' other/z.md 'z\n'
check "gate pre-filter: a derived doc root (handbook/) is honoured: its file is linted (and its warning shown), files elsewhere (docs/, other/) are not passed" "$(sgstopfr $HB)/$(grep -- '--files' $T/sgcalls | grep -c 'handbook/features/h.md')/$(grep -- '--files' $T/sgcalls | grep -c 'docs/\|other/')/$(grep -c 'handbook/features/h.md:2: warn: host path' $T/sgout)" "2/1/0/1"

# the cap: 300 architecture pages with line references
CP=$T/sgcap; sgmk $CP; mkdir -p $CP/superdoc/architecture; sgstop $CP >/dev/null
capargs=(); for i in $(seq 1 300); do capargs+=("superdoc/architecture/p$i.md" '# p\nsee main.py:42\n'); done
sgmerge $CP bcap "${capargs[@]}"
rc_cap=$(sgstop $CP)
check "gate cap: 300 findings show 40 lint lines, then how many more and that lint.sh lists them all; the whole Stop reason stays short" "$rc_cap/$(grep -c '^    superdoc/architecture/p[0-9]*.md:2: warn: line reference$' $T/sgout)/$(grep -c '^    \.\.\. and 261 more line(s) not shown; .*lint\.sh lists them all' $T/sgout)/$([ "$(wc -l < $T/sgout)" -lt 60 ] && echo short)" "2/40/1/short"
check "  and fires once, state advanced" "$(sgstop $CP)/$(sgstate $CP)" "0/head"
sgmerge $CP bcap2 superdoc/architecture/q1.md '# q\nsee main.py:42\n'
check "gate cap: a few findings are all shown, with no 'more' line" "$(sgstop $CP)/$(grep -c 'q1.md:2: warn: line reference$' $T/sgout)/$(grep -c 'more line' $T/sgout)" "2/1/0"

# old debt is not re-reported as a leak: errors only for lines added in the merge
OD=$T/sgod; sgmk $OD
printf '# O\nold 10.9.9.9\nline3 tyop\n' > $OD/superdoc/features/old.md; (cd $OD && git add -A && git commit -qm old --no-verify); sgstop $OD >/dev/null
sgmerge $OD bod1 superdoc/features/old.md '# O\nold 10.9.9.9\nline3 typo\n'
check "gate: fixing a typo in a file that holds an old private IP is silent (no 'leak got past the commit hooks'), state advanced" "$(sgstop $OD)/$(cat $T/sgout | wc -c | tr -d ' ')/$(sgstate $OD)" "0/0/head"
sgmerge $OD bod2 superdoc/features/old.md "# O\nold 10.9.9.9\nline3 typo\ncd /home/$SENT\nsee /mnt/nas/x\n"
rc_od=$(sgstop $OD)
check "gate: a merge that adds a leak to that file shows the added line only: error at line 4 with its commit, not the old private IP at line 2" "$rc_od/$(grep -c '^ *superdoc/features/old.md:4: error: home path (commit [0-9a-f]*)$' $T/sgout)/$(grep -c 'old.md:2:' $T/sgout)/$(grep -c 'error: private IP' $T/sgout)" "2/1/0/0"
check "  the warning on the added line appears once, with its hint; the fix line and the commit-rewrite line go with the error; the sentinel is never printed" "$(grep -c 'old.md:5: warn: host path$' $T/sgout)/$(grep -c '^ *hint: write repo-relative' $T/sgout)/$(grep -c '^ *fix: replace each flagged value' $T/sgout)/$(grep -c '^ *fix: a flagged value in a commit' $T/sgout)/$(grep -c "$SENT" $T/sgout)" "1/1/1/1/0"
check "  no lint summary line is repeated into the Stop reason" "$(grep -c 'superdoc-lint: [0-9]* error' $T/sgout)" "0"
# two calls, each under `timeout 4`; a timeout on either one is quiet and leaves the state alone
mkdir -p $T/sgfake2; printf '#!/bin/sh\necho "$1" >> "%s"\nn=$(cat "%s" 2>/dev/null || echo 0); echo $((n+1)) > "%s"\n[ "$n" -ge "$(cat "%s")" ] && exit 124\nshift; exec "$@"\n' "$T/sgtolog" "$T/sgtocnt" "$T/sgtocnt" "$T/sgtolimit" > $T/sgfake2/timeout; chmod +x $T/sgfake2/timeout
TO=$T/sgto; sgmk $TO; sgstop $TO >/dev/null
sgmerge $TO bto1 superdoc/features/t.md "# T\ncd /home/$SENT\nsee /mnt/nas/x\n"
sgstopto() { : > $T/sgtolog; printf '0' > $T/sgtocnt; printf '%s' "$1" > $T/sgtolimit; printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$TO" | env -u CLAUDE_PROJECT_DIR PATH="$T/sgfake2:$PATH" "$H/gate.sh" >"$T/sgout" 2>&1; echo $?; }
check "gate: the second lint call (--range) timing out is quiet, the state stays unmoved, and both calls ran under timeout 4" "$(sgstopto 1)/$(cat $T/sgout | wc -c | tr -d ' ')/$(sgstate $TO)/$(tr '\n' ' ' < $T/sgtolog)" "0/0/unmoved/4 4 "
check "gate: the first lint call (--files) timing out is quiet, the state stays unmoved, and the second call is not made" "$(sgstopto 0)/$(cat $T/sgout | wc -c | tr -d ' ')/$(sgstate $TO)/$(tr '\n' ' ' < $T/sgtolog)" "0/0/unmoved/4 "
check "gate: with no timeout it fires once: the error (range) and the warning (files) together, state advanced" "$(sgstopto 9)/$(grep -c 't.md:2: error: home path (commit' $T/sgout)/$(grep -c 't.md:3: warn: host path$' $T/sgout)/$(sgstate $TO)" "2/1/1/head"

echo "== superdoc enforcement: audit reminder (restore.sh) =="
R=$T/sgrem; sgmk $R
out_a1=$(sgrestore $R)
check "reminder: first run writes HEAD silently" "$(printf '%s\n' "$out_a1" | grep -c 'last audit')/$([ "$(cat $R/.claude/teamlead/.state/superdoc-audit)" = "$(cd $R && git rev-parse HEAD)" ] && echo head)" "0/head"
for i in $(seq 1 50); do (cd $R && git commit -q --allow-empty --no-verify -m "c$i"); done
check "reminder: exactly 50 commits since the audit is silent" "$(sgrestore $R | grep -c 'last audit')" "0"
(cd $R && git checkout -qb side && git commit -q --allow-empty --no-verify -m s1 && git checkout -q master && git merge -q --no-ff --no-verify -m merged side)
check "reminder: a merge commit is not counted (50 commits + one on a side branch = 51, not 52)" "$(sgrestore $R | grep -c '51 commits old')" "1"
out_a2=$(sgrestore $R startup)
check "reminder: over N prints ONE line for the lead: how old, run /teamlead superdoc, and never to ask the user" "$(printf '%s\n' "$out_a2" | grep -c '^\[teamlead\] superdoc: the last audit is 51 commits old\. Run /teamlead superdoc (audit, then repair) when the current work allows\.')/$(printf '%s\n' "$out_a2" | grep 'last audit' | grep -c 'do not ask the user')" "1/1"
check "reminder: also on resume and clear, not on compact" "$(sgrestore $R resume | grep -c 'last audit')/$(sgrestore $R clear | grep -c 'last audit')/$(sgrestore $R compact | grep -c 'last audit')" "1/1/0"
(cd $R && git rev-parse HEAD > .claude/teamlead/.state/superdoc-audit)
check "reminder: recording the audit (the skill's own command) silences it" "$(sgrestore $R | grep -c 'last audit')" "0"
printf '%s\n' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > $R/.claude/teamlead/.state/superdoc-audit
check "reminder: a recorded commit that is not an ancestor is replaced by HEAD, silently" "$(sgrestore $R | grep -c 'last audit')/$([ "$(cat $R/.claude/teamlead/.state/superdoc-audit)" = "$(cd $R && git rev-parse HEAD)" ] && echo head)" "0/head"
RU=$T/sgremu; sgmk $RU; printf '# P\n' > $RU/CLAUDE.md; (cd $RU && git commit -qam unwire); sgrestore $RU >/dev/null
check "reminder: an unwired project writes no state and prints nothing" "$(ls $RU/.claude/teamlead/.state | grep -c superdoc-audit)" "0"
grep -q 'git rev-parse HEAD > .claude/teamlead/.state/superdoc-audit' "$SD" && ok "SKILL.md: the lead records the audit with git rev-parse HEAD > .claude/teamlead/.state/superdoc-audit" || bad "SKILL.md: audit record command"
check "SKILL.md: the audit is recorded at the end of Step 4 (Step 3 for a report-only audit)" "$(grep -c 'end of Step 4 (Step 3 for a report-only audit)' "$SD")" "1"

echo "== superdoc SKILL.md: tiers (no Opus tier), enforcement section =="
check "SKILL.md: the old per-capability Opus tier paragraph and the Step 4 tier list are gone" "$(grep -c 'Tier per capability\|architectural rationale → Opus\|when unsure, \*\*take Opus\|tl-opus-high' "$SD")" "0"
check "SKILL.md: every remaining mention of Opus is the escalation rule (one place, ceiling tl-opus-medium)" "$(grep -ci 'opus' "$SD")/$(grep -c 'tl-opus-medium' "$SD")/$(grep -c 'There is no Opus QC' "$SD")" "2/1/1"
check "SKILL.md: tiers stated once: writers tl-sonnet-medium, QC tl-sonnet-high" "$(grep -c '^\*\*Tiers (stated here once' "$SD")/$(grep -c 'is `tl-sonnet-medium`' "$SD")/$(grep -c 'QC is `tl-sonnet-high`' "$SD")" "1/1/1"
check "SKILL.md: Step 1b dispatches its writing worker at tl-sonnet-medium" "$(grep -c 'one writing worker\*\* (`tl-sonnet-medium`)' "$SD")" "1"
ENFS=$(awk '/^## What enforces the rules between audits/{f=1;next} /^## /{f=0} f' "$SD")
for want in '--no-verify. outside Claude' 'never had a session' 'could not be installed' 'web editor' 'fast-forward' 'superdoc:start'; do
  printf '%s' "$ENFS" | grep -q -e "$want" && ok "  SKILL.md enforcement section covers: $want" || bad "  SKILL.md enforcement section covers: $want"
done

echo "== superdoc workers copy assets via Read/Write, not Bash on a plugin-root path (#5) =="
! grep -qF '$(cat .claude/teamlead/.state/plugin-root)' "$PB" && ok "playbook: no worktree-relative plugin-root lookup" || bad "playbook: worker told to cat the state file (missing in a worktree)"
! grep -qE '^cp |^PR=' "$PB" && ok "playbook: no Bash cp of plugin assets" || bad "playbook: still has a Bash cp/PR= for plugin assets"
grep -q 'Read tool' "$PB" && grep -q 'Write tool' "$PB" && ok "playbook: assets via Read + Write" || bad "playbook: assets via Read + Write"
grep -q 'literal' "$SD" && grep -q 'Read tool' "$SD" && ok "  dispatcher puts the literal root in the brief" || bad "  dispatcher puts the literal root in the brief"

echo "== the skill is self-sufficient for its own tooling =="
SKC="$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md"
for c in "board.py render" "board.py check" "board.py forget" "board.py status"; do
  grep -q "$c" "$SKC" || bad "skill never mentions '$c' — the agent would have to read the source"
done
ok "every CLI remedy is in the skill, not only the README"
grep -q 'never read the plugin.s source' "$SKC" && ok "  tells it not to reverse-engineer" || bad "  tells it not to reverse-engineer"
grep -q 'plan-watch\|plugin-root' "$SKC" && ok "  says where the plugin root is" || bad "  says where the plugin root is"

echo "== the status line installer =="
INS="$CLAUDE_PLUGIN_ROOT/scripts/install-statusline.sh"
ic=$T/cfg; mkdir -p $ic
run(){ CLAUDE_CONFIG_DIR=$ic bash "$INS" "$1" >"$T/iout" 2>&1; echo $?; }
sl(){ python3 -c "import json;print((json.load(open('$ic/settings.json')).get('statusLine') or {}).get('command',''))"; }
printf '{"model":"opus","statusLine":{"type":"command","command":"bash \\"/tmp/prior.sh\\""}}\n' > $ic/settings.json
check "combined install succeeds" "$(run --combined)" 0
grep -q 'prior.sh' $ic/statusline.sh && ok "  keeps the existing segment" || bad "  keeps the existing segment"
grep -qF "$H/statusline.sh" $ic/statusline.sh && ok "  adds teamlead" || bad "  adds teamlead"
[ "$(sl)" = "bash \"$ic/statusline.sh\"" ] && ok "  points settings at the combiner" || bad "  points settings at combiner ($(sl))"
python3 -c "import json;d=json.load(open('$ic/settings.json'));assert d['model']=='opus'" && ok "  leaves other settings alone" || bad "  leaves other settings alone"
ls $ic/settings.json.bak.* >/dev/null 2>&1 && ok "  wrote a backup" || bad "  wrote a backup"
run --combined >/dev/null
check "idempotent" "$(grep -cF "$H/statusline.sh" $ic/statusline.sh)" 1
run --uninstall >/dev/null
check "uninstall restores the original" "$(sl)" 'bash "/tmp/prior.sh"'
# version pinning is removed so a plugin update cannot break the segment
printf '{"statusLine":{"type":"command","command":"bash \\"$HOME/.claude/plugins/cache/x/y/1.2.3/s.sh\\""}}\n' > $ic/settings.json
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; run --combined >/dev/null
grep -q '/x/y/\*/s.sh' $ic/statusline.sh && ok "un-pins a versioned plugin path" || bad "un-pins a versioned plugin path"
# I5: de-pinning now resolves the newest version at RUN time (so a later plugin
# update is picked up without reinstalling) via a quoted `compgen -G`, fully
# quoted — never a bare unquoted `*`, which a two-version cache would explode
# into multiple words for `bash -c` (D7: "bash: /path1 /path2: No such file").
depinned=$(grep -m1 'compgen -G' $ic/statusline.sh)
grep -qE "compgen -G '[^']*/x/y/\*/s\.sh'" <<<"$depinned" && ok "  uses compgen -G on the glob" || bad "  uses compgen -G on the glob ($depinned)"
stripped=$(sed "s/'[^']*'//g" <<<"$depinned")
[ "${stripped/\*/}" = "$stripped" ] && ok "  every * sits inside single quotes" || bad "  unquoted * found outside quotes: $depinned"
# with two real cache versions on disk, the depinned command actually resolves
# to the newest and runs it exactly once (this is the case D7 broke: an unquoted
# glob over two versions runs `bash v1 v2`, "No such file", not the newest twice).
cache=$T/plugins/cache/x/y; mkdir -p "$cache/1.0.0" "$cache/1.1.0"
printf 'echo v1.0.0\n' > "$cache/1.0.0/s.sh"; printf 'echo v1.1.0\n' > "$cache/1.1.0/s.sh"
printf '{"statusLine":{"type":"command","command":"bash \\"%s/1.0.0/s.sh\\""}}\n' "$cache" > $ic/settings.json
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; run --combined >/dev/null
# workspace.current_dir points at $ic itself (no .claude/teamlead there) so the
# combined script's OWN teamlead segment stays silent and does not contaminate
# the output — cwd here is otherwise whatever project the caller last cd'd into.
out=$(printf '{"workspace":{"current_dir":"%s"}}' "$ic" | bash "$ic/statusline.sh" 2>&1)
check "the newest cache version runs, exactly once" "$out" "v1.1.0"
# a path containing spaces stays quoted and therefore stays pinned
printf '{"statusLine":{"type":"command","command":"bash \\"/a b/plugins/cache/x/y/1.2.3/s.sh\\""}}\n' > $ic/settings.json
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; run --combined >/dev/null
grep -q '1.2.3' $ic/statusline.sh && ok "  a path with spaces stays pinned and quoted" || bad "  path with spaces must stay quoted"
# never clobber a hand-written combiner
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; printf '# mine\n' > $ic/statusline.sh
run --combined >/dev/null; grep -q '^# mine' $ic/statusline.sh && ok "refuses to clobber a hand-written combiner" || bad "refuses to clobber"

echo "== done-when criteria and archiving =="
# $2 is the whole '## Done when' section, or '' for a plan that has not reached
# stage 4 yet — it and the wave table are written together, from settled decisions.
mkdw(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *why.*\n\n%b\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" "$2" | cat -s > "$T/dw.md"
  dh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/dw.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$dh/" "$T/dw.md"; "$PL" "$T/dw.md" >"$T/dwout" 2>&1; echo $?; }
check "criteria with verifiers pass" "$(mkdw 4 '## Done when\n- [x] tests pass — *verified by: agent*\n')" 0
check "no 'Done when' section at stage 4 fails" "$(mkdw 4 '')" 1
grep -q "no criteria under 'Done when'" "$T/dwout" && ok "  says what to add" || bad "  says what to add"
check "the section with no criteria in it fails" "$(mkdw 4 '## Done when\n')" 1
check "a criterion with no verifier fails" "$(mkdw 4 '## Done when\n- [ ] vague\n')" 1
grep -q 'who verifies them' "$T/dwout" && ok "  demands agent or user" || bad "  demands agent or user"
check "stage 3 has neither section yet" "$(mkdw 3 '')" 0
grep -q 'Done when' "$PS2" && ok "  the skill asks for it while planning" || bad "  skill asks while planning"
grep -q 'Really run them' "$PS2" && ok "  demands the checks actually run" || bad "  demands checks actually run"

ap=$T/arch; mkdir -p $ap/.claude/teamlead/{plan,.state/snap}; (cd $ap && git init -q)
apf=$ap/.claude/teamlead/plan/topic.md
# A confirmed plan: every 'Done when' box ticked. Archiving refuses anything less.
DONE='# T\n\n## Done when\n- [x] it works — *verified by: agent*\n'
printf "$DONE" > $apf
echo "$apf" > $ap/.claude/teamlead/.state/active-plan
: > $ap/.claude/teamlead/.state/plan-touched; cp $apf $ap/.claude/teamlead/.state/snap/topic.md
bash "$CLAUDE_PLUGIN_ROOT/scripts/plan-archive.sh" $apf --project $ap >/dev/null 2>&1
d=$(date +%Y-%m-%d)
[ -f "$ap/.claude/teamlead/plan/done/$d-topic.md" ] && ok "archives with a datestamp" || bad "archives with a datestamp"
[ -f "$apf" ] && bad "  removes it from the active folder" || ok "  removes it from the active folder"
[ -f "$ap/.claude/teamlead/.state/active-plan" ] && bad "  clears active-plan" || ok "  clears active-plan"
[ -f "$ap/.claude/teamlead/.state/snap/topic.md" ] && bad "  clears the snapshot" || ok "  clears the snapshot"
printf "$DONE" > $apf
bash "$CLAUDE_PLUGIN_ROOT/scripts/plan-archive.sh" $apf --project $ap >/dev/null 2>&1
[ -f "$ap/.claude/teamlead/plan/done/$d-topic-2.md" ] && ok "  a same-day second plan does not overwrite" || bad "  same-day collision"

# The 'confirm before retiring' rule is enforced here, not only in the skill text —
# filing a plan away with work left in it is how the leftover work gets lost.
arch(){ printf "$1" > $apf; bash "$CLAUDE_PLUGIN_ROOT/scripts/plan-archive.sh" $apf --project $ap ${2:-} >"$T/arout" 2>&1; echo $?; }
check "refuses a plan with an unticked box" "$(arch '# T\n\n## Done when\n- [x] a — *v: agent*\n- [ ] b — *v: user*\n')" 1
grep -q '1 of 2' "$T/arout" && ok "  counts what is left" || bad "  counts what is left"
grep -q '\- \[ \] b' "$T/arout" && ok "  names the unticked item" || bad "  names the unticked item"
check "refuses a plan with no criteria at all" "$(arch '# T\n\n## Done when\n\n## Context\nc\n')" 1
check "--abandon files a dropped plan anyway" "$(arch '# T\n\n## Done when\n- [ ] never done — *v: user*\n' --abandon)" 0
[ -f "$ap/.claude/teamlead/plan/done/$d-abandoned-topic.md" ] && ok "  and marks it abandoned" || bad "  and marks it abandoned"

echo "== a finished plan has empty inboxes =="
mkfin(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *why.*\n\n## Done when\n- [x] it works — *verified by: agent*\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n%s\n\n### Answered\n- ~~old~~ → yes → **D1**\n\n## Notes from me\n%s\n\n' "$1" "$2" "$3" | cat -s > "$T/fin.md"
  fh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/fin.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$fh/" "$T/fin.md"
  "$PL" "$T/fin.md" >"$T/finout" 2>&1; echo $?; }
check "stage 4, both inboxes empty" "$(mkfin 4 '*(none open)*' '')" 0
check "stage 4 with an open question" "$(mkfin 4 '1. unanswered?\n   *Suggest:* x — *y.*' '')" 1
grep -q 'fold each answer into a Decision' "$T/finout" && ok "  says to fold it into a Decision" || bad "  says to fold it"
check "stage 4 with a leftover note" "$(mkfin 4 '*(none)*' 'remember billing')" 1
grep -q "left in 'Notes from me'" "$T/finout" && ok "  names the leftover note" || bad "  names the leftover note"
check "stage 3 may hold both" "$(mkfin 3 '1. open?\n   *Suggest:* x — *y.*' 'a note')" 0
grep -q 'inboxes, not storage' "$PS2" && ok "  the skill states the invariant" || bad "  skill states the invariant"
grep -q 'can raise something new' "$PS2" && ok "  answers may spawn new questions" || bad "  answers may spawn new questions"

echo "== plan stages: path first, scout second =="
grep -q 'Order inside the first turn' "$PS2" && ok "spells out the order in turn one" || bad "spells out the order"
grep -q 'as your first output' "$PS2" && ok "  path before any slow work" || bad "  path before slow work"
grep -q 'Skip it entirely when the topic came with the command' "$PS2" && ok "  stage 1 is skippable" || bad "  stage 1 skippable"
grep -q 'Ends when' "$PS2" && ok "  each stage has an exit condition" || bad "  each stage has an exit condition"
# the statusline must have a sensible label for the transient stage 2
sed -i 's/Stage [0-9]/Stage 2/' $pf 2>/dev/null
echo "$pf" > $slp/.claude/teamlead/.state/active-plan
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q 'stage 2/7 open it in your editor' <<<"$out" && ok "  stage 2 tells the user to open it" || bad "  stage 2 label ($out)"
sed -i 's/Stage [0-9]/Stage 3/' $pf 2>/dev/null

echo "== plan skill presents the path prominently =="
PS="$CLAUDE_PLUGIN_ROOT/skills/teamlead-plan/SKILL.md"
grep -q 'single-cell table' "$PS" && ok "instructs a single-cell table" || bad "instructs a single-cell table"
grep -q '📄 Open this in your editor' "$PS" && ok "  gives the exact markup" || bad "  gives the exact markup"
grep -q 'never try to open it for them' "$PS" && ok "  still forbids opening it itself" || bad "  still forbids opening it itself"
grep -q 'after a compaction' "$PS" && ok "  re-shows the path after context loss" || bad "  re-shows the path after context loss"

echo "== README documents what exists =="
RM="$CLAUDE_PLUGIN_ROOT/README.md"
for sec in "## Dials" "## Planning mode" "## Troubleshooting" "## Install"; do
  grep -q "$sec" "$RM" || bad "README missing $sec"
done
ok "README has install, dials, planning, troubleshooting"
grep -q 'board.py status' "$RM" && ok "README documents status" || bad "README documents status"

echo "== core skill keeps the stage plan =="
grep -q '## Stage plan' "$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md" && ok "stage plan section present" || bad "stage plan section present"

echo "== board MCP server =="
mcpout=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | CLAUDE_PROJECT_DIR=$bp python3 "$B" --mcp)
grep -q 'teamlead-board' <<<"$mcpout" && ok "server initializes" || bad "server initializes"
for t in board_list board_add board_update; do
  grep -q "\"$t\"" <<<"$mcpout" && ok "  exposes $t" || bad "  exposes $t"
done
grep -q '"board_remove"' <<<"$mcpout" && bad "remove is exposed over MCP (it is a hand-repair op, CLI-only)" || ok "remove is not exposed over MCP"

echo "== D4 (I7): board writes are the lead's, and never resolve from cwd =="
d4p=$T/d4; mkdir -p $d4p
check "worker (CLAUDE_AGENT_ID set) add: refused" \
  "$(CLAUDE_AGENT_ID=x python3 "$B" add --project $d4p --task t --agent tl-sonnet-low >"$T/d4out" 2>&1; echo $?)" 1
grep -q 'workers report, the lead records' "$T/d4out" && ok "  names the reason" || bad "  names the reason"
python3 "$B" add --project $d4p --task real --agent tl-sonnet-low --owns d4/a >/dev/null   # id 1, for the update case below
check "worker (CLAUDE_AGENT_ID set) update: refused" \
  "$(CLAUDE_AGENT_ID=x python3 "$B" update --project $d4p --id 1 --notes x >"$T/d4out2" 2>&1; echo $?)" 1
grep -q 'workers report, the lead records' "$T/d4out2" && ok "  names the reason" || bad "  names the reason"

mkdir -p $d4p/sub
before_bj=$([ -f $d4p/.claude/teamlead/.state/board.json ] && cat $d4p/.claude/teamlead/.state/board.json)
check "no --project, no CLAUDE_PROJECT_DIR, from a subdir: refused" \
  "$(cd $d4p/sub && env -u CLAUDE_PROJECT_DIR python3 "$B" add --task t --agent tl-sonnet-low >"$T/d4out3" 2>&1; echo $?)" 1
grep -q 'board writes never resolve from cwd' "$T/d4out3" && ok "  names the reason" || bad "  names the reason"
after_bj=$(cat $d4p/.claude/teamlead/.state/board.json)
check "  the real board.json is unchanged" "$after_bj" "$before_bj"
check "list without --project from inside the project still works" \
  "$(cd $d4p && env -u CLAUDE_PROJECT_DIR python3 "$B" list >/dev/null 2>&1; echo $?)" 0

echo "== worker CLI writes: an agent worktree may not write its project's board; blank --project is refused =="
# The incident: a worker in .claude/worktrees/agent-* ran board.py with --project "" (an
# empty mktemp) and wrote the lead's real board. CLAUDE_AGENT_ID is NOT set in a worker's
# Bash, so the worker is recognised by where it runs: cwd in an agent-<id> linked worktree
# of the very project whose board it would write.
wkm=$T/wk/main; mkdir -p $wkm $T/wk/scratch
(cd $wkm && git init -q && git config user.email t@t.t && git config user.name t \
  && git commit -qm init --allow-empty && mkdir -p .claude/worktrees \
  && git worktree add -q -b worktree-agent-wk .claude/worktrees/agent-wk \
  && git worktree add -q -b feature-lead .claude/worktrees/feature-lead)
wkw=$wkm/.claude/worktrees/agent-wk; wkl=$wkm/.claude/worktrees/feature-lead
wkd=$wkm/.claude/teamlead/.state
python3 "$B" add --project $wkm --task "lead row" --agent tl-sonnet-low --owns wk/a >/dev/null    # id 1
python3 "$B" add --project $wkm --task "second row" --agent tl-sonnet-low --owns wk/b >/dev/null  # id 2
wksum(){ cat $wkd/board.json $wkm/.claude/teamlead/board.md $wkd/events.log 2>/dev/null | cksum; }
# run as a worker's Bash would: no CLAUDE_AGENT_ID, no hook marker
wkrun(){ (cd "$1" && shift && env -u CLAUDE_AGENT_ID -u TL_HOOK "$@"); }
wk0=$(wksum)

for pv in "" "  "; do
  check "worker worktree: add --project '$pv' (CLAUDE_PROJECT_DIR=main): refused" \
    "$(wkrun $wkw env CLAUDE_PROJECT_DIR=$wkm python3 "$B" add --project "$pv" --task "stale-base work" --agent tl-sonnet-low --owns src/x >"$T/wkout" 2>&1; echo $?)" 1
  grep -q 'non-empty' "$T/wkout" && ok "  says --project needs a value" || bad "  says --project needs a value: $(cat $T/wkout)"
done
E=""
check "worker worktree: add --project \$EMPTY (unquoted, the word vanishes): refused" \
  "$(wkrun $wkw python3 "$B" add --project $E --task u --agent tl-sonnet-low --owns src/w >"$T/wkout" 2>&1; echo $?)" 1
check "worker worktree: add ... --project (valueless, last): refused" \
  "$(wkrun $wkw python3 "$B" add --task t --agent tl-sonnet-low --owns src/z --project >"$T/wkout" 2>&1; echo $?)" 1
check "  no literal true/ dir (nor a lock) created in the worktree" \
  "$([ -e $wkw/true ] && echo yes; find $wkw -name board.lock -not -path '*/.git/*' | grep -c .)" "0"
check "  the project's real board was not touched" "$(wksum)" "$wk0"
check "blank --project on a read-only command is refused too" \
  "$(python3 "$B" list --project "" >"$T/wkout" 2>&1; echo $?)" 1
check "a --project that is not a directory is refused for a write (no true/.claude/... conjured)" \
  "$(cd $T/wk/scratch && python3 "$B" add --project nosuchdir --task t --agent tl-sonnet-low >"$T/wkout" 2>&1; echo $?; [ -e nosuchdir ] && echo created)" 1

# Every mutating command, run from the worker's worktree against the project it belongs to.
for c in "add --task t --agent tl-sonnet-low --owns wk/z" "update --id 1 --notes x" "remove 2" \
         "forget" "clean" "drop" "drop --dry-run" "hold 1" "release 1" "render" \
         "worker-start --id w9" "worker-stop --id w9"; do
  out=$(wkrun $wkw python3 "$B" $c --project $wkm 2>&1); rc=$?
  check "worker worktree: '$c' refused" "$rc" 1
  grep -q 'worker worktree' <<<"$out" && ok "  says why" || bad "  says why: $out"
done
check "  the project's real board, board.md and ledger were not touched" "$(wksum)" "$wk0"
check "worker worktree, from a subdirectory: add refused too" \
  "$(mkdir -p $wkw/sub; wkrun $wkw/sub python3 "$B" add --project $wkm --task t --agent tl-sonnet-low --owns wk/z >/dev/null 2>&1; echo $?)" 1
check "worker worktree, CLAUDE_PROJECT_DIR=main and no --project: add refused" \
  "$(wkrun $wkw env CLAUDE_PROJECT_DIR=$wkm python3 "$B" add --task t --agent tl-sonnet-low --owns wk/z >/dev/null 2>&1; echo $?)" 1
for c in list status check held ledger; do
  check "worker worktree: read-only '$c' still works" \
    "$(wkrun $wkw python3 "$B" $c --project $wkm >/dev/null 2>&1; echo $?)" 0
done
check "a worker may use board.py on a scratch project of its own (a different repo)" \
  "$(wkrun $wkw python3 "$B" add --project $T/wk/scratch --task t --agent tl-sonnet-low --owns s/a >/dev/null 2>&1; echo $?)" 0

check "the lead's own CLI from the main checkout: add works" \
  "$(wkrun $wkm python3 "$B" add --project $wkm --task "lead add" --agent tl-sonnet-low --owns wk/c >/dev/null 2>&1; echo $?)" 0
check "the lead from its own (non-agent) linked worktree: add works" \
  "$(wkrun $wkl python3 "$B" add --project $wkm --task "lead add 2" --agent tl-sonnet-low --owns wk/d >/dev/null 2>&1; echo $?)" 0
check "the lead's remove/clean/render from the main checkout work" \
  "$(wkrun $wkm python3 "$B" remove 4 --project $wkm >/dev/null 2>&1; echo $?; wkrun $wkm python3 "$B" clean --project $wkm >/dev/null 2>&1; echo $?; wkrun $wkm python3 "$B" render --project $wkm >/dev/null 2>&1; echo $?)" "0
0
0"

echo "== worker CLI writes: the hook path stays open (TL_HOOK) =="
check "TL_HOOK=1 worker-start from a worker's cwd: allowed" \
  "$(cd $wkw && env -u CLAUDE_AGENT_ID TL_HOOK=1 python3 "$B" worker-start --id w9 --project $wkm >/dev/null 2>&1; echo $?)" 0
check "TL_HOOK=1 worker-stop from a worker's cwd: allowed" \
  "$(cd $wkw && env -u CLAUDE_AGENT_ID TL_HOOK=1 python3 "$B" worker-stop --id w9 --project $wkm >/dev/null 2>&1; echo $?)" 0
for c in "add --task t --agent tl-sonnet-low --owns wk/z" "update --id 1 --notes x" "remove 3" "clean" "drop" "hold 1"; do
  check "TL_HOOK=1 does not open '$c' to a worker" \
    "$(cd $wkw && env -u CLAUDE_AGENT_ID TL_HOOK=1 python3 "$B" $c --project $wkm >/dev/null 2>&1; echo $?)" 1
done
# The real hooks, fired with cwd inside the worker's worktree: dispatch (PostToolUse/Agent),
# the session-start sweep (render + forget), and the worker's return (SubagentStop).
: > $wkd/active
wkhook(){ (cd $wkw && echo "$1" | env -u CLAUDE_AGENT_ID -u TL_HOOK -u CLAUDE_PROJECT_DIR "$2" >"$T/wkhout" 2>&1; echo $?); }
wkrow(){ python3 -c "import json;d=json.load(open('$wkd/board.json'));t=[x for x in d['tasks'] if x['id']==$1][0];print(t['state']+','+str(t['worker']))"; }
WPT='{"hook_event_name":"PostToolUse","cwd":"'$wkw'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"w","prompt":"Brief.\nboard: 1\nGo.","isolation":"worktree"},"tool_response":{"agentId":"wk1"}}'
check "record.sh PostToolUse(Agent) with a worker-worktree cwd: exit 0" "$(wkhook "$WPT" "$H/record.sh")" 0
check "  worker-start went through: row 1 running/wk1" "$(wkrow 1)" "running,wk1"
check "record.sh SubagentStart with a worker-worktree cwd: exit 0 (ledger: wk1 outstanding)" \
  "$(wkhook '{"hook_event_name":"SubagentStart","cwd":"'$wkw'","agent_type":"teamlead:tl-sonnet-high","agent_id":"wk1","session_id":"s-old"}' "$H/record.sh")" 0
sleep 1
check "restore.sh (SessionStart) with a worker-worktree cwd: exit 0" \
  "$(wkhook '{"hook_event_name":"SessionStart","source":"startup","session_id":"s-new","cwd":"'$wkw'"}' "$H/restore.sh")" 0
grep -q 'Closed out 1 worker(s) from a previous session: wk1' "$T/wkhout" \
  && ok "  its forget sweep went through" || bad "  its forget sweep went through: $(cat $T/wkhout)"
check "  row 1 requeued by the sweep" "$(wkrow 1 | cut -d, -f1)" "queued"
WPT2='{"hook_event_name":"PostToolUse","cwd":"'$wkw'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"w2","prompt":"Brief.\nboard: 2\nGo."},"tool_response":{"agentId":"wk2"}}'
wkhook "$WPT2" "$H/record.sh" >/dev/null
check "  row 2 running/wk2" "$(wkrow 2)" "running,wk2"
check "record.sh SubagentStop with a worker-worktree cwd: exit 0" \
  "$(wkhook '{"hook_event_name":"SubagentStop","cwd":"'$wkw'","agent_type":"teamlead:tl-sonnet-high","agent_id":"wk2","last_assistant_message":"done"}' "$H/record.sh")" 0
check "  worker-stop went through: row 2 returned" "$(wkrow 2)" "returned,wk2"
check "  no hook board call was refused" "$(grep -c 'board-refused' $wkd/events.log)" 0
check "gate.sh (Stop) with a worker-worktree cwd: reads the board fine" \
  "$(wkhook '{"hook_event_name":"Stop","cwd":"'$wkw'","stop_hook_active":false}' "$H/gate.sh" >/dev/null; grep -c 'refused' $T/wkhout)" 0
rm -f $wkd/active

echo "== D4 (I7): remove =="
rmp=$T/rm; mkdir -p $rmp
python3 "$B" add --project $rmp --task "queued one" --agent tl-sonnet-low --owns rm/a >/dev/null       # id 1
check "remove a queued task: exit 0" "$(python3 "$B" remove 1 --project $rmp >/dev/null 2>&1; echo $?)" 0
check "  gone from board.json" \
  "$(python3 -c "import json;print(len(json.load(open('$rmp/.claude/teamlead/.state/board.json'))['tasks']))")" 0
check "  gone from board.md" "$(grep -c 'queued one' $rmp/.claude/teamlead/board.md)" 0

python3 "$B" add --project $rmp --task "running one" --agent tl-sonnet-low --owns rm/b >/dev/null      # id 2
python3 "$B" update --project $rmp --id 2 --state running --branch wr >/dev/null
check "remove a running task: exit 1" "$(python3 "$B" remove 2 --project $rmp >"$T/rmout" 2>&1; echo $?)" 1
grep -qi 'running' "$T/rmout" && ok "  names the state" || bad "  names the state"

python3 "$B" update --project $rmp --id 2 --state returned >/dev/null
check "remove a returned task: exit 1" "$(python3 "$B" remove 2 --project $rmp >"$T/rmout2" 2>&1; echo $?)" 1
grep -qi 'returned' "$T/rmout2" && ok "  names the state" || bad "  names the state"

check "remove an unknown id: exit 1" "$(python3 "$B" remove 999 --project $rmp >/dev/null 2>&1; echo $?)" 1

python3 "$B" add --project $rmp --task "blocker" --agent tl-sonnet-low --owns rm/c >/dev/null          # id 3
python3 "$B" add --project $rmp --task "blocked one" --agent tl-sonnet-low --owns rm/d --blocked-by 3 >/dev/null  # id 4
python3 "$B" remove 3 --project $rmp >/dev/null
st4=$(python3 -c "import json;d=json.load(open('$rmp/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==4][0];print(t['state']+','+str(t['blocked_by']))")
check "removing a blocker requeues the task that was blocked on it" "$st4" "queued,[]"

echo "== QC2: op_remove's cascade must not escape the targeted refusal =="
rc2p=$T/rmcascade; mkdir -p $rc2p
python3 "$B" add --project $rc2p --task "I1" --agent tl-sonnet-low --owns shared/x >/dev/null                    # id 1
python3 "$B" add --project $rc2p --task "I2" --agent tl-sonnet-low --owns shared/y --blocked-by 1 >/dev/null     # id 2
python3 "$B" add --project $rc2p --task "I3" --agent tl-sonnet-low --owns shared/x --blocked-by 2 >/dev/null     # id 3
check "remove 2 (the chain link keeping I1/I3's shared owns apart): refused" \
  "$(python3 "$B" remove 2 --project $rc2p >"$T/rc2out" 2>&1; echo $?)" 1
grep -q 'overlapping paths' "$T/rc2out" && ok "  names the overlap" || bad "  names the overlap"
n_rc2=$(python3 "$B" list --project $rc2p | python3 -c 'import json,sys;print(json.load(sys.stdin)["open"])')
check "  board unchanged: still 3 open rows" "$n_rc2" 3
t2_rc2=$(python3 -c "import json;d=json.load(open('$rc2p/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==2][0])")
check "  row 2 (I2) intact, still blocked" "$t2_rc2" "blocked"

rc2p2=$T/rmcascade-ok; mkdir -p $rc2p2
python3 "$B" add --project $rc2p2 --task "I1" --agent tl-sonnet-low --owns shared2/x >/dev/null                  # id 1
python3 "$B" add --project $rc2p2 --task "I2" --agent tl-sonnet-low --owns shared2/y --blocked-by 1 >/dev/null   # id 2
python3 "$B" add --project $rc2p2 --task "I3" --agent tl-sonnet-low --owns shared2/z --blocked-by 2 >/dev/null   # id 3 (disjoint owns)
check "remove 2 when the freed row's owns is disjoint: accepted" \
  "$(python3 "$B" remove 2 --project $rc2p2 >/dev/null 2>&1; echo $?)" 0
t3_rc2=$(python3 -c "import json;d=json.load(open('$rc2p2/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==3][0];print(t['state']+','+str(t['blocked_by']))")
check "  I3 (no longer blocked, no overlap) becomes queued" "$t3_rc2" "queued,[]"

echo "== D5 (I1): board.json / board.md integrity =="
d5p=$T/d5; mkdir -p $d5p
python3 "$B" add --project $d5p --task "one" --agent tl-sonnet-low --owns d5/a >/dev/null
rm -f $d5p/.claude/teamlead/.state/board.json
before_md=$(cat $d5p/.claude/teamlead/board.md)
check "board.json deleted, board.md has rows: render refuses" \
  "$(python3 "$B" render --project $d5p >"$T/d5out" 2>&1; echo $?)" 1
grep -q 'board.md' "$T/d5out" && ok "  stderr names board.md" || bad "  stderr names board.md"
after_md=$(cat $d5p/.claude/teamlead/board.md)
check "  board.md is byte-identical afterwards" "$after_md" "$before_md"

d5p2=$T/d5b; mkdir -p $d5p2
python3 "$B" add --project $d5p2 --task "two" --agent tl-sonnet-low --owns d5b/a >/dev/null
rm -f $d5p2/.claude/teamlead/board.md
check "board.md deleted, board.json non-empty: check fails" \
  "$(python3 "$B" check --project $d5p2 >"$T/d5out2" 2>&1; echo $?)" 1
grep -q 'board.md is missing' "$T/d5out2" && ok "  names it" || bad "  names it"
check "  render recreates it" "$(python3 "$B" render --project $d5p2 >/dev/null 2>&1; echo $?)" 0
check "  check passes now" "$(python3 "$B" check --project $d5p2 >/dev/null 2>&1; echo $?)" 0

echo "== D6 (I6): plan-lint's stable open-question numbers reject reuse of an answered one =="
mknum(){ printf '# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n%b\n\n### Answered\n%b\n\n## Notes from me\n\n' "$1" "${2:-}" | cat -s > "$T/num.md"
  "$PL" "$T/num.md" >"$T/numout" 2>&1; echo $?; }
check "open '1.' while Answered already struck '1.': fails" \
  "$(mknum '1. Q?\n   *Suggest:* x — *y.*' '- ~~1. Old one?~~ → yes → **D1**')" 1
grep -q 'reuses an answered number' "$T/numout" && ok "  names it" || bad "  names it"
check "open '1.' still open while 2 and 3 were answered later: passes (exact membership, not <= max)" \
  "$(mknum '1. Q1 still open?\n   *Suggest:* keep it — *because.*' '- ~~2. Q2?~~ → yes → **D1**\n- ~~3. Q3?~~ → yes → **D1**')" 0
answered9=$(for i in 1 2 3 4 5 6 7 8 9; do printf -- '- ~~%s. Q%s?~~ \xe2\x86\x92 yes \xe2\x86\x92 **D1**\n' "$i" "$i"; done)
check "open '10.' with answered 1-9: ok (continues the sequence)" \
  "$(mknum '10. Q?\n   *Suggest:* x — *y.*' "$answered9")" 0
check "open '3.' used twice: fails" \
  "$(mknum '3. QA?\n   *Suggest:* a — *r.*\n3. QB?\n   *Suggest:* b — *r.*' '')" 1
grep -q 'used more than once' "$T/numout" && ok "  names it" || bad "  names it"
scrambled=$'- ~~5. Q5?~~ \xe2\x86\x92 yes \xe2\x86\x92 **D1**\n- ~~2. Q2?~~ \xe2\x86\x92 yes \xe2\x86\x92 **D1**\n- ~~9. Q9?~~ \xe2\x86\x92 yes \xe2\x86\x92 **D1**'
check "no open questions + scrambled answered numbers: ok" "$(mknum '*(none open)*' "$scrambled")" 0
grep -q "Numbers are stable for the plan's life" "$PS2" && ok "  the skill documents the rule" || bad "  skill documents the rule"

echo "== F2: blocked_by / auto-unblock =="
f2p=$T/f2; mkdir -p $f2p
python3 "$B" add --project $f2p --task "t1" --agent tl-sonnet-low --owns f2/a >/dev/null           # id 1
python3 "$B" add --project $f2p --task "t2" --agent tl-sonnet-low --owns f2/b --blocked-by 1 >/dev/null  # id 2
st=$(python3 -c "import json;d=json.load(open('$f2p/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==2][0];print(t['state'])")
check "task 2 starts blocked" "$st" "blocked"
python3 "$B" update --project $f2p --id 1 --state merged >/dev/null
st2=$(python3 -c "import json;d=json.load(open('$f2p/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==2][0];print(t['state'])")
check "task 2 auto-unblocks once its blocker merges" "$st2" "queued"

python3 "$B" add --project $f2p --task "t3" --agent tl-sonnet-low --owns f2/c >/dev/null            # id 3
python3 "$B" update --project $f2p --id 3 --state blocked >/dev/null
st3=$(python3 -c "import json;d=json.load(open('$f2p/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==3][0];print(t['state'])")
check "'blocked' with no blocked_by is not vacuously auto-unblocked — it stays blocked" "$st3" "blocked"

f2p2=$T/f2b; mkdir -p $f2p2/.claude/teamlead/.state
cat > $f2p2/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 3, "tasks": [
  {"id": 1, "task": "a", "agent": "tl-sonnet-low", "owns": ["f2b/a"], "state": "merged", "branch": null, "plan": null, "blocked_by": [], "notes": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "b", "agent": "tl-sonnet-low", "owns": ["f2b/b"], "state": "blocked", "branch": null, "plan": null, "blocked_by": [1], "notes": null, "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $f2p2 >/dev/null 2>&1     # regenerate board.md to match, so only the invariant below is under test
python3 "$B" check --project $f2p2 >"$T/f2out" 2>&1; rc=$?
check "check flags a hand-written 'blocked' task whose blockers are already merged" "$rc" 1
grep -q 'all its blockers are merged' "$T/f2out" && ok "  names it" || bad "  names it"

echo "== CLI --blocked-by parses to a list of ints, not a string (I7) =="
bbp=$T/bbint; mkdir -p $bbp
python3 "$B" add --project $bbp --task "base" --agent tl-sonnet-low --owns bb/a >/dev/null          # id 1
python3 "$B" add --project $bbp --task "dep" --agent tl-sonnet-low --owns bb/b --blocked-by 1 >/dev/null  # id 2
bt=$(python3 -c "import json;d=json.load(open('$bbp/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==2][0];print(repr(t['blocked_by']))")
check "blocked_by is stored as [1] (ints), not ['1'] or a raw string" "$bt" "[1]"

echo "== F6: datetime.UTC is not used (Python 3.10 compat) =="
check "no datetime.UTC usage in board.py" "$(grep -c 'datetime.UTC' "$CLAUDE_PLUGIN_ROOT/scripts/board.py")" 0

echo "== F10: resolve.sh's hardcoded agent tiers match agents/*.md exactly =="
resolved=$(sed -n '/^case "\$effort" in/,/^esac/p' "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" | grep -oE 'tl-(opus|sonnet)-[a-z]+' | sort -u)
actual_agents=$(cd "$CLAUDE_PLUGIN_ROOT" && ls agents/*.md | xargs -n1 basename | sed 's/\.md$//' | sort -u)
check "resolve.sh's tiers == agents/*.md basenames (set equality)" "$resolved" "$actual_agents"

echo "== F12: mutate refuses only the overlap it touches, not a pre-existing unrelated one =="
f12p=$T/f12; mkdir -p $f12p/.claude/teamlead/.state
cat > $f12p/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 4, "tasks": [
  {"id": 1, "task": "a", "agent": "tl-sonnet-low", "owns": ["f12/shared"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "b", "agent": "tl-sonnet-low", "owns": ["f12/shared"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "created": "x", "updated": "x"},
  {"id": 3, "task": "c", "agent": "tl-sonnet-low", "owns": ["f12/other"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $f12p >/dev/null 2>&1
check "update on the unrelated task (3): exit 0" \
  "$(python3 "$B" update --project $f12p --id 3 --notes x >/dev/null 2>&1; echo $?)" 0
check "update on a task IN the pre-existing overlap (1): exit 1" \
  "$(python3 "$B" update --project $f12p --id 1 --notes x >"$T/f12out" 2>&1; echo $?)" 1
grep -q 'overlapping' "$T/f12out" && ok "  names the overlap" || bad "  names the overlap"
python3 "$B" check --project $f12p >"$T/f12out2" 2>&1
grep -q 'overlapping' "$T/f12out2" && ok "  check still reports it" || bad "  check still reports it"

echo "== decompose =="
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"go"}' | "$H/mode.sh" >/dev/null
echo x >> src/a.py
check "one file changed -> no nag" "$(ev "$STOP" "$H/gate.sh")" 0
echo x >> src/b.py
check "two files, stale board -> blocks" "$(ev "$STOP" "$H/gate.sh")" 2
touch .claude/teamlead/board.md
check "board updated -> passes" "$(ev "$STOP" "$H/gate.sh")" 0

echo "== worktrees =="
# A worker's worktree is always .claude/worktrees/agent-<id>; check 3 ignores any other
# linked worktree that no board row names (see the #9 scope tests below).
git worktree add -q "$T/.claude/worktrees/agent-w1" -b w1 2>/dev/null; echo dirty > "$T/.claude/worktrees/agent-w1/new.txt"
check "dirty worktree blocks" "$(ev "$STOP" "$H/gate.sh")" 2

echo "== activation / deactivation =="
rm -rf "$proj/.claude"
A='{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"/teamlead"}'
ev "$A" "$H/mode.sh" >/dev/null
[ -f .claude/teamlead/.state/active ] && ok "activation creates the flag" || bad "activation creates the flag"
grep -q '^| ✓ | ID | Task |' .claude/teamlead/board.md && ok "board seeded as a table" || bad "board seeded as a table"
NA='{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"please act as a team lead"}'
rm -rf "$proj/.claude"
ev "$NA" "$H/mode.sh" >/dev/null
[ -f .claude/teamlead/.state/active ] && bad "'please act as a team lead' activates" || ok "'please act as a team lead' does not activate"
ev "$A" "$H/mode.sh" >/dev/null   # actually activate, so the deactivation checks below have a flag to remove
N1='{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"ok stop teamlead"}'
ev "$N1" "$H/mode.sh" >/dev/null
[ -f .claude/teamlead/.state/active ] && ok "'ok stop teamlead' does not remove the flag" || bad "'ok stop teamlead' removed the flag"
N2='{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"switch to normal mode"}'
ev "$N2" "$H/mode.sh" >/dev/null
[ -f .claude/teamlead/.state/active ] && ok "'switch to normal mode' does not remove the flag" || bad "'switch to normal mode' removed the flag"
S='{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"/teamlead stop"}'
ev "$S" "$H/mode.sh" >/dev/null
[ -f .claude/teamlead/.state/active ] && bad "stop removes the flag" || ok "stop removes the flag"

echo "== reconcile counts state from JSON, not from text =="
mkdir -p .claude/teamlead/.state; : > .claude/teamlead/.state/active   # re-arm
git -C "$T/.claude/worktrees/agent-w1" reset -q --hard 2>/dev/null; rm -f "$T/.claude/worktrees/agent-w1/new.txt" 2>/dev/null
rm -f .claude/teamlead/.state/board.json
python3 "$B" add --project $proj --task "running the migration script" --agent tl-sonnet-low --owns src/x >/dev/null
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf "$NOW  dispatch  agent=tl-sonnet-low\n$NOW  start     agent=tl-sonnet-low  id=q1\n$NOW  return    agent=tl-sonnet-low  id=q1  msg=x\n" > .claude/teamlead/.state/events.log
check "a task whose TEXT starts with 'running' is not counted" "$(ev "$STOP" "$H/gate.sh")" 0
python3 "$B" update --project $proj --id 1 --state running --branch wt1 >/dev/null
check "a real running task with 0 out blocks" "$(ev "$STOP" "$H/gate.sh")" 2
python3 "$B" update --project $proj --id 1 --state merged >/dev/null
rm -f .claude/teamlead/.state/events.log

echo "== plugin root is discoverable without the env var =="
CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"hi"}' "$H/mode.sh" >/dev/null
check "hook pins plugin-root for the skills" "$(cat .claude/teamlead/.state/plugin-root 2>/dev/null)" "$CLAUDE_PLUGIN_ROOT"

echo "== routing re-injected after first-run setup =="
rm -f .claude/teamlead/.state/routing-shown
printf 'effort: medium\nopus: on-demand\n' > .claude/teamlead/settings.md
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"hi"}' "$H/mode.sh" >/dev/null
grep -q 'Workhorse:' "$T/out" && ok "routing shown once after settings change" || bad "routing shown once after settings change"
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"hi again"}' "$H/mode.sh" >/dev/null
grep -q 'Workhorse:' "$T/out" && bad "routing not repeated every turn" || ok "routing not repeated every turn"

echo "== retry ladder: a resumed worker is tracked =="
mkdir -p .claude/teamlead/.state; : > .claude/teamlead/.state/active
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf "$NOW  dispatch  agent=tl-sonnet-high\n$NOW  start     agent=tl-sonnet-high  id=w7\n$NOW  return    agent=tl-sonnet-high  id=w7  msg=done\n" > $L
check "after return, nothing outstanding" "$(ev "$STOP" "$H/gate.sh")" 0
SM='{"hook_event_name":"PreToolUse","cwd":"'$proj'","tool_name":"SendMessage","tool_input":{"to":"w7","summary":"one correction"}}'
ev "$SM" "$H/record.sh" >/dev/null
grep -q '  resume    id=w7' $L && ok "resume recorded" || bad "resume recorded"
check "resumed worker counts as outstanding (ledger)" "$(outn)" 1
check "  but does not block the gate — it is running in the background" "$(ev "$STOP" "$H/gate.sh")" 0
R7='{"hook_event_name":"SubagentStop","cwd":"'$proj'","agent_type":"teamlead:tl-sonnet-high","agent_id":"w7","last_assistant_message":"fixed"}'
ev "$R7" "$H/record.sh" >/dev/null
check "its return clears the gate again" "$(ev "$STOP" "$H/gate.sh")" 0
SMX='{"hook_event_name":"PreToolUse","cwd":"'$proj'","tool_name":"SendMessage","tool_input":{"to":"not-our-agent","summary":"hi"}}'
ev "$SMX" "$H/record.sh" >/dev/null
grep -q 'not-our-agent' $L && bad "ignores agents not ours" || ok "ignores agents not ours"
rm -f $L

echo "== an abandoned dispatch must not nag forever =="
old=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)
printf '%s  dispatch  agent=tl-sonnet-low  desc=killed worker\n' "$old" > $L
check "stale unreturned dispatch ages out" "$(ev "$STOP" "$H/gate.sh")" 0
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  dispatch  agent=tl-sonnet-low  desc=live worker\n' "$now" > $L
check "a just-dispatched worker (no start yet) does not block either" "$(ev "$STOP" "$H/gate.sh")" 0
check "  it is pending in the ledger" "$(python3 "$B" ledger --project $proj | python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"])')" 1
printf '%s  start     agent=tl-sonnet-low  id=z1\n' "$now" >> $L
check "once started, it is tracked by id not by pending" "$(python3 "$B" ledger --project $proj | python3 -c 'import json,sys;d=json.load(sys.stdin);print(str(len(d["outstanding"]))+","+str(d["pending"]))')" "1,0"
rm -f $L

echo "== vocabulary is consistent: 'working', never 'out'/'running' =="
NOW2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  start     agent=tl-sonnet-high  id=v1\n' "$NOW2" > $L
check "an outstanding worker alone: gate exits 0" "$(ev "$STOP" "$H/gate.sh")" 0
check "  and prints nothing" "$(cat "$T/out")" ""
grep -qE 'worker\(s\) (still )?out\b' "$T/out" && bad "gate still says 'out'" || ok "gate no longer says 'out'"
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"hi"}' "$H/mode.sh" >/dev/null
grep -q 'worker(s) working' "$T/out" && ok "per-turn line says working" || ok "per-turn line quiet (no open tasks)"
# the per-turn count must come from id-pairing, not dispatch-minus-return
printf '%s  dispatch  agent=tl-sonnet-high\n%s  start     agent=tl-sonnet-high  id=v2\n%s  return    agent=tl-sonnet-high  id=v2  msg=x\n%s  resume    id=v2  summary=fix\n' "$NOW2" "$NOW2" "$NOW2" "$NOW2" > $L
n=$(python3 "$B" ledger --project $proj | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d["outstanding"]))')
check "a resumed worker counts as working" "$n" 1
rm -f $L

echo "== concise reminder =="
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"hi"}' "$H/mode.sh" >/dev/null
grep -q 'Concise output style is active' "$T/out" && ok "concise reminder injected per turn" || bad "concise reminder injected per turn"

echo "== worker fence =="
F="$H/worktree-fence.sh"
fence(){ out=$(echo "$1" | "$F"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }
W='"agent_id":"w1","agent_type":"tl-sonnet-low"'
check "lead is never fenced"          "$(fence '{"cwd":"/wt","tool_input":{"file_path":"/elsewhere/x"}}')" allow
check "internal agent is not fenced"  "$(fence '{"cwd":"/wt","agent_id":"i","agent_type":"","tool_input":{"file_path":"/elsewhere/x"}}')" allow
check "worker: inside worktree"       "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"file_path":"/wt/src/x"}}')" allow
check "worker: relative path"         "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"file_path":"src/x"}}')" allow
check "worker: namespaced type is fenced" "$(fence '{"cwd":"/wt","agent_id":"w1","agent_type":"teamlead:tl-sonnet-low","tool_input":{"file_path":"/home/u/other/x"}}')" deny
check "worker: ../ escape"            "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"file_path":"../main/x"}}')" deny
check "worker: absolute elsewhere"    "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"file_path":"/home/u/other/x"}}')" deny
check "worker: session scratchpad allowed" "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"file_path":"/tmp/claude-1000/sess/scratchpad/n.md"}}')" allow
check "worker: other /tmp still denied"   "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"file_path":"/tmp/elsewhere/x"}}')" deny
check "worker: notebook_path too"     "$(fence '{"cwd":"/wt",'"$W"',"tool_input":{"notebook_path":"/home/u/n.ipynb"}}')" deny

echo "== worker fence: scratchpad is scoped to the calling session (F9) =="
check "worker: own session's scratchpad allowed" \
  "$(fence '{"cwd":"/wt",'"$W"',"session_id":"S1","tool_input":{"file_path":"/tmp/claude-1000/x/S1/scratchpad/a"}}')" allow
check "worker: another session's scratchpad denied" \
  "$(fence '{"cwd":"/wt",'"$W"',"session_id":"S1","tool_input":{"file_path":"/tmp/claude-1000/x/S2/scratchpad/a"}}')" deny

echo "== worker fence: owns exception for out-of-project targets, Bash decision (#7) =="
# Non-git project P, an out-of-project dir O, and a board row owning O by absolute path.
FP="$T/fp/proj"; FO="$T/fp/outside"; FX="$T/fp/other"; mkdir -p "$FP/.claude/teamlead/.state" "$FO" "$FX"
ln -s "$FX" "$FP/linkout"; ln -s "$FX" "$FO/linkx"
fboard(){ printf '{"next_id":9,"tasks":[%s]}' "$1" > "$FP/.claude/teamlead/.state/board.json"; }
frow(){ printf '{"id":%s,"state":"%s","worker":"%s","owns":%s}' "$1" "$2" "$3" "$4"; }
fencep(){ out=$(echo "$1" | CLAUDE_PROJECT_DIR="$FP" "$F"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }
fe(){ jq -nc --arg c "$FP" --arg f "$1" --arg a "${2:-w1}" '{cwd:$c,agent_id:$a,agent_type:"tl-sonnet-low",tool_name:"Edit",tool_input:{file_path:$f}}'; }
fboard ""
check "no board row: out-of-project Edit refused"        "$(fencep "$(fe "$FO/x")")" deny
fboard "$(frow 1 running w1 "[\"$FO\"]")"
check "owns (absolute dir): Edit in it allowed"          "$(fencep "$(fe "$FO/sub/x")")" allow
check "owns: the owned dir itself"                       "$(fencep "$(fe "$FO")")" allow
check "owns: a sibling with the same prefix is refused"  "$(fencep "$(fe "${FO}2/x")")" deny
check "owns: .. out of the owned dir is refused"         "$(fencep "$(fe "$FO/../other/x")")" deny
check "owns: symlink inside owns pointing out is refused" "$(fencep "$(fe "$FO/linkx/x")")" deny
check "owns: another worker's row is not honoured"       "$(fencep "$(fe "$FO/x" w2)")" deny
check "owns: still inside the project too"               "$(fencep "$(fe "$FP/src/x")")" allow
fboard "$(frow 1 running w1 "[\"$FO/\"]")"
check "owns: trailing slash"                             "$(fencep "$(fe "$FO/x")")" allow
fboard "$(frow 1 merged w1 "[\"$FO\"]")"
check "owns: a merged row grants nothing"                "$(fencep "$(fe "$FO/x")")" deny
fboard "$(frow 1 returned w1 "[\"$FO\"]")"
check "owns: a returned row (retry) still counts"        "$(fencep "$(fe "$FO/x")")" allow
fboard "$(frow 1 running w1 "[\"outside\"]")"
check "owns: a relative entry grants nothing outside"    "$(fencep "$(fe "$FO/x")")" deny
fboard "$(frow 1 running w1 "[\"/\"]")"
check "owns: / is ignored, not a blank cheque"           "$(fencep "$(fe "$FO/x")")" deny
fboard "$(frow 1 running w1 "[\"~/.tlfence-test\"]")"
check "owns: ~ expands to \$HOME"                        "$(fencep "$(fe "$HOME/.tlfence-test/x")")" allow
check "owns: ~ does not widen to the rest of \$HOME"     "$(fencep "$(fe "$HOME/.other/x")")" deny
fboard "$(frow 1 running w1 "[\"$FO/*.conf\"]")"
check "owns: a glob entry matches"                       "$(fencep "$(fe "$FO/a.conf")")" allow
check "owns: a glob entry does not match other names"    "$(fencep "$(fe "$FO/a.txt")")" deny
fboard "$(frow 1 running w1 "[\"$FO\"]")"
check "owns: MultiEdit is covered"  "$(fencep "$(fe "$FO/x" | jq -c '.tool_name="MultiEdit"')")" allow
check "owns: NotebookEdit is covered" "$(fencep "$(fe "$FO/x" | jq -c --arg p "$FO/n.ipynb" '.tool_input={notebook_path:$p}|.tool_name="NotebookEdit"')")" allow
check "NotebookEdit outside owns refused" "$(fencep "$(fe "$FO/x" | jq -c --arg p "$FX/n.ipynb" '.tool_input={notebook_path:$p}|.tool_name="NotebookEdit"')")" deny
check "symlink inside the project pointing out is refused" "$(fencep "$(fe "$FP/linkout/x")")" deny
fboard ""
check "non-git project: project dir is writable from a subdir cwd" \
  "$(fencep "$(fe "$FP/src/x" | jq -c --arg c "$FP/sub" '.cwd=$c')")" allow
# Bash is not fenced (decision recorded in worktree-fence.sh): the hook is only registered for
# the file tools, and an unfenced tool must never be refused if it does reach the hook.
check "Bash write outside is not fenced (documented, not parsed)" \
  "$(fencep "$(jq -nc --arg c "$FP" '{cwd:$c,agent_id:"w1",agent_type:"tl-sonnet-low",tool_name:"Bash",tool_input:{command:"cp a /nowhere/x"}}')")" allow
check "hooks.json registers the fence on the file tools only" \
  "$(jq -r '[.hooks.PreToolUse[]|select(any(.hooks[];.command|test("worktree-fence")))|.matcher]|join(",")' "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json")" "Edit|Write|MultiEdit|NotebookEdit"
fmsg=$(fe "$FO/x" | CLAUDE_PROJECT_DIR="$FP" "$F" | jq -r .hookSpecificOutput.permissionDecisionReason)
case "$fmsg" in *owns*Bash*|*Bash*owns*) ok "refusal names the owns exception and that Bash is no way round" ;; *) bad "refusal names the owns exception and that Bash is no way round (got: $fmsg)" ;; esac
case "$fmsg" in *"SCOPE REQUEST"*SendMessage*main*|*SendMessage*main*"SCOPE REQUEST"*) ok "refusal tells the worker to send a SCOPE REQUEST" ;; *) bad "refusal tells the worker to send a SCOPE REQUEST (got: $fmsg)" ;; esac
for ag in "$CLAUDE_PLUGIN_ROOT"/agents/tl-*.md; do
  grep -q 'ask the lead for it with a `SCOPE REQUEST`' "$ag" && ok "  $(basename "$ag"): boundary line points at SCOPE REQUEST" || bad "  $(basename "$ag"): boundary line points at SCOPE REQUEST"
done
# git project: a worker that inherited a subdirectory cwd is anchored to the project, a linked
# worktree worker is not allowed into the main checkout.
FG="$T/fg"; mkdir -p "$FG/src" "$FG/sub"; git -C "$FG" init -q; git -C "$FG" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m i
git -C "$FG" worktree add -q "$FG/.claude/worktrees/agent-x" -b wt-x 2>/dev/null
ge(){ jq -nc --arg c "$1" --arg f "$2" '{cwd:$c,agent_id:"w1",agent_type:"tl-sonnet-low",tool_name:"Write",tool_input:{file_path:$f}}'; }
fenceg(){ out=$(echo "$1" | CLAUDE_PROJECT_DIR="$FG" "$F"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }
check "git: subdir cwd, write elsewhere in the project allowed" "$(fenceg "$(ge "$FG/sub" "$FG/build/tmp/x.sh")")" allow
check "git: subdir cwd, outside the project still refused"       "$(fenceg "$(ge "$FG/sub" "$FO/x")")" deny
check "git: linked-worktree worker may not write the main checkout" "$(fenceg "$(ge "$FG/.claude/worktrees/agent-x" "$FG/src/x")")" deny
check "git: linked-worktree worker writes its own worktree"         "$(fenceg "$(ge "$FG/.claude/worktrees/agent-x" "$FG/.claude/worktrees/agent-x/src/x")")" allow
mkdir -p "$FG/.claude/teamlead/.state"
printf '{"next_id":2,"tasks":[{"id":1,"state":"running","worker":"w1","owns":["%s"]}]}' "$FO" > "$FG/.claude/teamlead/.state/board.json"
check "git: worktree worker finds its row in the MAIN checkout's board" "$(fenceg "$(ge "$FG/.claude/worktrees/agent-x" "$FO/x")")" allow

echo "== worker fence: an owned outside path also answers Claude Code's permission prompt =="
# "allow" via fence() above is "no output OR allow JSON"; here tell the two apart.
fjson(){ echo "$1" | CLAUDE_PROJECT_DIR="$FG" "$F"; }
WTX="$FG/.claude/worktrees/agent-x"
fjo=$(fjson "$(ge "$WTX" "$FO/sub/x")")
check "owned absolute path outside the worktree: allow JSON" "$(jq -r .hookSpecificOutput.permissionDecision <<<"$fjo")" allow
check "  ... event name is PreToolUse"                       "$(jq -r .hookSpecificOutput.hookEventName <<<"$fjo")" PreToolUse
check "  ... reason names the board row"                     "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$fjo")" "teamlead: path is in board row 1's owns"
check "in-worktree write: plain pass, no allow JSON"         "$(fjson "$(ge "$WTX" "$WTX/src/x")")" ""
check "scratchpad write: plain pass, no allow JSON"          "$(fjson "$(ge "$WTX" "/tmp/claude-1000/a/S/scratchpad/x" | jq -c '.session_id="S"')")" ""
check "unowned outside path: still refused"                  "$(fenceg "$(ge "$WTX" "$FX/x")")" deny
printf '{"next_id":2,"tasks":[{"id":1,"state":"running","worker":"w1","owns":["hooks/"]}]}' > "$FG/.claude/teamlead/.state/board.json"
check "relative owns does not open the main checkout"        "$(fenceg "$(ge "$WTX" "$FG/hooks/x")")" deny
check "relative owns: no allow JSON for an in-worktree write" "$(fjson "$(ge "$WTX" "$WTX/hooks/x")")" ""

echo "== scope requests: agents carry the block, the lead skill has the paragraph =="
for ag in "$CLAUDE_PLUGIN_ROOT"/agents/tl-*.md; do
  grep -q '^SCOPE REQUEST: <path or glob>$' "$ag" && grep -q 'SendMessage. to `"main"`' "$ag" && grep -q 'starts with' "$ag" \
    && ok "  $(basename "$ag"): SCOPE REQUEST block" || bad "  $(basename "$ag"): SCOPE REQUEST block"
done
grep -q '^\*\*Scope requests\.\*\*' "$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md" && ok "  teamlead skill: Scope requests paragraph" || bad "  teamlead skill: Scope requests paragraph"

echo "== worker scratch: .tl-scratch/ rule in every agent, lead rule, git exclude =="
for ag in "$CLAUDE_PLUGIN_ROOT"/agents/tl-*.md; do
  grep -q '`\.tl-scratch/`' "$ag" && grep -q 'never use the session scratchpad' "$ag" && grep -q 'never create a symlink out of the worktree' "$ag" \
    && grep -q 'TMPDIR. at `\.tl-scratch/tmp`' "$ag" && grep -q 'you never commit it' "$ag" \
    && ok "  $(basename "$ag"): .tl-scratch rule" || bad "  $(basename "$ag"): .tl-scratch rule"
done
grep -q 'Never point a worker at files in your own session scratchpad' "$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md" \
  && grep -q 'says where outputs go: `\.tl-scratch/`' "$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md" \
  && ok "  teamlead skill: no scratchpad for workers" || bad "  teamlead skill: no scratchpad for workers"
tsx="$T/tsx"; mkdir -p "$tsx/.claude/teamlead/.state"; : > "$tsx/.claude/teamlead/.state/active"
git -C "$tsx" init -q
tsxs='{"hook_event_name":"SubagentStart","cwd":"'$tsx'","agent_type":"teamlead:tl-sonnet-high","agent_id":"tsx1"}'
check "SubagentStart record.sh: exit 0" "$(ev "$tsxs" "$H/record.sh")" 0
ev "$tsxs" "$H/record.sh" >/dev/null
check "  .tl-scratch/ in info/exclude exactly once after two starts" "$(grep -cxF '.tl-scratch/' "$tsx/.git/info/exclude")" 1
echo x > "$tsx/f"; mkdir -p "$tsx/.tl-scratch"; echo x > "$tsx/.tl-scratch/o.log"
check "  git ignores .tl-scratch/" "$(git -C "$tsx" status --porcelain -uall | grep -c tl-scratch)" 0
tsxw="$T/tsxw"; git -C "$tsx" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m i
git -C "$tsx" worktree add -q "$tsxw" >/dev/null 2>&1; mkdir -p "$tsxw/.tl-scratch"; echo x > "$tsxw/.tl-scratch/o.log"
check "  ... and in a linked worktree" "$(git -C "$tsxw" status --porcelain -uall | grep -c tl-scratch)" 0
tsxn="$T/tsxn"; mkdir -p "$tsxn/.claude/teamlead/.state"; : > "$tsxn/.claude/teamlead/.state/active"
check "non-git project: hook still exits 0, no exclude written" "$(ev "$(sed "s|$tsx|$tsxn|" <<<"$tsxs")" "$H/record.sh")" 0

echo "== plan-lint stage awareness =="
mkplan(){ cat > "$T/pl.md" <<PEOF
# T

> **Stage $1** — working it out · started 2026-09-16

## Goal
G

## Context
C

## Decisions
- **D1** a call — *why.*

## Done when
- [ ] it works — *verified by: agent*

## Implementation plan
$3

## Open questions
1. A question?
   *Suggest:* this one — *because.*
$2

### Answered

## Notes from me

PEOF
cat -s "$T/pl.md" > "$T/pl.md.sq" && mv "$T/pl.md.sq" "$T/pl.md"
"$PL" "$T/pl.md" >"$T/plout" 2>&1; echo $?; }
TBL='*Built from D1 · decisions:XX*

| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | do it — **D1** | `tl-sonnet-low` | src/a/ | — |'
check "stage 3 with no impl plan is clean" "$(mkplan 3 '' '')" 0
check "empty '> me:' placeholder is not an answer" "$(mkplan 3 '   > me:' '')" 0
check "the written form '> me: ' (trailing space) is not an answer" "$(mkplan 3 '   > me: ' '')" 0
check "several trailing spaces still not an answer" "$(mkplan 3 '   > me:   ' '')" 0
check "a real '> me:' answer is flagged" "$(mkplan 3 '   > me: yes do it' '')" 1
grep -q 'promote it to a Decision' "$T/plout" && ok "  says to promote it" || bad "  says to promote it"
check "unreferenced decision flagged once a plan exists" "$(mkplan 4 '' '| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | unrelated work | `tl-sonnet-low` | src/a/ | — |')" 1
grep -q 'D1 is decided but no implementation step' "$T/plout" && ok "  names the orphaned decision" || bad "  names the orphaned decision"

echo "== 'merged' is verified against git, not trusted =="
gp=$T/gp; mkdir -p $gp; cd $gp; git init -q; git config user.email t@t.t; git config user.name t
printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > .gitignore
echo base > a.txt; git add -A >/dev/null; git commit -qm init
# D3: the task must own the path the branch actually changes. `diff --quiet`
# is clean whenever the pathspec matches nothing on either side, so owning
# src/x (a path 'feat' never touches) used to pass vacuously even though the
# branch's real commits were never merged. The shortcut now only counts when
# the branch's name-only diff against the merge-base under `owns` is
# non-empty; an untouched (or typo'd) `owns` falls back to rev-list, which
# still flags the unmerged commits below and in the dedicated case further
# down.
python3 "$B" add --project $gp --task w --agent tl-sonnet-high --owns b.txt >/dev/null
git checkout -q -b feat; echo work > b.txt; git add -A >/dev/null; git commit -qm work; git checkout -q master
python3 "$B" update --project $gp --id 1 --state merged --branch feat >/dev/null
python3 "$B" check --project $gp >"$T/gout" 2>&1; rc=$?
check "false 'merged' is caught" "$rc" 1
grep -q 'not actually merged back' "$T/gout" && ok "  names the unmerged branch" || bad "  names the unmerged branch"
git merge -q feat
check "true 'merged' passes" "$(python3 "$B" check --project $gp >/dev/null 2>&1; echo $?)" 0
python3 "$B" update --project $gp --id 1 --branch "" >/dev/null 2>&1 || true
cd $proj

echo "== D3: squash merges are recognized as merged (owned-path diff, not rev-list) =="
sqp=$T/sq; mkdir -p $sqp; git -C $sqp init -q; git -C $sqp config user.email t@t.t; git -C $sqp config user.name t
printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > $sqp/.gitignore
echo base > $sqp/a.txt; git -C $sqp add -A >/dev/null; git -C $sqp commit -qm init
python3 "$B" add --project $sqp --task sq1 --agent tl-sonnet-high --owns c.txt >/dev/null   # id 1
git -C $sqp checkout -q -b sqfeat; echo work > $sqp/c.txt; git -C $sqp add -A >/dev/null; git -C $sqp commit -qm work; git -C $sqp checkout -q master
git -C $sqp merge -q --squash sqfeat >/dev/null; git -C $sqp commit -qm 'squash merge sqfeat' >/dev/null
python3 "$B" update --project $sqp --id 1 --state merged --branch sqfeat >/dev/null
check "a real squash merge (owned path caught up): check passes" \
  "$(python3 "$B" check --project $sqp >/dev/null 2>&1; echo $?)" 0

python3 "$B" add --project $sqp --task sq2 --agent tl-sonnet-high --owns d.txt >/dev/null   # id 2
git -C $sqp checkout -q -b sqfeat2; echo work2 > $sqp/d.txt; git -C $sqp add -A >/dev/null; git -C $sqp commit -qm work2; git -C $sqp checkout -q master
python3 "$B" update --project $sqp --id 2 --state merged --branch sqfeat2 >/dev/null
python3 "$B" check --project $sqp >"$T/sqout" 2>&1; rc=$?
check "a claimed squash merge whose owned path still differs: caught" "$rc" 1
grep -q 'not actually merged back' "$T/sqout" && ok "  names it" || bad "  names it"
git -C $sqp merge -q --squash sqfeat2 >/dev/null; git -C $sqp commit -qm 'squash merge sqfeat2' >/dev/null
check "  and once actually squash-merged, check passes again" \
  "$(python3 "$B" check --project $sqp >/dev/null 2>&1; echo $?)" 0

python3 "$B" add --project $sqp --task sq3 --agent tl-sonnet-high >/dev/null                # id 3, read-only (no --owns)
git -C $sqp checkout -q -b sqfeat3; echo work3 > $sqp/e.txt; git -C $sqp add -A >/dev/null; git -C $sqp commit -qm work3; git -C $sqp checkout -q master
python3 "$B" update --project $sqp --id 3 --state merged --branch sqfeat3 >/dev/null
python3 "$B" check --project $sqp >"$T/sqout2" 2>&1; rc2=$?
check "a read-only task (no owns) with an unmerged branch: still caught (rev-list only)" "$rc2" 1
grep -q 'not actually merged back' "$T/sqout2" && ok "  names it" || bad "  names it"

echo "== D3: a typo'd/untouched 'owns' no longer passes 'diff --quiet' vacuously =="
mkdir -p $sqp/src/d
python3 "$B" add --project $sqp --task sq4 --agent tl-sonnet-high --owns src/d-typo >/dev/null   # id 4, owns a path the branch never touches
git -C $sqp checkout -q -b sqfeat4; echo work4 > $sqp/src/d/file.txt; git -C $sqp add -A >/dev/null; git -C $sqp commit -qm work4; git -C $sqp checkout -q master
python3 "$B" update --project $sqp --id 4 --state merged --branch sqfeat4 >/dev/null
python3 "$B" check --project $sqp >"$T/sqout3" 2>&1; rc3=$?
check "typo'd owns (branch never touched it): not merged, caught by rev-list fallback" "$rc3" 1
grep -q 'not actually merged back' "$T/sqout3" && ok "  names it" || bad "  names it"

echo "== status command =="
python3 "$B" status --project $gp > "$T/st" 2>&1
grep -q 'teamlead —' "$T/st" && ok "status prints a summary line" || bad "status prints a summary line"

echo "== events.log rotation =="
rl=$proj/.claude/teamlead/.state/events.log
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in $(seq 1 4100); do printf '%s  start     agent=tl-sonnet-low  id=r%s\n' "$NOW" "$i"; done > $rl
ev '{"hook_event_name":"SubagentStart","cwd":"'$proj'","agent_type":"teamlead:tl-sonnet-low","agent_id":"rot"}' "$H/record.sh" >/dev/null
n=$(wc -l < $rl)
[ "$n" -le 2100 ] && ok "log rotated (now $n lines)" || bad "log rotated (got $n)"
[ -f $proj/.claude/teamlead/.state/events.archive.log ] && ok "  old lines archived" || bad "  old lines archived"
rm -f $rl $proj/.claude/teamlead/.state/events.archive.log

echo "== runtime state is gitignored =="
# tl_ensure_gitignore now writes one blanket line, '.claude/teamlead/', and
# migrates away the two old, narrower lines it used to write.
rm -rf $proj/.claude $proj/.gitignore
printf 'node_modules/\n' > $proj/.gitignore
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"/teamlead"}' "$H/mode.sh" >/dev/null
check "state dir ignored" "$(grep -cxF '.claude/teamlead/' $proj/.gitignore)" 1
check "board.md ignored" "$(git -C $proj check-ignore -q .claude/teamlead/board.md; echo $?)" 0
grep -qxF '.claude/teamlead/.state/' $proj/.gitignore && bad "  old state-dir line still present" || ok "  old state-dir line removed"
grep -qxF '.claude/teamlead/board.md' $proj/.gitignore && bad "  old board.md line still present" || ok "  old board.md line removed"
grep -qxF 'node_modules/' $proj/.gitignore && ok "  a pre-existing line is preserved" || bad "  a pre-existing line is preserved"
before=$(wc -l < $proj/.gitignore)
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"/teamlead"}' "$H/mode.sh" >/dev/null
check "not duplicated on re-activation" "$(wc -l < $proj/.gitignore)" "$before"
# A project activated by an older version has the flag but the OLD two-line form.
rm -f $proj/.gitignore
printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > $proj/.gitignore
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"ordinary turn"}' "$H/mode.sh" >/dev/null
check "backfilled on an ordinary turn" "$(grep -cxF '.claude/teamlead/' $proj/.gitignore)" 1
grep -qxF '.claude/teamlead/.state/' $proj/.gitignore && bad "  and migrates the old lines away" || ok "  and migrates the old lines away"
rm -f $proj/.gitignore
ev '{"hook_event_name":"SessionStart","cwd":"'$proj'","source":"startup"}' "$H/restore.sh" >/dev/null
check "backfilled on session restore" "$(grep -cxF '.claude/teamlead/' $proj/.gitignore)" 1

echo "== routing resolution =="
mkdir -p .claude/teamlead
printf 'effort: xlow\nopus: never\n' > .claude/teamlead/settings.md
r=$("$H/resolve.sh" "$proj")
grep -q 'Workhorse: tl-sonnet-medium' <<<"$r" && ok "xlow lowers the workhorse" || bad "xlow lowers the workhorse"
grep -q 'tl-opus-\*' <<<"$r" && ok "never bans Opus" || bad "never bans Opus"
grep -q 'Vision.*tl-opus-medium' <<<"$r" && ok "vision survives opus:never + xlow" || bad "vision survives opus:never + xlow"
grep -q 'Never tl-opus-high for vision' <<<"$r" && ok "vision capped below high" || bad "vision capped below high"
printf 'effort: medium\nopus: always\n' > .claude/teamlead/settings.md
r=$("$H/resolve.sh" "$proj")
grep -q 'Workhorse: tl-opus-medium · Scout: tl-opus-low' <<<"$r" && ok "always promotes workhorse+scout to Opus" || bad "always promotes workhorse+scout to Opus"
grep -q 'tl-sonnet-\*' <<<"$r" && ok "always bans Sonnet" || bad "always bans Sonnet"
grep -q 'Vision.*tl-opus-medium' <<<"$r" && ok "vision survives opus:always" || bad "vision survives opus:always"
printf 'effort: high\nopus: always\n' > .claude/teamlead/settings.md
r=$("$H/resolve.sh" "$proj")
grep -q 'Workhorse: tl-opus-high' <<<"$r" && ok "always still discriminates on effort (high != medium)" || bad "always still discriminates on effort (high != medium)"

echo "== a question carries the lead's recommendation =="
mkq(){ printf '# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n%b\n\n### Answered\n%b\n\n## Notes from me\n\n' "$1" "${2:-}" | cat -s > "$T/q.md"
  "$PL" "$T/q.md" >"$T/qout" 2>&1; echo $?; }
check "a bare question fails" "$(mkq '1. Per key or per IP?\n   > me: ')" 1
grep -q 'Your call' "$T/qout" && ok "  offers the honest opt-out" || bad "  offers the opt-out"
check "'*Suggest:*' satisfies it" "$(mkq '1. Per key or per IP?\n   *Suggest:* per key — *shared IPs.*\n   > me: ')" 0
check "'*Your call:*' satisfies it" "$(mkq '1. Your deadline?\n   *Your call:* only you know.\n   > me: ')" 0
check "a one-line question may carry it inline" "$(mkq '1. Per key or per IP? *Suggest:* per key.\n   > me: ')" 0
check "counts every bare one" "$(mkq '1. A?\n   *Suggest:* x.\n2. B?\n3. C?')" 1
grep -q '2 open question' "$T/qout" && ok "  counts 2 of 3" || bad "  counts 2 of 3"
# Struck questions under ### Answered already have their answer — demanding a
# suggestion there would fire on a correct plan.
check "an answered question needs none" "$(mkq '*(none open)*' '- ~~Old one?~~ → yes → **D1**')" 0
grep -q 'Never ask a bare question' "$PS2" && ok "  the plan skill says why" || bad "  plan skill says why"
grep -q 'Never ask a bare question' "$CLAUDE_PLUGIN_ROOT/skills/teamlead/SKILL.md" && ok "  and it applies in chat too" || bad "  applies in chat too"
grep -q 'Suggest:' "$CLAUDE_PLUGIN_ROOT/skills/teamlead-brainstorm/SKILL.md" && ok "  brainstorm asks the same way" || bad "  brainstorm asks the same way"

echo "== the two stage-4 sections are absent until stage 4 =="
# $1 = stage, $2 = the section block that sits between Decisions and Open questions.
mkord(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n%b## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" "$2" > "$T/o.md"
  "$PL" "$T/o.md" >"$T/oout" 2>&1; echo $?; }
FULL='## Done when\n- [x] ok — *verified by: agent*\n\n## Implementation plan\n*Built from D1 · decisions:QQ*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n'
check "a stage-3 plan with five sections is complete" "$(mkord 3 '')" 0
check "stage 4 without them fails" "$(mkord 4 '')" 1
grep -q 'no implementation plan' "$T/oout" && ok "  asks for the wave table" || bad "  asks for the wave table"
grep -q "no criteria under 'Done when'" "$T/oout" && ok "  asks for the criteria" || bad "  asks for the criteria"
# The inboxes stay last: anything after 'Notes from me' pushes the user's half of
# the file out of reach, which is the whole reason the order changed.
check "the wave table below the inboxes is out of order" \
  "$(printf '# T\n\n> **Stage 4** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n## Implementation plan\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n' > "$T/o.md"; "$PL" "$T/o.md" >"$T/oout" 2>&1; echo $?)" 1
grep -q 'out of order' "$T/oout" && ok "  and says so" || bad "  and says so"
check "a misspelled heading is caught" "$(printf '# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open Questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' > "$T/o.md"; "$PL" "$T/o.md" >"$T/oout" 2>&1; echo $?)" 1
grep -q 'unexpected section' "$T/oout" && ok "  named as unexpected" || bad "  named as unexpected"
grep -q 'missing section' "$T/oout" && ok "  and as missing" || bad "  and as missing"
grep -q 'do not exist until stage 4' "$PS2" && ok "  the skill says when they appear" || bad "  skill says when"

echo "== the plan stays finished through stages 5-7 =="
# Keying the finished-plan checks on "== 4" would let every one of them slide the
# moment the header ticked over to building.
mkst(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:SS*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n%b\n\n### Answered\n\n## Notes from me\n%b\n\n' "$1" "$2" "$3" | cat -s > "$T/st.md"
  sh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/st.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:SS/decisions:$sh/" "$T/st.md"; "$PL" "$T/st.md" >"$T/stout" 2>&1; echo $?; }
for n in 4 5 6 7; do
  check "stage $n is clean when the plan is finished" "$(mkst $n '*(none)*' '')" 0
  check "stage $n still rejects a leftover note" "$(mkst $n '*(none)*' 'remember billing')" 1
  grep -q "stage $n reached" "$T/stout" && ok "  names stage $n, not 4" || bad "  names stage $n, not 4"
done
check "stage 3 is still allowed to hold things" "$(mkst 3 '1. open?\n   *Suggest:* x — *y.*' 'a note')" 0
grep -q '6 Agent-Testing' "$PS2" && ok "  the skill has stage 6" || bad "  skill has stage 6"
grep -q '7 User-Testing' "$PS2" && ok "  the skill has stage 7" || bad "  skill has stage 7"
grep -q 'Leave `.claude/teamlead/.state/active-plan` set' "$PS2" && ok "  handoff no longer clears the pointer" || bad "  handoff clears the pointer"
grep -q 'Never tick a `user` box' "$PS2" && ok "  stage 7 belongs to the user" || bad "  stage 7 belongs to the user"

# The shipped docs are the reference a lead copies from. The example drifted out of
# spec once already (stage 4 with a full 'Notes from me') because nothing checked it.
echo "== shipped docs satisfy their own linter =="
"$PL" "$CLAUDE_PLUGIN_ROOT/docs/example-plan.md" >/dev/null 2>&1 \
  && ok "example-plan.md passes plan-lint" || bad "example-plan.md passes plan-lint"
# The file ends with exactly one empty line, so the user can type below the last section.
TRAIL='# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n'
check "plan ending with one empty line: ok" "$(printf "$TRAIL\n" > "$T/tr.md"; "$PL" "$T/tr.md" >/dev/null 2>&1; echo $?)" 0
check "plan with no trailing empty line: fails" "$(printf "$TRAIL" > "$T/tr.md"; "$PL" "$T/tr.md" >"$T/trout" 2>&1; echo $?)" 1
grep -q 'exactly one empty line' "$T/trout" && ok "  says how to fix it" || bad "  says how to fix it"
check "plan with two trailing empty lines: fails" "$(printf "$TRAIL\n\n" > "$T/tr.md"; "$PL" "$T/tr.md" >/dev/null 2>&1; echo $?)" 1
# The skill's template is what every new plan starts as, so its section order must
# match the linter's. Extract it and compare headings directly — derived from
# plan-lint.sh's own canon= line so the two cannot silently drift apart again.
cline=$(grep -m1 '^canon=' "$PL")
ccontent="${cline#canon=\$\'}"; ccontent="${ccontent%\'}"
canon_expected=$(printf '%b' "$ccontent")
ccount=$(grep -c '^' <<<"$canon_expected")
tpl=$(awk '/^## Goal$/{p=1} p&&/^## /{print}' "$PS2" | head -n "$ccount" | sed 's/^## //')
check "template section order matches the linter" "$tpl" "$canon_expected"

# ==============================================================================
# Phase-A mechanisms (plan-mode-improvements): D16 Go record, D16/D23 plan-fence,
# board-fence's stage gate, gate.sh's plan-mode checks, board.py check_plan (D22),
# state.sh/restore.sh (D14), and the skill text that documents them.
# ==============================================================================

echo "== mode.sh: a 'Go' is recorded against the plan's current stage (D16) =="
gop=$T/gorec; mkdir -p $gop/.claude/teamlead/plan $gop/.claude/teamlead/.state
: > $gop/.claude/teamlead/.state/active
gopf=$gop/.claude/teamlead/plan/topic.md
printf '# T\n\n> **Stage 3** — x\n' > $gopf
echo "$gopf" > $gop/.claude/teamlead/.state/active-plan
gosay(){ echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$gop'","prompt":"'"$1"'"}' | "$H/mode.sh" >/dev/null; }
rm -f $gop/.claude/teamlead/.state/plan-go
gosay "Go"
check "'Go' appends one line to plan-go" "$(wc -l < $gop/.claude/teamlead/.state/plan-go)" 1
grep -qE '^3 [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' $gop/.claude/teamlead/.state/plan-go \
  && ok "  as '<stage> <ISO-8601 UTC>'" || bad "  line format"
gosay " go "; gosay "GO"
check "' go ' and 'GO' also count (trim + case-insensitive)" "$(wc -l < $gop/.claude/teamlead/.state/plan-go)" 3
gosay "go ahead"
check "'go ahead' does not count" "$(wc -l < $gop/.claude/teamlead/.state/plan-go)" 3
rm -f $gop/.claude/teamlead/.state/active-plan $gop/.claude/teamlead/.state/plan-go
gosay "Go"
[ -f $gop/.claude/teamlead/.state/plan-go ] && bad "no active-plan: nothing written" || ok "no active-plan: nothing written"

echo "== plan-fence.sh: guards the plan's own stage header and its 'Notes from me' (D16, D23) =="
pfp=$T/pfence; mkdir -p $pfp/.claude/teamlead/plan $pfp/.claude/teamlead/.state
: > $pfp/.claude/teamlead/.state/active
pff=$pfp/.claude/teamlead/plan/topic.md
pfedit(){ echo '{"hook_event_name":"PreToolUse","cwd":"'$pfp'","tool_name":"Edit","tool_input":{"file_path":"'$pff'","old_string":"'"$1"'","new_string":"'"$2"'"}}' | "$H/plan-fence.sh"; }
pfdecide(){ [ -z "$1" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$1"; }

printf '# T\n\n> **Stage 3** — x\n\n## Notes from me\nkeep this\n' > $pff
echo "$pff" > $pfp/.claude/teamlead/.state/active-plan
rm -f $pfp/.claude/teamlead/.state/plan-go $pfp/.claude/teamlead/.state/plan-stage
out=$(pfedit '**Stage 3**' '**Stage 4**')
check "3->4 with no Go recorded: denied" "$(pfdecide "$out")" deny
grep -q 'none recorded since the last stage change' <<<"$out" && ok "  names the missing Go" || bad "  names the missing Go"

printf '3 2026-01-01T00:00:00Z\n' > $pfp/.claude/teamlead/.state/plan-go
out=$(pfedit '**Stage 3**' '**Stage 4**')
check "3->4 with a Go recorded since: allowed" "$(pfdecide "$out")" allow
check "  plan-stage now starts with '4 '" "$(cut -d' ' -f1 $pfp/.claude/teamlead/.state/plan-stage)" 4

# plan-fence never writes the file itself — only the real Edit/Write tool does —
# so the on-disk header has to be moved to Stage 4 by hand before testing 4->5.
printf '# T\n\n> **Stage 4** — x\n\n## Notes from me\n' > $pff
out=$(pfedit '**Stage 4**' '**Stage 5**')
check "4->5 on that same old Go: denied (plan-stage moved since)" "$(pfdecide "$out")" deny

printf '5 2099-01-01T00:00:00Z\n' >> $pfp/.claude/teamlead/.state/plan-go
out=$(pfedit '**Stage 4**' '**Stage 5**')
check "4->5 with a fresh Go: allowed" "$(pfdecide "$out")" allow

printf '# T\n\n> **Stage 3** — x\n\n## Notes from me\n' > $pff
rm -f $pfp/.claude/teamlead/.state/plan-stage
out=$(pfedit '**Stage 3**' '**Stage 5**')
check "3->5 in one edit: denied" "$(pfdecide "$out")" deny
grep -q 'one stage at a time' <<<"$out" && ok "  names the reason" || bad "  names the reason"

printf '# T\n\n> **Stage 5** — x\n\n## Notes from me\n' > $pff
out=$(pfedit '**Stage 5**' '**Stage 4**')
check "5->4 (backwards): allowed" "$(pfdecide "$out")" allow

printf '# T\n\n> **Stage 3** — x\n\n## Notes from me\nold line\n' > $pff
out=$(pfedit 'old line' 'old line\nnew line')
check "adding a line under '## Notes from me': denied" "$(pfdecide "$out")" deny
grep -q "the user's section" <<<"$out" && ok "  names it as the user's section" || bad "  names it as the user's section"

printf '# T\n\n> **Stage 3** — x\n\n## Notes from me\nold line\nsecond line\n' > $pff
out=$(pfedit 'old line\nsecond line' 'old line')
check "removing a line under '## Notes from me': allowed" "$(pfdecide "$out")" allow

printf '# T\n\n> **Stage 3** — x\n\n## Notes from me\nold line\n' > $pff
out=$(pfedit 'old line\n' 'old line\n\n')
check "adding the trailing empty line under '## Notes from me': allowed" "$(pfdecide "$out")" allow

pfother=$pfp/other.md; printf 'x\n' > $pfother
out=$(echo '{"hook_event_name":"PreToolUse","cwd":"'$pfp'","tool_name":"Edit","tool_input":{"file_path":"'$pfother'","old_string":"x","new_string":"y"}}' | "$H/plan-fence.sh")
check "Edit to a different file: no output" "$out" ""

pffresh=$pfp/.claude/teamlead/plan/fresh.md; rm -f "$pffresh"
echo "$pffresh" > $pfp/.claude/teamlead/.state/active-plan
rm -f $pfp/.claude/teamlead/.state/plan-stage
out=$(echo '{"hook_event_name":"PreToolUse","cwd":"'$pfp'","tool_name":"Write","tool_input":{"file_path":"'$pffresh'","content":"# T\n\n> **Stage 1** — x\n"}}' | "$H/plan-fence.sh")
check "Write to a plan path that doesn't exist yet: allowed" "$out" ""
grep -q '^1 ' $pfp/.claude/teamlead/.state/plan-stage && ok "  and seeds plan-stage" || bad "  and seeds plan-stage"

echo "$pff" > $pfp/.claude/teamlead/.state/active-plan
printf '# T\n\n> **Stage 3** — x\n\n## Notes from me\n' > $pff
out=$(pfedit 'not present anywhere' 'whatever')
check "old_string not in the file: allow silently (parse failure = allow)" "$out" ""

# T66: a same-stage write must not re-stamp plan-stage — that made a Go typed
# before it look older than "the last stage change" and refused the 3->4 bump.
pfst=$pfp/.claude/teamlead/.state
printf '# T\n\n> **Stage 3** — x\n\nbody one\n\n## Notes from me\n' > $pff
printf '3 2020-01-01T00:00:00Z\n' > $pfst/plan-stage
printf '3 2020-01-02T00:00:00Z\n' > $pfst/plan-go
out=$(pfedit 'body one' 'body two')
check "T66: same-stage Edit after a Go: allowed" "$(pfdecide "$out")" allow
printf '# T\n\n> **Stage 3** — x\n\nbody two\n\n## Notes from me\n' > $pff
out=$(echo '{"hook_event_name":"PreToolUse","cwd":"'$pfp'","tool_name":"Write","tool_input":{"file_path":"'$pff'","content":"# T\n\n> **Stage 3** — x\n\nbody three\n\n## Notes from me\n"}}' | "$H/plan-fence.sh")
check "T66: same-stage Write after a Go: allowed" "$(pfdecide "$out")" allow
check "T66: plan-stage untouched by same-stage writes" "$(cat $pfst/plan-stage)" "3 2020-01-01T00:00:00Z"
out=$(pfedit '**Stage 3**' '**Stage 4**')
check "T66: 3->4 after same-stage writes, Go still live: allowed" "$(pfdecide "$out")" allow
check "T66: the real bump does re-stamp plan-stage" "$(cut -d' ' -f1 $pfst/plan-stage)" 4
printf '3 2020-01-03T00:00:00Z\n' > $pfst/plan-stage
out=$(pfedit '**Stage 3**' '**Stage 4**')
check "T66: Go older than the real stage change: 3->4 still denied" "$(pfdecide "$out")" deny
printf '3 2020-01-02T00:00:00Z\n' > $pfst/plan-stage
out=$(pfedit '**Stage 3**' '**Stage 4**')
check "T66: Go in the same second as the stamp: denied (strict >)" "$(pfdecide "$out")" deny
rm -f $pfst/plan-stage $pfst/plan-go

m=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Edit|Write|MultiEdit|NotebookEdit") | .hooks[].command' "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json")
grep -q 'plan-fence.sh' <<<"$m" && ok "  hooks.json wires plan-fence.sh under Edit|Write|MultiEdit|NotebookEdit" || bad "  hooks.json wires plan-fence.sh"

echo "== board-fence.sh: board_add is also gated by the plan's stage =="
bfp=$T/bfence; mkdir -p $bfp/.claude/teamlead/plan $bfp/.claude/teamlead/.state
bff=$bfp/.claude/teamlead/plan/topic.md
echo "$bff" > $bfp/.claude/teamlead/.state/active-plan
RB=mcp__plugin_teamlead_teamlead-board
bfdecide(){ out=$(echo "$1" | "$H/board-fence.sh"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }

printf '# T\n\n> **Stage 3** — x\n' > $bff
bfadd(){ bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_add","tool_input":{"tasks":'"$1"'}}'; }
check "board_add of a plan: row at stage 3: denied" \
  "$(bfadd '[{"task":"build","plan":"I1"}]')" deny
check "board_add of an owns: row without plan: at stage 3: allowed" \
  "$(bfadd '[{"task":"set up docs","owns":["superdoc/"]}]')" allow
check "board_add of a read-only row at stage 3: allowed" \
  "$(bfadd '[{"task":"scout the repo","agent":"tl-sonnet-low"}]')" allow
check "board_add of a mixed batch with one plan: row at stage 3: denied" \
  "$(bfadd '[{"task":"scout"},{"task":"build","plan":"I1"}]')" deny
check "board_add of a batch of non-plan rows (read-only + owns:) at stage 3: allowed" \
  "$(bfadd '[{"task":"scout"},{"task":"set up docs","owns":["superdoc/"]}]')" allow

printf '# T\n\n> **Stage 5** — x\n' > $bff
check "board_add once the plan reaches stage 5: allowed" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_add","tool_input":{}}')" allow

printf '# T\n\n> **Stage 3** — x\n' > $bff
check "board_update at stage 3: allowed (closing pre-existing work stays open)" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_update","tool_input":{}}')" allow

printf '# T\n\n> **Stage 5** — x\n' > $bff
check "a worker's board_add at stage 5: still refused (worker, not stage)" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_add","tool_input":{},"agent_id":"w1"}')" deny

echo "== second Go: the fresh-context offer is enforced (issue #18) =="
og=$T/offer; mkdir -p $og/.claude/teamlead/plan $og/.claude/teamlead/.state
: > $og/.claude/teamlead/.state/active
ogf=$og/.claude/teamlead/plan/topic.md; ogs=$og/.claude/teamlead/.state
printf '# T\n\n> **Stage 4** — x\n' > $ogf
echo "$ogf" > $ogs/active-plan
printf '%s\n' '{"next_id":3,"tasks":[{"id":1,"task":"build","state":"queued","plan":"I1","owns":[],"blocked_by":[]},{"id":2,"task":"scout","state":"queued","plan":null,"owns":[],"blocked_by":[]}]}' > $ogs/board.json
ogsay(){ jq -n --arg p "$1" --arg c "$og" '{hook_event_name:"UserPromptSubmit",cwd:$c,prompt:$p}' | "$H/mode.sh" >/dev/null; }
ogout(){ jq -n --arg c "$og" --arg b "$1" '{hook_event_name:"PreToolUse",cwd:$c,tool_name:"Agent",tool_input:{subagent_type:"teamlead:tl-sonnet-high",description:"w",prompt:("do it\n"+$b+"\nmore")}}' | "$H/record.sh"; }
ogdisp(){ out=$(ogout "$1"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }
ogadd(){ bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$og'","tool_name":"'$RB'__board_add","tool_input":{"tasks":'"$1"'}}'; }
ogmark(){ [ -f $ogs/plan-offer-pending ] && echo set || echo none; }
ogsay "Go"
check "a Go at stage 4 sets plan-offer-pending" "$(ogmark)" set
check "pending: dispatch for a plan: row refused" "$(ogdisp 'board: 1')" deny
r=$(ogout 'board: 1' | jq -r .hookSpecificOutput.permissionDecisionReason)
grep -qF 'To build this on a fresh context: `/clear`, then `/teamlead plan continue`.' <<<"$r" && grep -qF 'Or say "here" to continue in this session.' <<<"$r" && grep -q STOP <<<"$r" \
  && ok "  refusal carries the byte-exact offer and says to stop" || bad "  refusal text"
check "  and a refused dispatch is not recorded in the ledger" "$(cat $ogs/events.log 2>/dev/null | grep -c dispatch)" 0
check "pending: dispatch for a non-plan row unaffected" "$(ogdisp 'board: 2')" allow
check "pending: dispatch with no board marker (scout) unaffected" "$(ogdisp 'no row')" allow
check "pending: board_add of a plan: row denied" "$(ogadd '[{"task":"b","plan":"I2"}]')" deny
check "pending: board_add without plan: allowed" "$(ogadd '[{"task":"scout"}]')" allow
ogsay "I said here earlier, and here is a quote"
ogsay "here we go"
check "prompts merely containing 'here' leave the mark" "$(ogmark)" set
check "  so the dispatch is still refused" "$(ogdisp 'board: 1')" deny
printf '# T\n\n> **Stage 5** — x\n' > $ogf
ogsay " Here "
check "'here' (trim, case-insensitive) clears the mark" "$(ogmark)" none
check "  and the plan: dispatch is allowed" "$(ogdisp 'board: 1')" allow
check "  and board_add of a plan: row is allowed" "$(ogadd '[{"task":"b","plan":"I2"}]')" allow
printf '# T\n\n> **Stage 4** — x\n' > $ogf
ogsay "Go"
check "a Go at stage 4 re-arms the mark" "$(ogmark)" set
ogsay "/teamlead plan continue"
check "'/teamlead plan continue' clears the mark" "$(ogmark)" none
check "  and the plan: dispatch is allowed" "$(ogdisp 'board: 1')" allow
printf '# T\n\n> **Stage 3** — x\n' > $ogf
ogsay "Go"
check "a Go at stage 3 does not set the mark" "$(ogmark)" none
: > $ogs/plan-offer-pending; rm -f $ogs/active-plan
check "no active plan: a stale mark never refuses a dispatch" "$(ogdisp 'board: 1')" allow

echo "== gate.sh: plan-mode checks — footer, plan-lint, stage 5->6, returned (D1, D9) =="
gtp=$T/gtgate; mkdir -p $gtp/.claude/teamlead/plan $gtp/.claude/teamlead/.state
: > $gtp/.claude/teamlead/.state/active
gtf=$gtp/.claude/teamlead/plan/topic.md
echo "$gtf" > $gtp/.claude/teamlead/.state/active-plan
git -C $gtp init -q; git -C $gtp config user.email t@t.t; git -C $gtp config user.name t
echo a > $gtp/a.txt; git -C $gtp add -A >/dev/null; git -C $gtp commit -qm init >/dev/null
gtmktx(){ printf '{"type":"user","message":{"content":"hi"}}\n' > "$1"
  python3 -c 'import json,sys;print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$2" >> "$1"; }
gtev(){ echo "$1" | "$H/gate.sh" >"$T/gtout" 2>&1; echo $?; }

printf '# T\n\n> **Stage 3** — x\n' > $gtf
gttx1=$gtp/tx1.jsonl; gtmktx "$gttx1" $'body\n\nType "Go" if you want me to plan the implementation.'
check "stage 3, footer present: exit 0" \
  "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false,"transcript_path":"'$gttx1'"}')" 0

gttx2=$gtp/tx2.jsonl; gtmktx "$gttx2" $'body\n\nType "Go" if you want me to start implementing.'
check "stage 3, last line is the stage-4 footer instead: exit 2" \
  "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false,"transcript_path":"'$gttx2'"}')" 2
grep -q 'Type "Go" if you want me to plan the implementation.' "$T/gtout" && ok "  names the stage-3 footer it wanted" || bad "  names the wanted footer"

printf '# T\n\n> **Stage 4** — x\n\n## Goal\nTBD\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' > $gtf
check "stage 4, a plan that fails plan-lint: exit 2" "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false}')" 2
grep -q 'TBD' "$T/gtout" && ok "  surfaces the TBD finding" || bad "  surfaces the TBD finding"
grep -q "no criteria under 'Done when'" "$T/gtout" && ok "  and the missing Done-when" || bad "  and the missing Done-when"

printf '# T\n\n> **Stage 5** — x\n' > $gtf
python3 "$B" add --project $gtp --task "w" --agent tl-sonnet-low --owns src/x >/dev/null
python3 "$B" update --project $gtp --id 1 --state merged >/dev/null
check "stage 5, the only board task is merged: exit 2" "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false}')" 2
grep -q 'Stage 6' "$T/gtout" && ok "  tells it to set the header to Stage 6" || bad "  names Stage 6"

python3 "$B" add --project $gtp --task "w2" --agent tl-sonnet-low --owns src/y >/dev/null
python3 "$B" update --project $gtp --id 2 --state returned >/dev/null
check "a task sitting in 'returned': exit 2" "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false}')" 2
grep -q 'returned' "$T/gtout" && ok "  names it" || bad "  names it"
# #9 class: "waiting on the user" is a correct state of a returned row, and the only way
# to acknowledge it is `blocked` + a note. The message has to say so, or the lead can only
# answer it "deliberately skipping" every turn.
grep "task(s) are in 'returned'" "$T/gtout" | grep -q "'blocked'" && ok "  and says a row waiting on the user goes to 'blocked'" || bad "  and says a row waiting on the user goes to 'blocked' (got: $(grep returned "$T/gtout"))"
grep "task(s) are in 'returned'" "$T/gtout" | grep -q "'blocked' with a note" && ok "  with a note saying what it waits for" || bad "  with a note saying what it waits for"
python3 "$B" update --project $gtp --id 2 --state blocked --notes "waiting on the user: keep or drop?" >/dev/null
grep -q "'returned'" <<<"$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false}' >/dev/null; cat "$T/gtout")" && bad "  and a blocked row is not flagged by check 7" || ok "  and a blocked row is not flagged by check 7"
python3 "$B" update --project $gtp --id 2 --state returned >/dev/null

python3 "$B" update --project $gtp --id 2 --state merged >/dev/null
printf '# T\n\n> **Stage 3** — x\n' > $gtf
check "no transcript_path: footer check skipped, exit 0" "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false}')" 0

echo "== gate.sh check 6: 'every board row merged' is not 'the plan is done' (#6) =="
# The board holds one wave/phase at a time, so all-merged between waves is normal
# while later I<n> steps have no row yet. Check 6 may fire only once every step of
# the current scope (the current phase, or the whole table without phases) is
# boarded AND merged.
g6=$T/g6gate; mkdir -p $g6/.claude/teamlead/plan $g6/.claude/teamlead/.state
: > $g6/.claude/teamlead/.state/active
g6f=$g6/.claude/teamlead/plan/topic.md
echo "$g6f" > $g6/.claude/teamlead/.state/active-plan
git -C $g6 init -q; git -C $g6 config user.email t@t.t; git -C $g6 config user.name t
echo a > $g6/a.txt; git -C $g6 add -A >/dev/null; git -C $g6 commit -qm init >/dev/null
g6run(){ echo '{"hook_event_name":"Stop","cwd":"'$g6'","stop_hook_active":false}' | "$H/gate.sh" >"$T/g6out" 2>&1; echo $?; }
g6s6(){ g6run >/dev/null; grep -q 'set the header to Stage 6' "$T/g6out" && echo fires || echo quiet; }
g6add(){ python3 "$B" add --project $g6 --task "t$1" --agent tl-sonnet-low --owns src/$1 --plan $1 >/dev/null; }
g6set(){ python3 "$B" update --project $g6 --id "$1" --state "$2" >/dev/null; }
g6reset(){ rm -f $g6/.claude/teamlead/.state/board.json $g6/.claude/teamlead/.state/phase-accepted $g6/.claude/teamlead/.state/plan-stage; }
G6HEAD='# T\n\n> **Stage 5** — x\n\n## Implementation plan\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n'
# unphased: I1..I4
printf "$G6HEAD"'| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n| 1 | I2 | b — **D1** | `tl-sonnet-low` | src/I2 | — |\n| 2 | I3 | c — **D1** | `tl-sonnet-low` | src/I3 | I1 |\n| 3 | I4 | d — **D1** | `tl-sonnet-low` | src/I4 | I3 |\n' > $g6f
g6reset; g6add I1; g6add I2; g6set 1 merged; g6set 2 merged
# (board.py check_plan may still nudge to board the next wave of an unphased table —
# that is its own message; what must not fire is the Stage 6 one.)
check "#6 repro: I1+I2 merged, I3+I4 not boarded: no Stage 6 demand" "$(g6s6)" quiet
check "  still quiet on the next turn" "$(g6s6)" quiet
g6add I3; g6set 3 merged
check "I1-I3 merged, I4 still unboarded: no Stage 6 demand" "$(g6s6)" quiet
g6add I4
check "I4 boarded but queued: exit 0" "$(g6run)" 0
g6set 4 merged
check "every step boarded and merged: exit 2" "$(g6run)" 2
check "  now demands Stage 6" "$(g6s6)" fires
# merged rows with no plan link (scouts) prove nothing about the plan's steps
g6reset; python3 "$B" add --project $g6 --task "scout" --agent tl-sonnet-low --owns src/s >/dev/null; g6set 1 merged
check "only a merged non-plan row, steps unboarded: no Stage 6 demand" "$(g6s6)" quiet
# an unboarded step is never 'merged', even when a wave-mate is
g6reset; g6add I1; g6set 1 merged
check "I1 merged, same-wave I2 unboarded: no Stage 6 demand" "$(g6s6)" quiet
# a header-only plan (no I<n> steps at all) keeps the old behaviour
printf '# T\n\n> **Stage 5** — x\n' > $g6f
g6reset; python3 "$B" add --project $g6 --task "w" --agent tl-sonnet-low --owns src/x >/dev/null; g6set 1 merged
check "plan without any I<n> step, board all merged: still exit 2" "$(g6run)" 2
g6reset
check "plan without any I<n> step, empty board: exit 0" "$(g6run)" 0
# phased: A = I1,I2   B = I3
printf "$G6HEAD"'| — | **A** | **First** | | | |\n| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n| 1 | I2 | b — **D1** | `tl-sonnet-low` | src/I2 | — |\n| — | **B** | **Second** | | | |\n| 2 | I3 | c — **D1** | `tl-sonnet-low` | src/I3 | — |\n' > $g6f
g6reset; g6add I1; g6set 1 merged
check "phased: phase A half boarded: no Stage 6 demand" "$(g6s6)" quiet
g6add I2; g6set 2 merged
check "phased: phase A fully merged, B not boarded: exit 2 (A is the current phase)" "$(g6run)" 2
grep -q 'Stage 6' "$T/g6out" && ok "  demands Stage 6 for the finished phase" || bad "  demands Stage 6"
# A passes 6 and 7, the header returns to 5 for B: A's merged rows may still sit on the board
sed -i 's/Stage 5/Stage 6/' $g6f; g6run >/dev/null
sed -i 's/Stage 6/Stage 7/' $g6f; g6run >/dev/null
sed -i 's/Stage 7/Stage 5/' $g6f
# (the Stage 6 gate stays quiet. check_plan now asks for B's steps by phase name, so the gate does
# exit 2 here with that nudge: it used to say nothing, which was the "first phase on the board" flaw)
check "phased: back at stage 5 after A was accepted, B unboarded: no Stage 6 demand" "$(g6s6)" quiet
check "  but check_plan asks to board phase B" "$(grep -c 'phase B: plan step I3 has no board task' "$T/g6out")" 1
g6add I3
check "phased: B boarded, not merged: exit 0" "$(g6run)" 0
g6set 3 merged
check "phased: B fully merged: exit 2" "$(g6run)" 2
# a step of an accepted phase that is reopened (stage 6/7 failure) is current again
g6set 1 queued
check "phased: accepted step reopened: exit 0 while it is open" "$(g6run)" 0
g6set 1 merged
check "phased: accepted step re-merged, B merged: exit 2" "$(g6run)" 2
g6reset
# #8: the message must name its scope, so "Stage 6" is not read as "the whole plan is done"
g6add I1; g6add I2; g6set 1 merged; g6set 2 merged
g6run >/dev/null
grep -q 'phase A of 2' "$T/g6out" && ok "#8 phased: message names 'phase A of 2'" || bad "#8 phased: message names 'phase A of 2'"
grep -qi 'phase B comes after Stage 7' "$T/g6out" && ok "  and says phase B comes after Stage 7" || bad "  says phase B comes after Stage 7"
grep -q 'verifying phase A of 2' "$T/g6out" && ok "  and gives the header body to write" || bad "  gives the header body to write"
sed -i 's/Stage 5/Stage 6/' $g6f; g6run >/dev/null
sed -i 's/Stage 6/Stage 7/' $g6f; g6run >/dev/null
sed -i 's/Stage 7/Stage 5/' $g6f
g6add I3; g6set 3 merged
g6run >/dev/null
grep -q 'phase B of 2' "$T/g6out" && ok "#8 last phase: message names 'phase B of 2'" || bad "#8 last phase: names 'phase B of 2'"
grep -qi 'last phase' "$T/g6out" && ok "  and calls it the last phase" || bad "  calls it the last phase"
grep -qi 'plan is complete' "$T/g6out" && ok "  and says the plan is complete after Stage 7" || bad "  says the plan is complete after Stage 7"
g6reset
printf "$G6HEAD"'| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n' > $g6f
g6add I1; g6set 1 merged
g6run >/dev/null
grep -qi 'whole plan' "$T/g6out" && ok "#8 unphased: message says it covers the whole plan" || bad "#8 unphased: says whole plan"
grep -qi 'plan is complete' "$T/g6out" && ok "  and that Stage 7 completes it" || bad "  Stage 7 completes it"
g6reset

echo "== board.py check_plan: the wave table's CURRENT phase must be on the board (D22) =="
cpp=$T/cplan; mkdir -p $cpp/.claude/teamlead/plan $cpp/.claude/teamlead/.state
git -C $cpp init -q; git -C $cpp config user.email t@t.t; git -C $cpp config user.name t
echo a > $cpp/a.txt; git -C $cpp add -A >/dev/null; git -C $cpp commit -qm init >/dev/null
cpf=$cpp/.claude/teamlead/plan/topic.md
echo "$cpf" > $cpp/.claude/teamlead/.state/active-plan
printf '# T\n\n> **Stage 5** — x\n\n## Implementation plan\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| — | **A** | **First** | | | |\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n| 2 | I2 | do2 — **D1** | `tl-sonnet-low` | src/b | — |\n| — | **B** | **Second** | | | |\n| 3 | I3 | do3 — **D1** | `tl-sonnet-low` | src/c | — |\n' > $cpf
cpchk(){ python3 "$B" check --project $cpp >"$T/cpout" 2>&1; echo $?; }
check "empty board: check fails" "$(cpchk)" 1
grep -q 'plan step I1 has no board task' "$T/cpout" && ok "  names I1" || bad "  names I1"
grep -q 'I2 has no board task' "$T/cpout" && ok "  and I2" || bad "  and I2"
grep -q 'I3' "$T/cpout" && bad "  should not name I3 (a later phase)" || ok "  does not name I3 (a later phase)"
python3 "$B" add --project $cpp --task "do" --agent tl-sonnet-low --owns src/a --plan I1 >/dev/null
check "with I1 on the board: only I2 remains" "$(cpchk)" 1
grep -q 'I1 has no board task' "$T/cpout" && bad "  I1 still named" || ok "  I1 no longer named"
grep -q 'I2 has no board task' "$T/cpout" && ok "  I2 still named" || bad "  I2 still named"
python3 "$B" add --project $cpp --task "do2" --agent tl-sonnet-low --owns src/b --plan I2 >/dev/null
check "with I1 and I2 both on the board: clean" "$(cpchk)" 0
sed -i 's/Stage 5/Stage 3/' $cpf
check "header below stage 5: clean regardless of the board" "$(cpchk)" 0
sed -i 's/Stage 3/Stage 5/' $cpf
rm -f $cpp/.claude/teamlead/.state/board.json
python3 "$B" add --project $cpp --task "do" --agent tl-sonnet-low --owns src/a --plan I1 >/dev/null
python3 "$B" status --project $cpp > "$T/cpstatus" 2>&1
grep -q 'I2 has no board task' "$T/cpstatus" && ok "  'status' prints the same problem text" || bad "  status prints the problem"

echo "== board.py check_plan: the CURRENT phase follows merge + acceptance, not 'first phase on the board' =="
# Same class as #6 (inferring plan progress from the board alone): phase A merged AND accepted, its rows
# still on the board, B not boarded (or only partly). Fixture: A = I1,I2   B = I3,I4
cpq=$T/cplanq; mkdir -p $cpq/.claude/teamlead/plan $cpq/.claude/teamlead/.state
git -C $cpq init -q; git -C $cpq config user.email t@t.t; git -C $cpq config user.name t
echo a > $cpq/a.txt; git -C $cpq add -A >/dev/null; git -C $cpq commit -qm init >/dev/null
cqf=$cpq/.claude/teamlead/plan/topic.md
echo "$cqf" > $cpq/.claude/teamlead/.state/active-plan
printf '# T\n\n> **Stage 5** — x\n\n## Implementation plan\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| — | **A** | **First** | | | |\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n| 2 | I2 | do2 — **D1** | `tl-sonnet-low` | src/b | — |\n| — | **B** | **Second** | | | |\n| 3 | I3 | do3 — **D1** | `tl-sonnet-low` | src/c | — |\n| 4 | I4 | do4 — **D1** | `tl-sonnet-low` | src/d | — |\n' > $cqf
cqchk(){ python3 "$B" check --project $cpq >"$T/cqout" 2>&1; echo $?; }
cqadd(){ python3 "$B" add --project $cpq --task "t$1" --agent tl-sonnet-low --owns src/$1 --plan $1 >/dev/null; }
cqid(){ python3 -c "import json;print([t['id'] for t in json.load(open('$cpq/.claude/teamlead/.state/board.json'))['tasks'] if t['plan']=='$1'][0])"; }
cqset(){ python3 "$B" update --project $cpq --id "$(cqid $1)" --state "$2" >/dev/null; }
cqadd I1; cqadd I2; cqset I1 merged; cqset I2 merged
check "A merged, not yet accepted, B unboarded: still phase A (all boarded), clean" "$(cqchk)" 0
echo "I1 I2" > $cpq/.claude/teamlead/.state/phase-accepted
check "A merged and accepted, B unboarded: check fails" "$(cqchk)" 1
grep -q 'phase B: plan step I3 has no board task' "$T/cqout" && ok "  names phase B and I3" || bad "  names phase B and I3"
grep -q 'phase B: plan step I4 has no board task' "$T/cqout" && ok "  and I4, each line carrying the phase" || bad "  and I4, each line carrying the phase"
grep -q 'I1\|I2' "$T/cqout" && bad "  should not name A's steps" || ok "  does not name A's steps"
cqadd I3
check "B partly boarded (I3 only): check still fails" "$(cqchk)" 1
grep -q 'phase B: plan step I4 has no board task' "$T/cqout" && ok "  names the missing B step I4" || bad "  names the missing B step I4"
grep -q 'I3 has no board task' "$T/cqout" && bad "  I3 is boarded, not named" || ok "  I3 not named"
cqadd I4
check "B fully boarded: clean" "$(cqchk)" 0
# stage 6/7 is about the phase UNDER TEST: never ask for the next phase's steps then
rm -f $cpq/.claude/teamlead/.state/board.json; cqadd I1; cqadd I2; cqset I1 merged; cqset I2 merged
sed -i 's/Stage 5/Stage 6/' $cqf
check "stage 6, A accepted, B unboarded: A is under test, nothing to board yet" "$(cqchk)" 0
sed -i 's/Stage 6/Stage 7/' $cqf
check "stage 7, same: still clean" "$(cqchk)" 0
sed -i 's/Stage 7/Stage 5/' $cqf
# a reopened accepted step makes its phase current again (and it is on the board, so clean)
cqset I2 queued
check "accepted step reopened, B unboarded: phase A is current again, all boarded: clean" "$(cqchk)" 0
rm -f $cpq/.claude/teamlead/.state/board.json $cpq/.claude/teamlead/.state/phase-accepted
check "phased, nothing boarded, nothing accepted: asks for phase A" "$(cqchk)" 1
grep -q 'phase A: plan step I1 has no board task' "$T/cqout" && ok "  'phase A: plan step I1 …'" || bad "  'phase A: plan step I1 …'"

echo "== board.py check_plan: an unphased wave table groups by WAVE, never fully-merged (D22 follow-up) =="
wcp=$T/wcplan; mkdir -p $wcp/.claude/teamlead/plan $wcp/.claude/teamlead/.state
git -C $wcp init -q; git -C $wcp config user.email t@t.t; git -C $wcp config user.name t
echo a > $wcp/a.txt; git -C $wcp add -A >/dev/null; git -C $wcp commit -qm init >/dev/null
wcf=$wcp/.claude/teamlead/plan/topic.md
echo "$wcf" > $wcp/.claude/teamlead/.state/active-plan
printf '# T\n\n> **Stage 5** — x\n\n## Implementation plan\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n| 1 | I2 | do2 — **D1** | `tl-sonnet-low` | src/b | — |\n| 2 | I3 | do3 — **D1** | `tl-sonnet-low` | src/c | I1 |\n| 3 | I4 | do4 — **D1** | `tl-sonnet-low` | src/d | I3 |\n' > $wcf
wcchk(){ python3 "$B" check --project $wcp >"$T/wcout" 2>&1; echo $?; }
python3 "$B" add --project $wcp --task "do" --agent tl-sonnet-low --owns src/a --plan I1 >/dev/null
check "only I1 boarded: check fails" "$(wcchk)" 1
grep -q 'I2 has no board task' "$T/wcout" && ok "  names I2 (same wave)" || bad "  names I2"
grep -q 'I3' "$T/wcout" && bad "  should not name I3 (a later wave)" || ok "  does not name I3 (a later wave)"
grep -q 'I4' "$T/wcout" && bad "  should not name I4 (a later wave)" || ok "  does not name I4 (a later wave)"
python3 "$B" add --project $wcp --task "do2" --agent tl-sonnet-low --owns src/b --plan I2 >/dev/null
check "wave 1 fully boarded (not yet merged): clean — this was the 57-step nag bug" "$(wcchk)" 0
i1id=$(python3 -c "import json;print([t['id'] for t in json.load(open('$wcp/.claude/teamlead/.state/board.json'))['tasks'] if t['plan']=='I1'][0])")
i2id=$(python3 -c "import json;print([t['id'] for t in json.load(open('$wcp/.claude/teamlead/.state/board.json'))['tasks'] if t['plan']=='I2'][0])")
python3 "$B" update --project $wcp --id $i1id --state merged >/dev/null
python3 "$B" update --project $wcp --id $i2id --state merged >/dev/null
check "wave 1 fully merged, wave 2 untouched: falls back to the lowest un-boarded wave" "$(wcchk)" 1
grep -q 'I1' "$T/wcout" && bad "  should not name I1 (merged)" || ok "  does not name I1 (merged)"
grep -q 'I2' "$T/wcout" && bad "  should not name I2 (merged)" || ok "  does not name I2 (merged)"
grep -q 'I3 has no board task' "$T/wcout" && ok "  names I3 (next wave)" || bad "  names I3 (next wave)"
grep -qi 'phase' "$T/wcout" && bad "  unphased message carries no phase prefix" || ok "  unphased message carries no phase prefix"
grep -q 'I4' "$T/wcout" && bad "  should not name I4 (a later wave)" || ok "  does not name I4 (a later wave)"
python3 "$B" add --project $wcp --task "do3" --agent tl-sonnet-low --owns src/c --plan I3 >/dev/null
check "wave 1 merged, wave 2 (I3) boarded and not merged: clean" "$(wcchk)" 0

echo "== state.sh: stage/go/watcher status block (D14) =="
stp=$T/state1; mkdir -p $stp/.claude/teamlead/plan $stp/.claude/teamlead/.state
git -C $stp init -q; git -C $stp config user.email t@t.t; git -C $stp config user.name t
echo a > $stp/a.txt; git -C $stp add -A >/dev/null; git -C $stp commit -qm init >/dev/null
stf=$stp/.claude/teamlead/plan/topic.md
echo "$stf" > $stp/.claude/teamlead/.state/active-plan

printf '# T\n\n> **Stage 3** — x\n' > $stf
stout=$("$H/state.sh" "$stp")
grep -q 'stage: 3 — working it out' <<<"$stout" && ok "names the stage and its label" || bad "names the stage and its label"
grep -q 'go: none recorded' <<<"$stout" && ok "  no Go recorded" || bad "  no Go recorded"
grep -q 'watcher: NOT running — restart it:' <<<"$stout" && ok "  says the watcher is not running" || bad "  watcher not running"
grep -q 'watch-plan.sh' <<<"$stout" && ok "    and names watch-plan.sh" || bad "    names watch-plan.sh"
grep -q "Active plan: $stf" <<<"$stout" && ok "  (F15) prints the literal 'Active plan:' line" || bad "  (F15) prints the literal 'Active plan:' line"

printf '3 2026-01-01T00:00:00Z\n' > $stp/.claude/teamlead/.state/plan-go
stout=$("$H/state.sh" "$stp")
grep -q 'go: recorded at' <<<"$stout" && ok "a recorded Go is shown" || bad "a recorded Go is shown"
grep -q 'already said Go' <<<"$stout" && ok "  and folded into the next: line" || bad "  folded into next:"

printf '# T\n\n> **Stage 5** — x\n' > $stf
stout=$("$H/state.sh" "$stp")
grep -q 'watcher: off (stages 5-6)' <<<"$stout" && ok "stage 5: watcher reported off" || bad "watcher off"
printf '# T\n\n> **Stage 6** — x\n' > $stf
grep -q 'watcher: off (stages 5-6)' <<<"$("$H/state.sh" "$stp")" && ok "stage 6: watcher reported off" || bad "stage 6 watcher off"
printf '# T\n\n> **Stage 7** — x\n' > $stf
stout=$("$H/state.sh" "$stp")
grep -q 'watcher: NOT running — restart it:' <<<"$stout" && ok "stage 7: missing watcher is flagged (user ticks need it)" || bad "stage 7 watcher flagged"
grep -q '^  next:' <<<"$stout" && ok "  and still has a next: line" || bad "  next: line"

echo "== state.sh / skill / help: the phase cycle names its scope (#8) =="
# phased plan A = I1,I2   B = I3 (same fixture shape as the #6 gate block)
printf "$G6HEAD"'| — | **A** | **First** | | | |\n| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n| 1 | I2 | b — **D1** | `tl-sonnet-low` | src/I2 | — |\n| — | **B** | **Second** | | | |\n| 2 | I3 | c — **D1** | `tl-sonnet-low` | src/I3 | — |\n' > $g6f
g6reset; g6add I1; g6add I2; g6set 1 merged; g6set 2 merged
st8(){ "$H/state.sh" "$g6" | grep '^  next:'; }
st8phase(){ "$H/state.sh" "$g6" | grep '^  phase:'; }
grep -q 'phase A of 2' <<<"$(st8)" && ok "stage 5: next: names phase A of 2" || bad "stage 5: next: names phase A of 2"
grep -q 'phase A of 2' <<<"$(st8phase)" && ok "  and a phase: line says so" || bad "  phase: line"
sed -i 's/Stage 5/Stage 6/' $g6f; g6run >/dev/null
grep -q 'verify phase A of 2' <<<"$(st8)" && ok "stage 6: next: says verify phase A of 2" || bad "stage 6: next: says verify phase A of 2"
sed -i 's/Stage 6/Stage 7/' $g6f; g6run >/dev/null
grep -q 'back to Stage 5 for phase B' <<<"$(st8)" && ok "stage 7 (phase A accepted, B next): next: says back to Stage 5 for phase B" || bad "stage 7: next: says back to Stage 5 for phase B"
grep -q 'phase A of 2' <<<"$(st8phase)" && ok "  and the phase: line still says phase A (the one under test)" || bad "  phase: line at stage 7 is still phase A"
grep -qi 'no "Go"' <<<"$(st8)" && ok "  and that 7 -> 5 needs no Go" || bad "  7 -> 5 needs no Go"
sed -i 's/Stage 7/Stage 5/' $g6f; g6add I3; g6set 3 merged
sed -i 's/Stage 5/Stage 7/' $g6f; g6run >/dev/null
grep -q 'plan complete' <<<"$(st8)" && ok "stage 7 on the last phase: next: says plan complete" || bad "stage 7 last phase: plan complete"
grep -q 'phase B of 2' <<<"$(st8phase)" && ok "  and the phase: line says phase B of 2" || bad "  phase: line says phase B of 2"
printf "$G6HEAD"'| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n' > $g6f
g6reset; g6add I1; g6set 1 merged
grep -qi 'whole plan' <<<"$(st8)" && ok "unphased stage 5: next: says whole plan" || bad "unphased stage 5: whole plan"
grep -q '^  phase:' <<<"$("$H/state.sh" "$g6")" && bad "unphased: no phase: line expected" || ok "  unphased prints no phase: line"
g6reset
LOOPTXT="back to Stage 5 for phase N+1"
HELPBLK=$(awk '/^## Help text/,/^## Project setup/' "$SK")
grep -q "$LOOPTXT" <<<"$HELPBLK" && ok "help text states the phase loop" || bad "help text states the phase loop"
grep -q "$LOOPTXT" "$PS2" && ok "plan skill states the phase loop" || bad "plan skill states the phase loop"
grep -q 'Stage 7 → Stage 5' "$PS2" && ok "  and says 7 -> 5 is a legal move" || bad "  says 7 -> 5 is a legal move"
grep -q "against the plan's phase structure" "$PS2" && ok "plan skill: a gate that seems wrong is re-read against the phases first" || bad "plan skill: re-read gate against phases"
grep -q "against the plan's phase structure" "$SK" && ok "lead skill carries the same rule" || bad "lead skill carries the same rule"

echo "== restore.sh: flags a plan left mid-flight after /clear =="
: > $stp/.claude/teamlead/.state/active
printf '# T\n\n> **Stage 6** — x\n' > $stf
rsout=$(echo '{"hook_event_name":"SessionStart","source":"clear","cwd":"'$stp'"}' | "$H/restore.sh")
grep -q 'Session was cleared mid-plan' <<<"$rsout" && ok "stage 6: flags the clear" || bad "stage 6: flags the clear"
printf '# T\n\n> **Stage 3** — x\n' > $stf
rsout=$(echo '{"hook_event_name":"SessionStart","source":"clear","cwd":"'$stp'"}' | "$H/restore.sh")
grep -q 'Session was cleared mid-plan' <<<"$rsout" && bad "stage 3: should not flag the clear" || ok "stage 3: does not flag the clear"

echo "== restore.sh: the lead line carries the plugin.json version =="
want_ver=$(jq -r .version "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json")
rsout_ver=$(echo '{"hook_event_name":"SessionStart","source":"startup","cwd":"'$stp'"}' | "$H/restore.sh")
grep -qF "[teamlead v$want_ver] Active for this project." <<<"$rsout_ver" && ok "lead line starts with [teamlead v$want_ver]" || bad "lead line starts with [teamlead v$want_ver]"
verroot="$T/noverroot"; mkdir -p "$verroot"
rsout_nover=$(echo '{"hook_event_name":"SessionStart","source":"startup","cwd":"'$stp'"}' | CLAUDE_PLUGIN_ROOT="$verroot" "$H/restore.sh" 2>/dev/null)
grep -qF "[teamlead] Active for this project." <<<"$rsout_nover" && ok "  unreadable plugin.json falls back to plain [teamlead]" || bad "  unreadable plugin.json falls back to plain [teamlead]"

echo "== restore.sh: resume and compact also print the lead line and the state block (F23) =="
rsout_resume=$(echo '{"hook_event_name":"SessionStart","source":"resume","session_id":"RS1","cwd":"'$stp'"}' | "$H/restore.sh")
grep -q 'You are the lead' <<<"$rsout_resume" && ok "resume: prints the lead line" || bad "resume: prints the lead line"
grep -q 'stage: 3' <<<"$rsout_resume" && ok "  and the state block" || bad "  and the state block"
rsout_compact=$(echo '{"hook_event_name":"SessionStart","source":"compact","session_id":"RS1","cwd":"'$stp'"}' | "$H/restore.sh")
grep -q 'You are the lead' <<<"$rsout_compact" && ok "compact: prints the lead line" || bad "compact: prints the lead line"
grep -q 'stage: 3' <<<"$rsout_compact" && ok "  and the state block" || bad "  and the state block"
# compact must never forget, even when a stale foreign-session worker is eligible.
stpL=$stp/.claude/teamlead/.state/events.log; rm -f "$stpL"
echo '{"hook_event_name":"SubagentStart","cwd":"'$stp'","agent_type":"tl-sonnet-high","agent_id":"foreign1","session_id":"OTHER"}' \
  | "$H/record.sh" >/dev/null
tenago_stp=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
sed -i "s/^[^ ]*\(.*id=foreign1.*\)\$/$tenago_stp\1/" "$stpL"
echo '{"hook_event_name":"SessionStart","source":"compact","session_id":"RS1","cwd":"'$stp'"}' | "$H/restore.sh" >/dev/null
stp_out=$(python3 "$B" ledger --project $stp | python3 -c 'import json,sys;print(json.load(sys.stdin)["outstanding"])')
check "compact: a stale foreign-session worker is still outstanding, not forgotten" "$stp_out" "['foreign1']"
rm -f "$stpL"

echo "== restore.sh: a plan's '## Handoff' is pointed at after clear/compact/resume =="
hop=$T/handoff1; mkdir -p $hop/.claude/teamlead/plan $hop/.claude/teamlead/.state
git -C $hop init -q; git -C $hop config user.email t@t.t; git -C $hop config user.name t
echo a > $hop/a.txt; git -C $hop add -A >/dev/null; git -C $hop commit -qm init >/dev/null
hof=$hop/.claude/teamlead/plan/topic.md
echo "$hof" > $hop/.claude/teamlead/.state/active-plan
: > $hop/.claude/teamlead/.state/active
printf '# T\n\n> **Stage 5** — phase B done, next: phase C\n\n## Goal\nG\n\n## Handoff\nnext: phase C\n\n## Open questions\n\n## Notes from me\n\n' > $hof
for hsrc in clear compact resume; do
  hout=$(echo '{"hook_event_name":"SessionStart","source":"'$hsrc'","session_id":"H1","cwd":"'$hop'"}' | "$H/restore.sh")
  grep -q "Plan $hof" <<<"$hout" && grep -q '## Handoff' <<<"$hout" && ok "$hsrc: names the plan path and its Handoff" || bad "$hsrc: names the plan path and its Handoff"
done
grep -q 'phase B done, next: phase C' <<<"$hout" && ok "  and quotes the header's stage line" || bad "  and quotes the header's stage line"
hout=$(echo '{"hook_event_name":"SessionStart","source":"startup","session_id":"H1","cwd":"'$hop'"}' | "$H/restore.sh")
grep -q '## Handoff' <<<"$hout" && bad "startup: should not mention Handoff" || ok "startup: no Handoff line"
printf '# T\n\n> **Stage 5** — building\n\n## Goal\nG\n\n## Open questions\n\n## Notes from me\n\n' > $hof
hout=$(echo '{"hook_event_name":"SessionStart","source":"clear","session_id":"H1","cwd":"'$hop'"}' | "$H/restore.sh")
grep -q 'Handoff' <<<"$hout" && bad "plan without a Handoff: no Handoff line expected" || ok "plan without a Handoff: no Handoff line"
rm -f $hop/.claude/teamlead/.state/active-plan
hout=$(echo '{"hook_event_name":"SessionStart","source":"clear","session_id":"H1","cwd":"'$hop'"}' | "$H/restore.sh"); hrc=$?
grep -qE 'Handoff|Plan /' <<<"$hout" && bad "no active plan: no plan line expected" || ok "no active plan: no plan line"
check "  and restore.sh exits 0" "$hrc" 0

echo "== skill text documents clearing between phases =="
grep -q '^## Clearing context between phases' "$PS2" && ok "teamlead-plan/SKILL.md has the section" || bad "section missing"

echo "== skill text reflects the phase-A changes =="
grep -q 'stop teamlead' "$SK" && bad "teamlead/SKILL.md still says 'stop teamlead'" || ok "teamlead/SKILL.md no longer says 'stop teamlead'"
grep -q 'normal mode' "$SK" && bad "teamlead/SKILL.md still mentions 'normal mode'" || ok "teamlead/SKILL.md no longer mentions 'normal mode'"
grep -q 'Stage 7' "$SK" && ok "  and it documents Stage 7" || bad "  documents Stage 7"
grep -q 'plan continue' "$PS2" && ok "teamlead-plan/SKILL.md documents 'plan continue'" || bad "documents plan continue"
grep -q 'plan-go' "$PS2" && ok "  and plan-go" || bad "  and plan-go"
grep -q 'Edit/Write' "$PS2" && ok "  and the Edit/Write requirement" || bad "  and Edit/Write"
grep -qF 'To build this on a fresh context: `/clear`, then `/teamlead plan continue`.' "$PS2" \
  && ok "  the byte-exact handoff line" || bad "  byte-exact handoff line"

# ==============================================================================
# Phase-B mechanisms: plan-lint's Owns-overlap/placeholder/blank-line/tick-evidence/
# Brainstorm-request/phase-row rules (I9), watch-plan.sh's single inotifywait (I10),
# statusline.sh's case-insensitive stage header (I11), plan-archive.sh --abandon
# closing out the ledger (I12), and the skill text documenting all of it (I13).
# ==============================================================================

echo "== plan-lint (I9): Owns prefix overlap in the same wave (D21) =="
# $1 = the two (or more) table rows, real newlines via %b. Wraps them in a full,
# otherwise-valid stage-4 plan so only the overlap check is under test.
mkrows(){ printf '# T\n\n> **Stage 4** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n%b\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" > "$T/rows.md"
  rh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/rows.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$rh/" "$T/rows.md"; "$PL" "$T/rows.md" >"$T/rowsout" 2>&1; echo $?; }
check "a directory prefix overlapping a file under it, same wave: fails" \
  "$(mkrows '| 1 | I1 | do — **D1** | `tl-sonnet-low` | hooks/ | — |\n| 1 | I2 | do2 — **D1** | `tl-sonnet-low` | hooks/gate.sh | — |')" 1
grep -q 'Owns overlaps in the same wave' "$T/rowsout" && ok "  names the overlap" || bad "  names the overlap"
grep -q 'I1 and I2' "$T/rowsout" && ok "  names both ids" || bad "  names both ids"
check "backticked, comma-separated Owns cells overlap too" \
  "$(mkrows '| 1 | I1 | do — **D1** | `tl-sonnet-low` | `hooks/a.sh`, `hooks/b.sh` | — |\n| 1 | I2 | do2 — **D1** | `tl-sonnet-low` | `hooks/b.sh` | — |')" 1
check "the same overlap across different waves is fine" \
  "$(mkrows '| 1 | I1 | do — **D1** | `tl-sonnet-low` | hooks/ | — |\n| 2 | I2 | do2 — **D1** | `tl-sonnet-low` | hooks/gate.sh | I1 |')" 0
check "an exact duplicate Owns path in the same wave still fails" \
  "$(mkrows '| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a.py | — |\n| 1 | I2 | do2 — **D1** | `tl-sonnet-low` | src/a.py | — |')" 1

echo "== plan-lint (I9): placeholder marker (TBD) is scoped to '## Goal' =="
mktbd(){ printf '# T\n\n> **Stage 5** — x\n\n## Goal\n%s\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n%s\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" "$2" > "$T/tbd.md"
  th=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/tbd.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$th/" "$T/tbd.md"; "$PL" "$T/tbd.md" >"$T/tbdout" 2>&1; echo $?; }
check "TBD inside '## Goal' at stage 5 fails" \
  "$(mktbd 'TBD: decide later' '| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |')" 1
grep -q 'placeholder marker (TBD)' "$T/tbdout" && ok "  names it" || bad "  names it"
check "TBD only in a wave-table row does not trip it" \
  "$(mktbd 'G' '| 1 | I1 | fix the TBD bug — **D1** | `tl-sonnet-low` | src/a | — |')" 0

echo "== plan-lint (I9): two-or-more blank lines (D17) =="
mkblank(){ printf '%b' "$1" > "$T/bl.md"; "$PL" "$T/bl.md" >"$T/blout" 2>&1; echo $?; }
BLANKBAD='# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n'
BLANKGOOD='# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n'
check "two consecutive blank lines fail" "$(mkblank "$BLANKBAD")" 1
grep -qE 'two or more consecutive blank lines \(first at line [0-9]+\)' "$T/blout" && ok "  names the line" || bad "  names the line"
check "a single blank line is fine" "$(mkblank "$BLANKGOOD")" 0

echo "== plan-lint (I9): D10 tick evidence at stage >= 6 =="
mkevid(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n%b\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" "$2" > "$T/ev.md"
  eh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/ev.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$eh/" "$T/ev.md"; "$PL" "$T/ev.md" >"$T/evout" 2>&1; echo $?; }
check "stage 6, ticked agent item with no 'ran \`...\`': fails" "$(mkevid 6 '- [x] ok — *verified by: agent*')" 1
grep -q 'ticked agent item has no evidence' "$T/evout" && ok "  names it" || bad "  names it"
check "stage 6, with 'ran \`...\`' evidence: ok" "$(mkevid 6 '- [x] ok — *verified by: agent* — ran `x` → ok')" 0
check "stage 5, no evidence: ok (rule only applies from stage 6)" "$(mkevid 5 '- [x] ok — *verified by: agent*')" 0
check "stage 6, ticked *verified by: user*, no evidence needed: ok" "$(mkevid 6 '- [x] ok — *verified by: user*')" 0

echo "== plan-lint (I9): 'Brainstorm request' must be run or cleared by stage 5 (D12) =="
# $2 = the section's own content, including its own trailing blank line when
# non-empty (empty string when it should read as cleared).
mkbrn(){ if [ "${3:-}" = after ]; then
    printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n## Brainstorm request\n%b' "$1" "$2" > "$T/brn.md"
  else
    printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Brainstorm request\n%b## Notes from me\n\n' "$1" "$2" > "$T/brn.md"
  fi
  bh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/brn.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$bh/" "$T/brn.md"
  "$PL" "$T/brn.md" >"$T/brnout" 2>&1; echo $?; }
check "cleared (empty) Brainstorm request at stage 5: ok" "$(mkbrn 5 '')" 0
check "non-empty Brainstorm request at stage 5: fails" "$(mkbrn 5 'y — run it\n\n')" 1
grep -q "non-empty 'Brainstorm request'" "$T/brnout" && ok "  names it" || bad "  names it"
check "non-empty Brainstorm request at stage 3: ok (still available while planning)" "$(mkbrn 3 'y — run it\n\n')" 0
check "Brainstorm request placed after 'Notes from me': out of order" "$(mkbrn 5 '' after)" 1
grep -q 'out of order' "$T/brnout" && ok "  says so" || bad "  says so"

echo "== plan-lint: a '## Handoff' section between Implementation plan and Open questions is accepted =="
mkbrn 5 '' >/dev/null
sed -i 's/^## Open questions$/## Handoff\nphase A done (abc123). Next: phase B, wave 3.\n\n## Open questions/' "$T/brn.md"
check "plan with a Handoff at stage 5: lint passes" "$("$PL" "$T/brn.md" >"$T/hlout" 2>&1; echo $?)" 0
sed -i '/^## Handoff$/,/^$/d' "$T/brn.md"; sed -i 's/^## Notes from me$/## Handoff\nx\n\n## Notes from me/' "$T/brn.md"
check "Handoff after the inboxes: out of order" "$("$PL" "$T/brn.md" >"$T/hlout" 2>&1; echo $?)" 1

echo "== plan-lint: 'Research request' must be run or cleared by stage 5 =="
# Same shape as mkbrn above: $2 = the section's content, $3 = 'after' puts it below
# 'Notes from me'.
mkrsn(){ if [ "${3:-}" = after ]; then
    printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n## Research request\n%b' "$1" "$2" > "$T/rsn.md"
  else
    printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Research request\n%b## Brainstorm request\n\n## Notes from me\n\n' "$1" "$2" > "$T/rsn.md"
  fi
  rh=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/rsn.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$rh/" "$T/rsn.md"
  "$PL" "$T/rsn.md" >"$T/rsnout" 2>&1; echo $?; }
check "cleared (empty) Research request at stage 5: ok" "$(mkrsn 5 '')" 0
check "non-empty Research request at stage 5: fails" "$(mkrsn 5 'y — run it\n\n')" 1
grep -q "non-empty 'Research request'" "$T/rsnout" && ok "  names it" || bad "  names it"
check "non-empty Research request at stage 3: ok (still available while planning)" "$(mkrsn 3 'y — run it\n\n')" 0
check "Research request placed after 'Notes from me': out of order" "$(mkrsn 5 '' after)" 1
grep -q 'out of order' "$T/rsnout" && ok "  says so" || bad "  says so"

echo "== plan-lint (I9): a phase row is display-only, not a real step =="
mkphase(){ printf '# T\n\n> **Stage 5** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n%b\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" > "$T/ph.md"
  ph=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/ph.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$ph/" "$T/ph.md"; "$PL" "$T/ph.md" >"$T/phout" 2>&1; echo $?; }
check "a phase row alongside real rows: lints clean" \
  "$(mkphase '| — | **A** | **Phase one** | | | |\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |')" 0
check "a phase row alone still counts as no implementation plan" \
  "$(mkphase '| — | **A** | **Phase one** | | | |')" 1
grep -q 'no implementation plan' "$T/phout" && ok "  the check still sees past the phase row" || bad "  the check still sees past the phase row"

echo "== watch-plan.sh (I10): single inotifywait, no persistent-mode text =="
grep -q 'persistent: true' "$H/watch-plan.sh" && bad "watch-plan.sh still says 'persistent: true'" || ok "watch-plan.sh no longer says 'persistent: true'"
grep -q 'inotifywait' "$H/watch-plan.sh" && ok "  drives inotifywait" || bad "  drives inotifywait"
if command -v inotifywait >/dev/null 2>&1; then
  cat > "$T/i10.sh" <<EOF
set -uo pipefail
wip="$T/wone"; mkdir -p "\$wip/.claude/teamlead/plan"
wipf="\$wip/.claude/teamlead/plan/t.md"; printf 'x\n' > "\$wipf"
trap '
  p=\$(cat "\$wip/.claude/teamlead/.state/plan-watch.pid" 2>/dev/null)
  [ -n "\$p" ] && kill -9 "\$p" 2>/dev/null
  pkill -9 -f "inotifywait.*\$wip" 2>/dev/null
  true
' EXIT
setsid nohup bash "$H/watch-plan.sh" "\$wip" "\$wipf" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null
sleep 1
setsid nohup bash "$H/watch-plan.sh" "\$wip" "\$wipf" >/dev/null 2>&1 </dev/null &
disown 2>/dev/null
sleep 1
wcount=\$(pgrep -f "inotifywait.*\$wip" | wc -l)
wpid=\$(cat "\$wip/.claude/teamlead/.state/plan-watch.pid" 2>/dev/null)
live=0; [ -n "\$wpid" ] && kill -0 "\$wpid" 2>/dev/null && live=1
[ -n "\$wpid" ] && kill -TERM "\$wpid" 2>/dev/null
sleep 1
pidgone=1; [ -f "\$wip/.claude/teamlead/.state/plan-watch.pid" ] && pidgone=0
wcount2=\$(pgrep -f "inotifywait.*\$wip" | wc -l)
printf '%s %s %s %s\n' "\$wcount" "\$live" "\$pidgone" "\$wcount2"
EOF
  read -r wcount live pidgone wcount2 <<<"$(bash "$T/i10.sh")"
  check "exactly one inotifywait after starting twice (D2)" "${wcount:-?}" 1
  check "  plan-watch.pid holds a live pid" "${live:-?}" 1
  check "  TERMed: pid file is gone" "${pidgone:-?}" 1
  check "  TERMed: no inotifywait left" "${wcount2:-?}" 0
else
  echo "skip: inotifywait not installed — cannot test the live watcher"
fi

echo "== statusline.sh: cache + single-flight background refresh =="
cp_=$T/slc; fk=$T/slfake; mkdir -p $cp_/.claude/teamlead/.state $fk/scripts
st=$cp_/.claude/teamlead/.state; cf=$st/statusline.cache
slx() { printf '{"cwd":"%s"}' "$cp_" | env -u TEAMLEAD_STATUSLINE_SYNC bash "$H/statusline.sh"; }
check "inactive: empty output" "$(slx)" ""
sleep 0.3; [ -z "$(ls -A $st)" ] && ok "  and nothing spawned or written" || bad "  inactive project wrote state"
: > $st/active; echo "$fk" > $st/plugin-root
# A fake board.py: counts how many refreshes ran, and is slow enough to overlap.
cat > $fk/scripts/board.py <<'PY'
import sys, time
if sys.argv[1] == "list":
    open(__file__ + ".calls", "a").write("x\n")
    time.sleep(1)
    print('{"open": 3, "by_state": {"returned": ["a"]}}')
else:
    print("{}")
PY
out=$(slx)
[ "$out" = "$(printf '\033[38;5;44m%s\033[0m' '⚑ teamlead')" ] && ok "first run: plain teal flag" || bad "first run: plain flag ($out)"
for i in 1 2 3 4 5 6 7 8; do slx >/dev/null & done; wait
for i in $(seq 1 40); do [ -f $cf ] && break; sleep 0.2; done
[ -f $cf ] && ok "  cache appears shortly after" || bad "  cache never appeared"
check "  concurrent runs started exactly one refresh" "$(wc -l < $fk/scripts/board.py.calls)" 1
[ ! -e $st/statusline.lock ] && ok "  lock released after the refresh" || bad "  lock left behind"
out=$(slx)
grep -q '3 open' <<<"$out" && grep -q '1 returned' <<<"$out" && ok "second run: full cached segment" || bad "second run: cached segment ($out)"
sleep 2.2; rm -f $fk/scripts/board.py.calls
# a stale lock whose holder is dead must not wedge refreshing
echo 999999 > $st/statusline.lock
slx >/dev/null; for i in $(seq 1 40); do [ -s $fk/scripts/board.py.calls ] && break; sleep 0.2; done
[ -s $fk/scripts/board.py.calls ] && ok "  a dead holder's lock is taken over" || bad "  dead holder's lock blocked the refresh"
sleep 1.5

echo "== statusline.sh (I11): stage header parsing is case-insensitive =="
slip=$T/sli; mkdir -p $slip/.claude/teamlead/{plan,.state}
: > $slip/.claude/teamlead/.state/active
slipf=$slip/.claude/teamlead/plan/topic.md
printf '# T\n\n> **stage 6** — x\n' > $slipf
echo "$slipf" > $slip/.claude/teamlead/.state/active-plan
out=$(printf '{"cwd":"%s"}' "$slip" | bash "$H/statusline.sh")
grep -q '🧪 Plan:' <<<"$out" && ok "lowercase 'stage 6' header: 🧪 Plan" || bad "lowercase 'stage 6' header: 🧪 Plan ($out)"
grep -q 'stage 6/7' <<<"$out" && ok "  and 'stage 6/7'" || bad "  and 'stage 6/7'"
printf '# T\n\n> **Stage 2** — x\n' > $slipf
out=$(printf '{"cwd":"%s"}' "$slip" | bash "$H/statusline.sh")
grep -q '📄 Planning:' <<<"$out" && ok "'Stage 2' header: 📄 Planning" || bad "'Stage 2' header: 📄 Planning ($out)"
printf '# T\n\n> **Stage 7** — x\n' > $slipf
out=$(printf '{"cwd":"%s"}' "$slip" | bash "$H/statusline.sh")
grep -q '🙋' <<<"$out" && ok "'Stage 7' header: 🙋" || bad "'Stage 7' header: 🙋 ($out)"
# a plan with phases names the phase in the stage description (same parser as the gate)
printf "$G6HEAD"'| — | **A** | **First** | | | |\n| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n| — | **B** | **Second** | | | |\n| 2 | I2 | b — **D1** | `tl-sonnet-low` | src/I2 | — |\n| — | **C** | **Third** | | | |\n| 3 | I3 | c — **D1** | `tl-sonnet-low` | src/I3 | — |\n' > $slipf
sli(){ printf '{"cwd":"%s"}' "$slip" | bash "$H/statusline.sh"; }
grep -q 'stage 5/7 building phase A of 3' <<<"$(sli)" && ok "phased, stage 5, nothing merged: 'building phase A of 3'" || bad "phased stage 5: building phase A of 3 ($(sli))"
python3 "$B" add --project $slip --task t1 --agent tl-sonnet-low --owns src/I1 --plan I1 >/dev/null
python3 "$B" update --project $slip --id 1 --state merged >/dev/null
echo "I1" > $slip/.claude/teamlead/.state/phase-accepted
grep -q 'stage 5/7 building phase B of 3' <<<"$(sli)" && ok "  A merged and accepted: 'building phase B of 3'" || bad "  building phase B of 3 ($(sli))"
rm -f $slip/.claude/teamlead/.state/phase-accepted; sed -i 's/Stage 5/Stage 6/' $slipf
grep -q 'stage 6/7 verifying phase A of 3' <<<"$(sli)" && ok "  stage 6: 'verifying phase A of 3' (the phase under test)" || bad "  verifying phase A of 3 ($(sli))"
sed -i 's/Stage 6/Stage 7/' $slipf
grep -q 'stage 7/7 your turn to test phase A of 3' <<<"$(sli)" && ok "  stage 7: 'your turn to test phase A of 3'" || bad "  your turn to test phase A of 3 ($(sli))"
printf "$G6HEAD"'| 1 | I1 | a — **D1** | `tl-sonnet-low` | src/I1 | — |\n' > $slipf
grep -q 'stage 5/7 building it' <<<"$(sli)" && ok "  a plan without phase rows keeps 'building it'" || bad "  unphased keeps 'building it' ($(sli))"
rm -f $slip/.claude/teamlead/.state/board.json

echo "== plan-archive.sh --abandon (I12): closes out the ledger =="
abp=$T/aband; mkdir -p $abp/.claude/teamlead/{plan,.state/snap}
git -C $abp init -q; git -C $abp config user.email t@t.t; git -C $abp config user.name t
echo a > $abp/a.txt; git -C $abp add -A >/dev/null; git -C $abp commit -qm init >/dev/null
abf=$abp/.claude/teamlead/plan/topic.md
printf '# T\n\n## Done when\n- [ ] never done — *verified by: user*\n' > $abf
echo "$abf" > $abp/.claude/teamlead/.state/active-plan
NOWA=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  dispatch  agent=tl-sonnet-low  desc=scout\n%s  start     agent=tl-sonnet-low  id=a1\n' "$NOWA" "$NOWA" > $abp/.claude/teamlead/.state/events.log
python3 "$B" status --project $abp > "$T/abstatus1" 2>&1
grep -q '1 worker(s) working' "$T/abstatus1" && ok "before --abandon: one worker outstanding" || bad "before --abandon: one worker outstanding"
bash "$CLAUDE_PLUGIN_ROOT/scripts/plan-archive.sh" $abf --project $abp --abandon >/dev/null 2>&1
python3 "$B" status --project $abp > "$T/abstatus2" 2>&1
grep -q '0 worker(s) working' "$T/abstatus2" && ok "--abandon closes out the ledger" || bad "--abandon closes out the ledger"
ls $abp/.claude/teamlead/plan/done/*abandoned-*.md >/dev/null 2>&1 && ok "  and files the plan as abandoned" || bad "  and files the plan as abandoned"
# Without --abandon, a finished plan archives cleanly and the ledger is untouched.
abp2=$T/aband2; mkdir -p $abp2/.claude/teamlead/{plan,.state/snap}
git -C $abp2 init -q; git -C $abp2 config user.email t@t.t; git -C $abp2 config user.name t
echo a > $abp2/a.txt; git -C $abp2 add -A >/dev/null; git -C $abp2 commit -qm init >/dev/null
abf2=$abp2/.claude/teamlead/plan/topic.md
printf '# T\n\n## Done when\n- [x] it works — *verified by: agent* — ran `x` → ok\n' > $abf2
echo "$abf2" > $abp2/.claude/teamlead/.state/active-plan
printf '%s  dispatch  agent=tl-sonnet-low  desc=scout\n%s  start     agent=tl-sonnet-low  id=a2\n' "$NOWA" "$NOWA" > $abp2/.claude/teamlead/.state/events.log
before2=$(cat $abp2/.claude/teamlead/.state/events.log)
bash "$CLAUDE_PLUGIN_ROOT/scripts/plan-archive.sh" $abf2 --project $abp2 >/dev/null 2>&1
after2=$(cat $abp2/.claude/teamlead/.state/events.log)
check "without --abandon, the ledger is untouched" "$after2" "$before2"

echo "== skill text documents phase-B mechanisms (I13) =="
grep -qF 'Initial brainstorm [y/n]: ' "$PS2" && ok "documents the brainstorm prompt line" || bad "documents the brainstorm prompt line"
grep -q '^## Brainstorm request' "$PS2" && ok "  and the '## Brainstorm request' heading" || bad "  the Brainstorm request heading"
grep -qF 'Initial research [y/n]: ' "$PS2" && ok "documents the research prompt line" || bad "documents the research prompt line"
grep -q '^## Research request' "$PS2" && ok "  and the '## Research request' heading" || bad "  the Research request heading"
grep -q 'inotifywait' "$PS2" && ok "  and 'inotifywait'" || bad "  'inotifywait'"
grep -qF 'ran `' "$PS2" && ok "  and the D10 tick-evidence format" || bad "  the D10 tick-evidence format"
grep -qiE '^## .*phase' "$PS2" && ok "  and a heading about phases" || bad "  a heading about phases"

# ==============================================================================
# core-fixes (I11): fixtures for hook-side machinery landed on master in this
# plan — D1 (session-aware ledger forgetting), D2 (gate.sh's plan-stage check
# 3b), F5 (worktree cwd resolution), F11 (gitignore already-covered), F21
# (mode.sh's first-Go nudge), D5 (restore.sh renders board.md), and I9 docs.
# F9 and F15/F23 fixtures were added inline, next to the sections they extend
# (worker fence, state.sh, restore.sh's clear-mid-plan block).
# ==============================================================================

echo "== D1: restore.sh closes out a previous session's dead workers on startup, never on compact =="
d1p=$T/d1kill; mkdir -p $d1p/.claude/teamlead/.state; : > $d1p/.claude/teamlead/.state/active
d1L=$d1p/.claude/teamlead/.state/events.log; rm -f "$d1L"
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1p'","agent_type":"tl-sonnet-high","agent_id":"old1","session_id":"S0"}' "$H/record.sh" >/dev/null
grep -qE 'start.*id=old1.*session=S0' "$d1L" && ok "old1's start line carries session=S0" || bad "old1's start line carries session=S0"
yesterday=$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)
sed -i "s/^[^ ]*\(.*id=old1.*\)\$/$yesterday\1/" "$d1L"
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1p'","agent_type":"tl-sonnet-high","agent_id":"cur1","session_id":"S1"}' "$H/record.sh" >/dev/null
rsout1=$(echo '{"hook_event_name":"SessionStart","source":"startup","session_id":"S1","cwd":"'$d1p'"}' | "$H/restore.sh")
grep -q 'Closed out 1 worker(s)' <<<"$rsout1" && ok "startup: closes out 1 worker from the dead session" || bad "startup: closes out 1 worker from the dead session"
grep -q 'old1' <<<"$rsout1" && ok "  names old1" || bad "  names old1"
d1ledger(){ python3 "$B" ledger --project $d1p | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin)["outstanding"]))'; }
check "outstanding is now only cur1" "$(d1ledger)" "['cur1']"
grep -qE 'cancel.*id=old1.*reason=restart' "$d1L" && ok "  a cancel/restart line was written" || bad "  a cancel/restart line was written"

# A second stale worker from the dead session, to prove compact leaves it alone.
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1p'","agent_type":"tl-sonnet-high","agent_id":"old2","session_id":"S0"}' "$H/record.sh" >/dev/null
# Before the session boundary but well within the 4h stale-age-out window, so it
# reads as OUTSTANDING (not abandoned) throughout — the point under test is
# session-scoping, not staleness.
tenago=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
sed -i "s/^[^ ]*\(.*id=old2.*\)\$/$tenago\1/" "$d1L"
rsout2=$(echo '{"hook_event_name":"SessionStart","source":"compact","session_id":"S1","cwd":"'$d1p'"}' | "$H/restore.sh")
grep -q 'Closed out' <<<"$rsout2" && bad "compact: forgets nothing (should not have forgotten anything)" || ok "compact: forgets nothing"
check "old2 is still outstanding after compact" "$(d1ledger)" "['cur1', 'old2']"

# A NEW start under the current session survives a real startup-triggered forget.
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1p'","agent_type":"tl-sonnet-high","agent_id":"cur2","session_id":"S1"}' "$H/record.sh" >/dev/null
rsout3=$(echo '{"hook_event_name":"SessionStart","source":"startup","session_id":"S1","cwd":"'$d1p'"}' | "$H/restore.sh")
grep -q 'old2' <<<"$rsout3" && ok "  a later startup finally sweeps old2" || bad "  a later startup finally sweeps old2"
check "cur1 and cur2 (this session) still outstanding" "$(d1ledger)" "['cur1', 'cur2']"

echo "== D1: record.sh with .state/active absent still records an outstanding worker's own SubagentStop (F16) =="
d1bp=$T/d1noactive; mkdir -p $d1bp/.claude/teamlead/.state; : > $d1bp/.claude/teamlead/.state/active
d1bL=$d1bp/.claude/teamlead/.state/events.log
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1bp'","agent_type":"tl-sonnet-high","agent_id":"nw1"}' "$H/record.sh" >/dev/null
rm -f $d1bp/.claude/teamlead/.state/active
check "SubagentStop for an outstanding id, active absent: hook still exits 0" \
  "$(ev '{"hook_event_name":"SubagentStop","cwd":"'$d1bp'","agent_type":"tl-sonnet-high","agent_id":"nw1","last_assistant_message":"done"}' "$H/record.sh")" 0
grep -qE 'return.*id=nw1' "$d1bL" && ok "  the return line was appended despite no active flag" || bad "  the return line was appended despite no active flag"
check "SubagentStop for an unknown id, active absent: hook exits 0" \
  "$(ev '{"hook_event_name":"SubagentStop","cwd":"'$d1bp'","agent_type":"tl-sonnet-high","agent_id":"ghost","last_assistant_message":"done"}' "$H/record.sh")" 0
grep -q 'id=ghost' "$d1bL" && bad "  an unknown id got recorded anyway" || ok "  an unknown id recorded nothing"

echo "== D1: record.sh's id anchoring — id=w1 must not substring-match id=w10 (F16) =="
d1cp=$T/d1anchor; mkdir -p $d1cp/.claude/teamlead/.state; : > $d1cp/.claude/teamlead/.state/active
d1cL=$d1cp/.claude/teamlead/.state/events.log
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1cp'","agent_type":"tl-sonnet-high","agent_id":"w10"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$d1cp'","agent_type":"tl-sonnet-high","agent_id":"w10","last_assistant_message":"done"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStart","cwd":"'$d1cp'","agent_type":"tl-sonnet-high","agent_id":"w1"}' "$H/record.sh" >/dev/null
rm -f $d1cp/.claude/teamlead/.state/active
check "w10 already returned, active absent: SubagentStop for w1 still exits 0" \
  "$(ev '{"hook_event_name":"SubagentStop","cwd":"'$d1cp'","agent_type":"tl-sonnet-high","agent_id":"w1","last_assistant_message":"done"}' "$H/record.sh")" 0
grep -qE '  return .*  id=w1(  |$)' "$d1cL" && ok "  w1's return line was appended (id=w1 not swallowed by w10's id=w10)" || bad "  w1's return line was appended (id=w1 not swallowed by w10's id=w10)"

echo "== D2: gate.sh's plan-stage check (3b) catches a header bump that bypassed plan-fence.sh =="
d2p=$T/d2gate; mkdir -p $d2p/.claude/teamlead/plan $d2p/.claude/teamlead/.state
: > $d2p/.claude/teamlead/.state/active
d2f=$d2p/.claude/teamlead/plan/topic.md
echo "$d2f" > $d2p/.claude/teamlead/.state/active-plan
d2write(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n\n' "$1" > "$d2f"
  h=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$d2f" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$h/" "$d2f"
}
d2ev(){ echo "$1" | "$H/gate.sh" >"$T/d2out" 2>&1; echo $?; }
D2STOP='{"hook_event_name":"Stop","cwd":"'$d2p'","stop_hook_active":false}'

d2write 3
printf '3 %s\n' "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)" > $d2p/.claude/teamlead/.state/plan-stage
rm -f $d2p/.claude/teamlead/.state/plan-go
sed -i 's/Stage 3/Stage 5/' "$d2f"
check "forward jump Stage 3->5 in one edit: exit 2" "$(d2ev "$D2STOP")" 2
grep -qF 'moved Stage 3 → 5' "$T/d2out" && ok "  names the jump" || bad "  names the jump"

sed -i 's/Stage 5/Stage 4/' "$d2f"
check "3->4 with no Go recorded since: exit 2" "$(d2ev "$D2STOP")" 2
grep -qF 'no "Go" is recorded' "$T/d2out" && ok "  says so" || bad "  says so"

printf '3 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> $d2p/.claude/teamlead/.state/plan-go
check "3->4 with a Go recorded since: exit 0" "$(d2ev "$D2STOP")" 0
check "  plan-stage now starts with '4'" "$(cut -d' ' -f1 $d2p/.claude/teamlead/.state/plan-stage)" 4

rm -f $d2p/.claude/teamlead/.state/plan-stage
check "deleting plan-stage: gate passes and re-seeds it" "$(d2ev "$D2STOP")" 0
grep -q '^4 ' $d2p/.claude/teamlead/.state/plan-stage && ok "  re-seeded at the current header stage (4)" || bad "  re-seeded at stage 4"

sed -i 's/Stage 4/Stage 2/' "$d2f"
check "backward move Stage 4->2: accepted" "$(d2ev "$D2STOP")" 0
check "  plan-stage now starts with '2'" "$(cut -d' ' -f1 $d2p/.claude/teamlead/.state/plan-stage)" 2

# T66: a Stop with the header unchanged must not re-stamp plan-stage — otherwise
# any Go typed before that Stop is voided for the next turn's 3->4 bump.
d2write 3
printf '3 2020-01-01T00:00:00Z\n' > $d2p/.claude/teamlead/.state/plan-stage
printf '3 2020-01-02T00:00:00Z\n' > $d2p/.claude/teamlead/.state/plan-go
d2ev "$D2STOP" >/dev/null
check "T66: same-stage Stop leaves plan-stage untouched" "$(cat $d2p/.claude/teamlead/.state/plan-stage)" "3 2020-01-01T00:00:00Z"
sed -i 's/Stage 3/Stage 4/' "$d2f"
d2ev "$D2STOP" >/dev/null
grep -qF 'no "Go" is recorded' "$T/d2out" && bad "T66: 3->4 on the next Stop, Go still live: accepted" || ok "T66: 3->4 on the next Stop, Go still live: accepted"
check "T66:   plan-stage now starts with '4'" "$(cut -d' ' -f1 $d2p/.claude/teamlead/.state/plan-stage)" 4

echo "== gate.sh check 4b: no /clear offer while still asking for the second Go =="
OFFER='To build this on a fresh context: `/clear`, then `/teamlead plan continue`.'
d4msg(){ jq -nc --arg m "$1" '{"hook_event_name":"Stop","cwd":"'$d2p'","stop_hook_active":false,"last_assistant_message":$m}'; }
d2write 4
printf '4 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $d2p/.claude/teamlead/.state/plan-stage
check "stage 4, message offers /teamlead plan continue: exit 2" \
  "$(d2ev "$(d4msg "plan written.

$OFFER
Or say \"here\".

Type \"Go\" if you want me to start implementing.")")" 2
grep -qF 'offers /clear' "$T/d2out" && grep -qF 'only after the user' "$T/d2out" && ok "  says to print it only after the user's Go" || bad "  says to print it only after the user's Go (got: $(cat $T/d2out))"
check "stage 4, footer only: exit 0" "$(d2ev "$(d4msg 'plan written.

Type "Go" if you want me to start implementing.')")" 0
check "stage 4, no last_assistant_message: exit 0" "$(d2ev "$D2STOP")" 0
# Go typed, header bumped to 5 in the reply: the offer is now legitimate.
d2write 5
printf '4 2020-01-01T00:00:00Z\n' > $d2p/.claude/teamlead/.state/plan-stage
printf '4 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> $d2p/.claude/teamlead/.state/plan-go
check "stage 5 with the Go recorded, offer printed: exit 0" "$(d2ev "$(d4msg "$OFFER
Or say \"here\" to continue in this session.")")" 0
d2write 7
printf '7 2020-01-01T00:00:00Z\n' > $d2p/.claude/teamlead/.state/plan-stage
check "stage 7, phase-boundary /clear advice mentioning plan continue: exit 0" \
  "$(d2ev "$(d4msg 'phase done. Optionally /clear, then /teamlead plan continue.')")" 0
grep -qF 'never at the end of' "$PS2" && ok "skill: offer is for the second-Go reply, never stage 4" || bad "skill: offer is for the second-Go reply, never stage 4"
grep -qF 'No Go recorded for the implementation plan yet' "$PS2" && ok "skill: plan continue at stage 4 without a Go says so plainly" || bad "skill: plan continue at stage 4 without a Go says so plainly"

echo "== F5: a hook fired from inside a worktree resolves to the main checkout (I2) =="
f5p=$T/f5proj; mkdir -p $f5p
git -C $f5p init -q 2>/dev/null; git -C $f5p config user.email t@t.t; git -C $f5p config user.name t
echo a > $f5p/a.txt; git -C $f5p add -A >/dev/null; git -C $f5p commit -qm init >/dev/null
# .claude/teamlead is created AFTER the commit and never staged, so the new
# worktree's checkout of HEAD does not carry it along.
mkdir -p $f5p/.claude/teamlead/.state; : > $f5p/.claude/teamlead/.state/active
git -C $f5p worktree add -q "$T/wt5" -b wtb5 2>/dev/null
f5L=$f5p/.claude/teamlead/.state/events.log; rm -f "$f5L"
echo '{"hook_event_name":"SubagentStart","cwd":"'"$T"'/wt5","agent_type":"tl-sonnet-high","agent_id":"wtworker"}' \
  | env -u CLAUDE_PROJECT_DIR "$H/record.sh" >/dev/null 2>&1
grep -qE 'start.*id=wtworker' "$f5L" && ok "the event lands in the MAIN checkout's events.log" || bad "the event lands in the main checkout's events.log"
[ -d "$T/wt5/.claude/teamlead" ] && bad "  a .claude/teamlead was created inside the worktree" || ok "  no .claude/teamlead was created inside the worktree"
git -C $f5p worktree remove --force "$T/wt5" 2>/dev/null

echo "== F11: tl_ensure_gitignore appends nothing when an existing pattern already covers it =="
f11p=$T/f11gi; mkdir -p $f11p/.claude/teamlead/.state; : > $f11p/.claude/teamlead/.state/active
git -C $f11p init -q 2>/dev/null; git -C $f11p config user.email t@t.t; git -C $f11p config user.name t
printf '.claude/\n' > $f11p/.gitignore
cp $f11p/.gitignore "$T/f11gi.before"
echo '{"hook_event_name":"SessionStart","source":"startup","cwd":"'$f11p'"}' | "$H/restore.sh" >/dev/null 2>&1
cmp -s "$T/f11gi.before" "$f11p/.gitignore" && ok "restore.sh leaves an existing '.claude/' pattern's .gitignore untouched" || bad "restore.sh leaves an existing '.claude/' pattern's .gitignore untouched"

echo "== mode.sh: first Go nudges when the plan was never edited by the user (F21) =="
f21p=$T/f21go; mkdir -p $f21p/.claude/teamlead/plan $f21p/.claude/teamlead/.state
: > $f21p/.claude/teamlead/.state/active
f21f=$f21p/.claude/teamlead/plan/topic.md
printf '# T\n\n> **Stage 3** — x\n' > $f21f
echo "$f21f" > $f21p/.claude/teamlead/.state/active-plan
rm -f $f21p/.claude/teamlead/.state/plan-go $f21p/.claude/teamlead/.state/plan-touched
f21say(){ echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$f21p'","prompt":"'"$1"'"}' | "$H/mode.sh"; }
out=$(f21say "Go")
grep -q 'First Go recorded, but the plan file was never edited by you' <<<"$out" && ok "first Go, plan never touched: nudges" || bad "first Go, plan never touched: nudges"
out2=$(f21say "Go")
grep -q 'First Go recorded' <<<"$out2" && bad "second Go: nudges again (should not)" || ok "second Go: no repeat nudge"
rm -f $f21p/.claude/teamlead/.state/plan-go
: > $f21p/.claude/teamlead/.state/plan-touched
out3=$(f21say "Go")
grep -q 'First Go recorded' <<<"$out3" && bad "plan-touched present: still nudges (should not)" || ok "plan-touched present: no nudge on first Go"

echo "== D5: restore.sh renders board.md from board.json, and never creates one where none existed =="
d5p=$T/d5render; mkdir -p $d5p/.claude/teamlead/.state; : > $d5p/.claude/teamlead/.state/active
python3 "$B" add --project $d5p --task "render me" --agent tl-sonnet-low --owns d5/a >/dev/null
rm -f $d5p/.claude/teamlead/board.md
[ -f $d5p/.claude/teamlead/board.md ] && bad "setup: board.md should be gone before restore" || ok "setup: board.md removed before restore"
rsout5=$(echo '{"hook_event_name":"SessionStart","source":"startup","cwd":"'$d5p'"}' | "$H/restore.sh")
[ -f $d5p/.claude/teamlead/board.md ] && ok "restore.sh recreated board.md from board.json" || bad "restore.sh recreated board.md from board.json"
grep -q 'render me' <<<"$rsout5" && ok "  and restore.sh's own output lists the recreated row" || bad "  restore.sh's output lists the recreated row"

d5p2=$T/d5none; mkdir -p $d5p2/.claude/teamlead/.state; : > $d5p2/.claude/teamlead/.state/active
echo '{"hook_event_name":"SessionStart","source":"startup","cwd":"'$d5p2'"}' | "$H/restore.sh" >/dev/null
[ -f $d5p2/.claude/teamlead/board.md ] && bad "a board-less project got an empty board.md created" || ok "a board-less project gets no board.md created"

echo "== I9 docs: CLI table and enforcement.md name the newly landed mechanisms =="
grep -qE 'board\.py remove <id>' "$SK" && ok "skills/teamlead/SKILL.md documents 'board.py remove <id>'" || bad "SKILL.md documents 'board.py remove <id>'"
ENFDOC="$CLAUDE_PLUGIN_ROOT/docs/enforcement.md"
gate_row=$(grep '`gate.sh`' "$ENFDOC")
grep -q 'plan-stage' <<<"$gate_row" && ok "enforcement.md's gate.sh row mentions plan-stage" || bad "enforcement.md's gate.sh row mentions plan-stage"
restore_row=$(grep '`restore.sh`' "$ENFDOC")
grep -q 'forget' <<<"$restore_row" && ok "enforcement.md's restore.sh row mentions forget" || bad "enforcement.md's restore.sh row mentions forget"

echo "== docs/enforcement.md names exactly the files under hooks/ and scripts/ =="
ENF="$CLAUDE_PLUGIN_ROOT/docs/enforcement.md"
documented=$(grep -oE '^\| `[^`]+`' "$ENF" | tr -d '|` ' | sort)
actual=$(find "$H" "$CLAUDE_PLUGIN_ROOT/scripts" -maxdepth 1 -type f -printf '%f\n' | grep -v '^hooks.json$' | sort)
d=$(diff <(printf '%s\n' "$documented") <(printf '%s\n' "$actual"))
[ -z "$d" ] && ok "table matches hooks/ and scripts/ exactly" || bad "table vs tree differ:
$d"
dupes=$(printf '%s\n' "$documented" | uniq -d)
[ -z "$dupes" ] && ok "  no filename listed twice" || bad "  listed more than once: $dupes"

echo "== D8: owns-overlap allowed along a transitive blocked_by chain =="
d8p=$T/d8; mkdir -p $d8p
python3 "$B" add --project $d8p --task "I1" --agent tl-sonnet-high --owns scripts/board.py >/dev/null            # id 1
check "I2 blocked_by I1, no overlap with I1's owns: accepted" \
  "$(python3 "$B" add --project $d8p --task "I2" --agent tl-sonnet-high --owns SKILL.md --blocked-by 1 >/dev/null 2>&1; echo $?)" 0   # id 2
check "I3 owns board.py again, blocked_by I2 (chain reaches I1 through I2): accepted" \
  "$(python3 "$B" add --project $d8p --task "I3" --agent tl-sonnet-high --owns scripts/board.py --blocked-by 2 >/dev/null 2>&1; echo $?)" 0   # id 3
python3 "$B" add --project $d8p --task "X" --agent tl-sonnet-high --owns scripts/board.py >"$T/d8out" 2>&1
rc=$?
check "unrelated overlap with no blocked_by: refused" "$rc" 1
grep -q 'overlapping paths' "$T/d8out" && ok "  names the overlap" || bad "  names the overlap"

echo "== D8: direct chain, same path, accepted =="
d8b=$T/d8direct; mkdir -p $d8b
python3 "$B" add --project $d8b --task "A" --agent tl-sonnet-high --owns chain/x >/dev/null   # id 1
check "B blocked_by A, same owns path: accepted" \
  "$(python3 "$B" add --project $d8b --task "B" --agent tl-sonnet-high --owns chain/x --blocked-by 1 >/dev/null 2>&1; echo $?)" 0

echo "== D8: order of ids must not matter (lower id blocked_by higher id) =="
d8c=$T/d8order; mkdir -p $d8c/.claude/teamlead/.state
cat > $d8c/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 3, "tasks": [
  {"id": 1, "task": "a", "agent": "tl-sonnet-low", "owns": ["ord/x"], "state": "blocked", "branch": null, "plan": null, "blocked_by": [2], "notes": null, "worker": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "b", "agent": "tl-sonnet-low", "owns": ["ord/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "worker": null, "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $d8c >/dev/null 2>&1
check "lower id blocked_by higher id, same path: still linked, check passes" \
  "$(python3 "$B" check --project $d8c >/dev/null 2>&1; echo $?)" 0

echo "== D8: a blocked_by cycle terminates instead of hanging =="
d8d=$T/d8cycle; mkdir -p $d8d/.claude/teamlead/.state
cat > $d8d/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 3, "tasks": [
  {"id": 1, "task": "a", "agent": "tl-sonnet-low", "owns": ["cyc/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [2], "notes": null, "worker": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "b", "agent": "tl-sonnet-low", "owns": ["cyc/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [1], "notes": null, "worker": null, "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $d8d >/dev/null 2>&1
timeout 5 python3 "$B" check --project $d8d >"$T/d8cout" 2>&1
rc=$?
[ "$rc" -ne 124 ] && ok "cycle does not hang (terminated within 5s)" || bad "cycle hangs (timed out)"
check "mutual direct blockers are linked, so the overlap is allowed: check passes" "$rc" 0

echo "== D9: running/merged refused while a blocker is unmerged =="
d9p=$T/d9; mkdir -p $d9p
python3 "$B" add --project $d9p --task "I1" --agent tl-sonnet-high --owns scripts/board.py >/dev/null                         # id 1
python3 "$B" add --project $d9p --task "I2" --agent tl-sonnet-high --owns SKILL.md --blocked-by 1 >/dev/null                 # id 2
python3 "$B" add --project $d9p --task "I3" --agent tl-sonnet-high --owns scripts/board.py --blocked-by 2 >/dev/null          # id 3

python3 "$B" update --project $d9p --id 3 --state running >"$T/d9out1" 2>&1; rc=$?
check "I3 running while I2 (its blocker) is blocked: refused" "$rc" 1
grep -q 'is blocked by 2, which is blocked' "$T/d9out1" && ok "  names the unmerged blocker and its state" || bad "  names the unmerged blocker and its state"

python3 "$B" update --project $d9p --id 3 --state merged >"$T/d9out2" 2>&1; rc=$?
check "I3 merged while I2 is blocked: refused likewise" "$rc" 1
grep -q 'is blocked by 2, which is blocked' "$T/d9out2" && ok "  same message for a merged jump" || bad "  same message for a merged jump"

python3 "$B" update --project $d9p --id 1 --state merged >/dev/null 2>&1; rc=$?
check "I1 merged: ok" "$rc" 0
st2=$(python3 -c "import json;d=json.load(open('$d9p/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==2][0])")
check "I2 auto-unblocked to queued once I1 merged" "$st2" "queued"
python3 "$B" update --project $d9p --id 2 --state running >/dev/null 2>&1; rc=$?
check "I2 running: ok" "$rc" 0

python3 "$B" update --project $d9p --id 3 --state running >"$T/d9out3" 2>&1; rc=$?
check "I3 running while I2 is running (not merged): still refused" "$rc" 1
grep -q 'is blocked by 2, which is running' "$T/d9out3" && ok "  names I2's current state" || bad "  names I2's current state"

python3 "$B" update --project $d9p --id 2 --state merged >/dev/null 2>&1; rc=$?
check "I2 merged: ok" "$rc" 0
python3 "$B" update --project $d9p --id 3 --state running >/dev/null 2>&1; rc=$?
check "I3 running, now that I2 is merged: ok" "$rc" 0

echo "== D9: normal blocked/auto-unblock path is unaffected =="
d9n=$T/d9normal; mkdir -p $d9n
python3 "$B" add --project $d9n --task "A" --agent tl-sonnet-high --owns d9n/a >/dev/null                     # id 1
python3 "$B" add --project $d9n --task "B" --agent tl-sonnet-high --owns d9n/b --blocked-by 1 >/dev/null       # id 2
stb=$(python3 -c "import json;d=json.load(open('$d9n/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==2][0])")
check "B starts blocked (has an unmerged blocker)" "$stb" "blocked"
python3 "$B" update --project $d9n --id 1 --state merged >/dev/null 2>&1; rc=$?
check "A merged: ok" "$rc" 0
stb2=$(python3 -c "import json;d=json.load(open('$d9n/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==2][0])")
check "B auto-unblocked to queued" "$stb2" "queued"
python3 "$B" update --project $d9n --id 2 --state running >/dev/null 2>&1; rc=$?
check "B running: accepted" "$rc" 0

echo "== D6: check_git warns when a returned branch is behind main =="
d6p=$T/d6; mkdir -p $d6p; cd $d6p; git init -q; git config user.email t@t.t; git config user.name t
printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > .gitignore
echo base > a.txt; git add -A >/dev/null; git commit -qm init
mainbr=$(git rev-parse --abbrev-ref HEAD)
python3 "$B" add --project $d6p --task w --agent tl-sonnet-high --owns a.txt >/dev/null                 # id 1
git checkout -q -b feat; echo work > b.txt; git add -A >/dev/null; git commit -qm work; git checkout -q $mainbr
python3 "$B" update --project $d6p --id 1 --state returned --branch feat >/dev/null
python3 "$B" check --project $d6p >/dev/null 2>&1; rc=$?
check "feat contains HEAD: check passes" "$rc" 0
echo more >> a.txt; git commit -qam advance
python3 "$B" check --project $d6p >"$T/d6out" 2>&1; rc=$?
check "master advanced past feat's branch point: check fails" "$rc" 1
grep -q "branch feat is behind $mainbr — rebase before merging" "$T/d6out" && ok "  names the behind-main warning" || bad "  names the behind-main warning"
python3 "$B" update --project $d6p --id 1 --state running >/dev/null
python3 "$B" check --project $d6p >"$T/d6out2" 2>&1
grep -q 'behind' "$T/d6out2" && bad "  running row still warns (should be skipped)" || ok "  running row is skipped, no behind-main warning"
git checkout -q feat; git rebase -q $mainbr; git checkout -q $mainbr
python3 "$B" update --project $d6p --id 1 --state returned >/dev/null
python3 "$B" check --project $d6p >/dev/null 2>&1; rc=$?
check "rebased and returned again: check passes" "$rc" 0
cd $proj

echo "== D7: check_git flags a leftover worktree for a merged row =="
d7p=$T/d7; mkdir -p $d7p; cd $d7p; git init -q; git config user.email t@t.t; git config user.name t
printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > .gitignore
echo base > a.txt; git add -A >/dev/null; git commit -qm init
python3 "$B" add --project $d7p --task w --agent tl-sonnet-high --owns a.txt >/dev/null                 # id 1
git worktree add -q "$T/d7wt" -b wtb >/dev/null 2>&1
echo work > "$T/d7wt/b.txt"; git -C "$T/d7wt" add -A >/dev/null; git -C "$T/d7wt" commit -qm work
git merge -q wtb >/dev/null
python3 "$B" update --project $d7p --id 1 --state merged --branch wtb >/dev/null
python3 "$B" check --project $d7p >"$T/d7out" 2>&1; rc=$?
check "merged but the worktree is still there: check fails" "$rc" 1
grep -q "is merged but worktree $T/d7wt still exists" "$T/d7out" && ok "  names the worktree path" || bad "  names the worktree path"
grep -q 'git worktree remove' "$T/d7out" && ok "  suggests the removal command" || bad "  suggests the removal command"
lines=$(grep -c '^  - ' "$T/d7out")
check "exactly one problem line (real merge, not a squash-mismatch too)" "$lines" 1
git worktree remove "$T/d7wt"
python3 "$B" check --project $d7p >/dev/null 2>&1; rc=$?
check "worktree removed: check passes" "$rc" 0
# A merged row whose branch IS the main checkout's branch (work committed straight
# onto it) must never be told to remove the main checkout — git refuses, so the
# finding would come back every turn. Same for a main branch not named master.
for d7b in master trunk; do
  d7m=$T/d7main-$d7b; mkdir -p $d7m; cd $d7m; git init -q -b $d7b; git config user.email t@t.t; git config user.name t
  printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > .gitignore
  echo base > a.txt; git add -A >/dev/null; git commit -qm init
  python3 "$B" add --project $d7m --task w --agent tl-sonnet-high --owns a.txt >/dev/null               # id 1
  python3 "$B" update --project $d7m --id 1 --state merged --branch $d7b >/dev/null
  python3 "$B" check --project $d7m >"$T/d7mout" 2>&1; rc=$?
  check "merged row on the main branch ($d7b): check passes" "$rc" 0
  grep -q 'git worktree remove' "$T/d7mout" && bad "  never suggests removing the main checkout" || ok "  never suggests removing the main checkout"
done
# a branch checked out in a hand-made linked worktree is still a real leftover
git worktree add -q "$T/d7hand" -b handb >/dev/null 2>&1
python3 "$B" update --project $d7m --id 1 --branch handb >/dev/null
python3 "$B" check --project $d7m >"$T/d7mout" 2>&1
grep -q "is merged but worktree $T/d7hand still exists" "$T/d7mout" && ok "  linked (non-agent) worktree of a merged row is still flagged" || bad "  linked (non-agent) worktree of a merged row is still flagged"
git worktree remove "$T/d7hand"
cd $proj

echo "== D12: worker-start/worker-stop lifecycle =="
wsp=$T/ws; mkdir -p $wsp
python3 "$B" add --project $wsp --task a --agent tl-sonnet-low --owns ws/x >/dev/null                # id 1
python3 "$B" add --project $wsp --task b --agent tl-sonnet-low --owns ws/y --blocked-by 1 >/dev/null # id 2

check "worker-start --board 1 --branch: exit 0" \
  "$(python3 "$B" worker-start --id w1 --board 1 --branch worktree-agent-w1 --project $wsp >/dev/null 2>&1; echo $?)" 0
row1=$(python3 -c "import json;d=json.load(open('$wsp/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==1][0];print(t['state']+','+t['worker']+','+t['branch'])")
check "  row 1 is running/w1/worktree-agent-w1" "$row1" "running,w1,worktree-agent-w1"

python3 "$B" worker-start --id w1 --board 2 --project $wsp >"$T/wsout1" 2>&1; rc=$?
check "worker-start --board 2 while its blocker (1) is unmerged: refused" "$rc" 1
grep -q 'is blocked by' "$T/wsout1" && ok "  names the blocker" || bad "  names the blocker"

python3 "$B" worker-start --id w1 --board 99 --project $wsp >"$T/wsout2" 2>&1; rc=$?
check "worker-start --board 99 (no such row): refused" "$rc" 1
grep -q 'no task with id 99' "$T/wsout2" && ok "  names the missing id" || bad "  names the missing id"

check "worker-stop --id w1: exit 0" \
  "$(python3 "$B" worker-stop --id w1 --project $wsp >/dev/null 2>&1; echo $?)" 0
st1=$(python3 -c "import json;d=json.load(open('$wsp/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==1][0])")
check "  row 1 is returned" "$st1" "returned"

check "worker-stop --id w1 again (no running row for w1): exit 0, no-op" \
  "$(python3 "$B" worker-stop --id w1 --project $wsp >/dev/null 2>&1; echo $?)" 0
st1b=$(python3 -c "import json;d=json.load(open('$wsp/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==1][0])")
check "  row 1 unchanged by the no-op" "$st1b" "returned"

check "worker-start --id w1, no --board (resume path): moves the returned row to running" \
  "$(python3 "$B" worker-start --id w1 --project $wsp >/dev/null 2>&1; echo $?)" 0
st1c=$(python3 -c "import json;d=json.load(open('$wsp/.claude/teamlead/.state/board.json'));print([t['state'] for t in d['tasks'] if t['id']==1][0])")
check "  row 1 is running again" "$st1c" "running"

check "worker-start --id nobody (no row of that worker in 'returned'): exit 0, no-op" \
  "$(python3 "$B" worker-start --id nobody --project $wsp >/dev/null 2>&1; echo $?)" 0

echo "== D12: worker-start/worker-stop are no-ops with no board.json, and never create one =="
nbp=$T/ws-noboard; mkdir -p $nbp
check "worker-start --id w1, no board.json: exit 0" \
  "$(python3 "$B" worker-start --id w1 --project $nbp >/dev/null 2>&1; echo $?)" 0
check "worker-stop --id w1, no board.json: exit 0" \
  "$(python3 "$B" worker-stop --id w1 --project $nbp >/dev/null 2>&1; echo $?)" 0
check "  no board.json created" "$([ -f $nbp/.claude/teamlead/.state/board.json ] && echo yes || echo no)" no
check "  no board.md created" "$([ -f $nbp/.claude/teamlead/board.md ] && echo yes || echo no)" no

check "worker-start with no --project and no CLAUDE_PROJECT_DIR: refused" \
  "$(env -u CLAUDE_PROJECT_DIR python3 "$B" worker-start --id w1 >"$T/wsout3" 2>&1; echo $?)" 1
grep -q 'pass --project' "$T/wsout3" && ok "  names the fix" || bad "  names the fix"

echo "== D2: forget requeues a running row whose worker is being cancelled =="
d2p=$T/d2; mkdir -p $d2p
python3 "$B" add --project $d2p --task "k1 work" --agent tl-sonnet-low --owns d2/k1 >/dev/null              # id 1
python3 "$B" add --project $d2p --task "k2 work" --agent tl-sonnet-low --owns d2/k2 >/dev/null              # id 2
python3 "$B" add --project $d2p --task "k1's earlier task" --agent tl-sonnet-low --owns d2/k1b >/dev/null   # id 3
python3 "$B" update --project $d2p --id 1 --state running --worker k1 >/dev/null
python3 "$B" update --project $d2p --id 2 --state running --worker k2 >/dev/null
python3 "$B" update --project $d2p --id 3 --state returned --worker k1 >/dev/null
NOWF2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  start     agent=teamlead:tl-sonnet-medium  id=k1\n' "$NOWF2" > $d2p/.claude/teamlead/.state/events.log
python3 "$B" forget k1 --project $d2p >"$T/d2out" 2>&1
req=$(python3 -c "import json;print(json.load(open('$T/d2out'))['requeued'])")
check "forget k1 reports row 1 requeued" "$req" "[1]"

st1d2=$(python3 -c "import json;d=json.load(open('$d2p/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==1][0];print(t['state']+'|'+t['worker']+'|'+(t['notes'] or ''))")
check "row 1 (k1, was running) requeued, worker kept, note appended" "$st1d2" "queued|k1|requeued: worker k1 lost on restart"

st2d2=$(python3 -c "import json;d=json.load(open('$d2p/.claude/teamlead/.state/board.json'));print([x['state'] for x in d['tasks'] if x['id']==2][0])")
check "row 2 (k2, not forgotten) is untouched" "$st2d2" "running"

st3d2=$(python3 -c "import json;d=json.load(open('$d2p/.claude/teamlead/.state/board.json'));print([x['state'] for x in d['tasks'] if x['id']==3][0])")
check "row 3 (returned, worker k1) is NOT requeued — the work already came back" "$st3d2" "returned"

check "board is still valid after the requeue" "$(python3 "$B" check --project $d2p >/dev/null 2>&1; echo $?)" 0

echo "== QC3: worker_stop and forget's requeue must not use a stale precondition =="
qc3p=$T/qc3; mkdir -p $qc3p
python3 "$B" add --project $qc3p --task "qc3 row" --agent tl-sonnet-low --owns qc3/a >/dev/null   # id 1
python3 "$B" update --project $qc3p --id 1 --state running --worker A >/dev/null
NOWQC3=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  start     agent=teamlead:tl-sonnet-medium  id=A\n' "$NOWQC3" > $qc3p/.claude/teamlead/.state/events.log
python3 -c "
import sys, json
sys.path.insert(0, '$bd')
import board
board.worker_stop('A', '$qc3p')
res = board.forget(['A'], '$qc3p')
row = [t for t in board.load('$qc3p')['tasks'] if t['id'] == 1][0]
print(json.dumps({'requeued': res['requeued'], 'state': row['state']}))
" > "$T/qc3out"
req3=$(python3 -c "import json; print(json.load(open('$T/qc3out'))['requeued'])")
check "sequential stop-then-forget: requeued is empty (row already returned)" "$req3" "[]"
state3=$(python3 -c "import json; print(json.load(open('$T/qc3out'))['state'])")
check "  row is returned, not overwritten to queued" "$state3" "returned"

qc3rp=$T/qc3race; mkdir -p $qc3rp
# Each racer slows board.save by 0.5s (the lock is held across it) and touches
# the marker file ($1) just before sleeping, so a caller can wait for "this racer
# holds the board lock" and only then start the other one. That makes the order
# deterministic; the old version started both at once and the winner was decided
# by python startup jitter, so the test asserted an order it never controlled.
qc3_racer() {  # $1 = marker file, $2 = stop | forget
  python3 -c "
import sys, time, pathlib
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    pathlib.Path('$1').touch()
    time.sleep(0.5)
    orig(db, project)
board.save = slow
if '$2' == 'stop':
    board.worker_stop('A', '$qc3rp')
else:
    board.forget(['A'], '$qc3rp')
"
}
qc3_setup() {
  rm -rf $qc3rp; mkdir -p $qc3rp
  python3 "$B" add --project $qc3rp --task "qc3 race row" --agent tl-sonnet-low --owns "qc3r/$1" >/dev/null  # id 1
  python3 "$B" update --project $qc3rp --id 1 --state running --worker A >/dev/null
  printf '%s  start     agent=teamlead:tl-sonnet-medium  id=A\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > $qc3rp/.claude/teamlead/.state/events.log
}
qc3_row() {
  python3 -c "import json; d=json.load(open('$qc3rp/.claude/teamlead/.state/board.json')); t=[x for x in d['tasks'] if x['id']==1][0]; print(t['state']+'|'+str(t['notes']))"
}
qc3_wait_for() { for _ in $(seq 1 200); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }
QC3_LOST='queued|requeued: worker A lost on restart'
for i in 1 2 3; do
  # stop takes the lock first; forget then re-checks under the lock, finds the row returned, requeues nothing
  qc3_setup "s$i"
  qc3_racer $qc3rp/m1 stop & sp1=$!
  qc3_wait_for $qc3rp/m1
  qc3_racer $qc3rp/m2 forget & sp2=$!
  wait $sp1 $sp2
  check "race iteration $i (stop holds the lock first): row 1 is returned with no requeue note" "$(qc3_row)" "returned|None"
  # forget takes the lock first and requeues; stop then re-checks under the lock, finds the row queued, leaves it alone
  qc3_setup "f$i"
  qc3_racer $qc3rp/m1 forget & sp1=$!
  qc3_wait_for $qc3rp/m1
  qc3_racer $qc3rp/m2 stop & sp2=$!
  wait $sp1 $sp2
  check "race iteration $i (forget holds the lock first): row 1 is requeued once, stop does not clobber it" "$(qc3_row)" "$QC3_LOST"
done
# Unordered race: both start at once. Either order is legal, but the outcome must
# be exactly one of the two consistent states, never a mix (returned with a requeue
# note, queued without one, a doubled note).
for i in 1 2 3; do
  qc3_setup "u$i"
  qc3_racer $qc3rp/m1 stop & sp1=$!
  qc3_racer $qc3rp/m2 forget & sp2=$!
  wait $sp1 $sp2
  race3=$(qc3_row)
  if [ "$race3" = "returned|None" ] || [ "$race3" = "$QC3_LOST" ]; then
    ok "unordered race iteration $i: one consistent outcome ($race3)"
  else
    bad "unordered race iteration $i: mixed or lost state (got $race3)"
  fi
done

echo "== QC4: forget's requeue lands on 'blocked', not 'queued', when a blocker is unmerged =="
qc4p=$T/qc4; mkdir -p $qc4p/.claude/teamlead/.state
cat > $qc4p/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 3, "tasks": [
  {"id": 1, "task": "blocker", "agent": "tl-sonnet-low", "owns": ["qc4/a"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "worker": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "dependant", "agent": "tl-sonnet-low", "owns": ["qc4/b"], "state": "running", "branch": null, "plan": null, "blocked_by": [1], "notes": null, "worker": "Z", "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $qc4p >/dev/null 2>&1
printf '%s  start     agent=teamlead:tl-sonnet-medium  id=Z\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > $qc4p/.claude/teamlead/.state/events.log
python3 "$B" forget Z --project $qc4p >"$T/qc4out" 2>&1
req4=$(python3 -c "import json;print(json.load(open('$T/qc4out'))['requeued'])")
check "forget Z reports row 2 requeued" "$req4" "[2]"
row2qc4=$(python3 -c "import json;d=json.load(open('$qc4p/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==2][0];print(t['state']+'|'+t['notes'])")
check "row 2 (blocker unmerged) lands on 'blocked', with the requeue note" "$row2qc4" \
  "blocked|requeued: worker Z lost on restart"

qc4bp=$T/qc4b; mkdir -p $qc4bp
python3 "$B" add --project $qc4bp --task "plain" --agent tl-sonnet-low --owns qc4b/a >/dev/null   # id 1
python3 "$B" update --project $qc4bp --id 1 --state running --worker Q >/dev/null
printf '%s  start     agent=teamlead:tl-sonnet-medium  id=Q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > $qc4bp/.claude/teamlead/.state/events.log
python3 "$B" forget Q --project $qc4bp >/dev/null 2>&1
st1qc4b=$(python3 -c "import json;print([t['state'] for t in json.load(open('$qc4bp/.claude/teamlead/.state/board.json'))['tasks'] if t['id']==1][0])")
check "no blockers: requeue still lands in queued" "$st1qc4b" "queued"

echo "== #4/#9: hold / release — the lead marks a kept worktree, tied to its row =="
hop=$T/hop; mkdir -p $hop
git -C $hop init -q; git -C $hop config user.email t@t.t; git -C $hop config user.name t
echo a > $hop/a; git -C $hop add a; git -C $hop commit -qm init
git -C $hop worktree add -q $hop/.claude/worktrees/agent-o1 -b worktree-agent-o1 2>/dev/null
git -C $hop worktree add -q $hop/.claude/worktrees/agent-o2 -b worktree-agent-o2 2>/dev/null
HOJ=$hop/.claude/teamlead/.state/board.json
hoq(){ python3 -c "import json;d=json.load(open('$HOJ'));t=[x for x in d['tasks'] if x['id']==$1][0];print($2)"; }
python3 "$B" add --project $hop --task "queued row" --agent tl-sonnet-low --owns ho/a >/dev/null    # 1
python3 "$B" add --project $hop --task "blocked row" --agent tl-sonnet-low --owns ho/b >/dev/null   # 2
python3 "$B" add --project $hop --task "running row" --agent tl-sonnet-low --owns ho/c >/dev/null   # 3
python3 "$B" add --project $hop --task "merged row" --agent tl-sonnet-low --owns ho/d >/dev/null    # 4
python3 "$B" update --project $hop --id 1 --worker o1 --branch worktree-agent-o1 >/dev/null
python3 "$B" update --project $hop --id 2 --state blocked --worker o2 >/dev/null
python3 "$B" update --project $hop --id 3 --state running --worker o3 --branch worktree-agent-o1 >/dev/null
python3 "$B" update --project $hop --id 4 --state merged >/dev/null
check "hold: an unknown row is refused" "$(python3 "$B" hold 99 --project $hop >/dev/null 2>&1; echo $?)" 1
check "  a running row is refused (its worker is out)" "$(python3 "$B" hold 3 --project $hop >"$T/hoout" 2>&1; echo $?)" 1
grep -q 'running' "$T/hoout" && ok "  and says why" || bad "  and says why (got: $(cat $T/hoout))"
check "  a merged row is refused" "$(python3 "$B" hold 4 --worktree $hop/.claude/worktrees/agent-o1 --project $hop >/dev/null 2>&1; echo $?)" 1
check "  the main checkout is not a worktree to hold" "$(python3 "$B" hold 1 --worktree $hop --project $hop >"$T/hoout" 2>&1; echo $?)" 1
grep -q 'not a linked worktree' "$T/hoout" && ok "  and says so" || bad "  and says so (got: $(cat $T/hoout))"
check "  a plain directory is refused" "$(python3 "$B" hold 1 --worktree $T --project $hop >/dev/null 2>&1; echo $?)" 1
check "  a worker may not hold (the board is the lead's)" "$(CLAUDE_AGENT_ID=x python3 "$B" hold 1 --project $hop >/dev/null 2>&1; echo $?)" 1
check "  no --project and no CLAUDE_PROJECT_DIR is refused (writes never resolve from cwd)" "$(env -u CLAUDE_PROJECT_DIR python3 "$B" hold 1 >/dev/null 2>&1; echo $?)" 1
check "  nothing was held by any refusal" "$(hoq 1 "'held' in t")" False
check "hold 2 with no branch resolves the path from the worker id" "$(python3 "$B" hold 2 --reason "kept as reference" --project $hop >/dev/null 2>&1; echo $?)" 0
check "  recorded path" "$(hoq 2 "t['held']['worktree']")" "$hop/.claude/worktrees/agent-o2"
check "  recorded the state it was held in" "$(hoq 2 "t['held']['state']")" blocked
check "  and the worker" "$(hoq 2 "t['held']['worker']")" o2
check "hold 1 with an explicit --worktree: exit 0" "$(python3 "$B" hold 1 --worktree $hop/.claude/worktrees/agent-o1/ --project $hop >/dev/null 2>&1; echo $?)" 0
check "  the stored path is the one git lists, not the spelling given" "$(hoq 1 "t['held']['worktree']")" "$hop/.claude/worktrees/agent-o1"
python3 "$B" held --project $hop >"$T/hheld" 2>&1
check "held lists both, neither lapsed" "$(python3 -c "import json;d=json.load(open('$T/hheld'));print(sorted((v['row'],v['lapsed']) for v in d.values()))")" "[(1, None), (2, None)]"
check "board check accepts held rows" "$(python3 "$B" check --project $hop >/dev/null 2>&1; echo $?)" 0
check "board_list (MCP) carries the hold" "$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"board_list","arguments":{}}}' | CLAUDE_PROJECT_DIR=$hop python3 "$B" --mcp | grep -c 'kept as reference')" 1
# anything that moves the row off the state it was held in drops the hold
python3 "$B" update --project $hop --id 2 --state queued >/dev/null 2>&1
check "blocked -> queued drops the hold" "$(hoq 2 "'held' in t")" False
python3 "$B" update --project $hop --id 1 --worker other >/dev/null 2>&1
check "a new worker on the row drops the hold" "$(hoq 1 "'held' in t")" False
python3 "$B" update --project $hop --id 1 --notes "just a note" >/dev/null 2>&1
python3 "$B" hold 1 --worktree $hop/.claude/worktrees/agent-o1 --project $hop >/dev/null 2>&1
python3 "$B" update --project $hop --id 1 --notes "a note does not lift it" >/dev/null 2>&1
check "an unrelated edit (notes) keeps the hold" "$(hoq 1 "'held' in t")" True
python3 "$B" release 1 --project $hop >/dev/null 2>&1
check "release drops it" "$(hoq 1 "'held' in t")" False
check "  releasing a row that is not held is harmless" "$(python3 "$B" release 1 --project $hop >/dev/null 2>&1; echo $?)" 0
check "  a worker may not release" "$(CLAUDE_AGENT_ID=x python3 "$B" release 1 --project $hop >/dev/null 2>&1; echo $?)" 1

echo "== I5/D3/D4: hooks.json wires PostToolUse(Agent) -> record.sh =="
check "hooks.json declares the PostToolUse Agent matcher" \
  "$(jq -e '.hooks.PostToolUse[0].matcher == "Agent"' "$H/hooks.json")" "true"
check "record.sh's silent-stderr sites did not grow (no new board call swallows stderr)" \
  "$(grep -c '2>/dev/null' "$H/record.sh")" 5   # 4 + the stale-base guard's one git helper

echo "== I5/D3/D4: PostToolUse(Agent) calls worker-start =="
p5=$T/i5; mkdir -p "$p5/.claude/teamlead/.state"; : > "$p5/.claude/teamlead/.state/active"
python3 "$B" add --project $p5 --task "row one" --agent tl-sonnet-low --owns i5/a >/dev/null   # id 1
python3 "$B" add --project $p5 --task "row two" --agent tl-sonnet-low --owns i5/b >/dev/null   # id 2
python3 "$B" add --project $p5 --task "row three" --agent tl-sonnet-low --owns i5/c >/dev/null # id 3
L5=$p5/.claude/teamlead/.state/events.log
row5(){ python3 -c "import json;d=json.load(open('$p5/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==$1][0];print(str(t['state'])+','+str(t['worker'])+','+str(t['branch']))"; }

PT1='{"hook_event_name":"PostToolUse","cwd":"'$p5'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"row one work","prompt":"Intro line one.\nboard: 1\nGoal: do the thing.","isolation":"worktree"},"tool_response":{"status":"async_launched","agentId":"pw1","description":"row one work","prompt":"Intro line one.\nboard: 1\nGoal: do the thing."}}'
check "PostToolUse, object tool_response, mid-brief marker, worktree isolation: exit 0" "$(ev "$PT1" "$H/record.sh")" 0
check "  row 1 -> running/pw1/worktree-agent-pw1" "$(row5 1)" "running,pw1,worktree-agent-pw1"

PT2='{"hook_event_name":"PostToolUse","cwd":"'$p5'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"row two work","prompt":"Intro line two.\nboard: 2\nGoal: do another thing."},"tool_response":{"status":"async_launched","agentId":"pw2","description":"row two work","prompt":"Intro line two.\nboard: 2\nGoal: do another thing."}}'
check "same, no isolation field: exit 0" "$(ev "$PT2" "$H/record.sh")" 0
check "  row 2 -> running/pw2, branch stays null" "$(row5 2)" "running,pw2,None"

PT3='{"hook_event_name":"PostToolUse","cwd":"'$p5'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"decoy","prompt":"see board: 1 above\nGoal: something else."},"tool_response":{"status":"async_launched","agentId":"px9","description":"decoy","prompt":"see board: 1 above"}}'
check "board: N embedded mid-line (not its own line): exit 0" "$(ev "$PT3" "$H/record.sh")" 0
check "  not matched — row 1 unchanged" "$(row5 1)" "running,pw1,worktree-agent-pw1"

w0=$(grep -c 'warn' $L5 2>/dev/null || echo 0)
PT4='{"hook_event_name":"PostToolUse","cwd":"'$p5'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"no marker","prompt":"Just a plain brief with no board line at all."},"tool_response":{"status":"async_launched","agentId":"px8","description":"no marker","prompt":"Just a plain brief with no board line at all."}}'
check "no board: marker anywhere: exit 0" "$(ev "$PT4" "$H/record.sh")" 0
check "  row 1 still unchanged" "$(row5 1)" "running,pw1,worktree-agent-pw1"
check "  no warn line emitted" "$(grep -c 'warn' $L5 2>/dev/null || echo 0)" "$w0"

PT5='{"hook_event_name":"PostToolUse","cwd":"'$p5'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"text fallback","prompt":"Some brief.\nboard: 3\nGoal: text fallback case."},"tool_response":"Dispatched async. agentId: pw2 status: ok"}'
check "tool_response as a plain string, agentId: X fallback: exit 0" "$(ev "$PT5" "$H/record.sh")" 0
check "  row 3 -> running/pw2 via the text fallback" "$(row5 3)" "running,pw2,None"

PT6='{"hook_event_name":"PostToolUse","cwd":"'$p5'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"broken response case","prompt":"Some brief with no useful info."},"tool_response":{"status":"async_launched","description":"nope"}}'
check "tool_response with neither an agentId field nor matching text: exit 0" "$(ev "$PT6" "$H/record.sh")" 0
grep -q 'warn      no-agent-id' $L5 && ok "  no-agent-id warned to the ledger" || bad "  no-agent-id warned to the ledger"

echo "== I5/D1: board.py refusals surface but never fail the hook =="
p5d=$T/i5-blocked; mkdir -p "$p5d/.claude/teamlead/.state"; : > "$p5d/.claude/teamlead/.state/active"
python3 "$B" add --project $p5d --task "d1" --agent tl-sonnet-low --owns i5d/a >/dev/null                 # id 1, unmerged
python3 "$B" add --project $p5d --task "d2" --agent tl-sonnet-low --owns i5d/b --blocked-by 1 >/dev/null  # id 2, blocked_by 1
L5D=$p5d/.claude/teamlead/.state/events.log
row5d(){ python3 -c "import json;d=json.load(open('$p5d/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==$1][0];print(str(t['state'])+','+str(t['worker']))"; }
before2=$(row5d 2)

PTB1='{"hook_event_name":"PostToolUse","cwd":"'$p5d'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"missing row","prompt":"Brief.\nboard: 99\nGoal: nothing."},"tool_response":{"status":"async_launched","agentId":"pwB1","description":"x","prompt":"y"}}'
echo "$PTB1" | "$H/record.sh" >"$T/outB1" 2>&1; rc=$?
check "board: 99 (no such row): hook still exits 0" "$rc" 0
grep -q '\[teamlead\] board:' "$T/outB1" && ok "  board.py stderr surfaced with the [teamlead] prefix" || bad "  board.py stderr surfaced with the [teamlead] prefix"
grep -q 'no task with id 99' "$T/outB1" && ok "  names the missing id" || bad "  names the missing id"
grep -q 'warn      board-refused' $L5D && ok "  logged to the ledger as board-refused" || bad "  logged to the ledger as board-refused"

PTB2='{"hook_event_name":"PostToolUse","cwd":"'$p5d'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"blocked row","prompt":"Brief.\nboard: 2\nGoal: nothing."},"tool_response":{"status":"async_launched","agentId":"pwB2","description":"x","prompt":"y"}}'
echo "$PTB2" | "$H/record.sh" >"$T/outB2" 2>&1; rc=$?
check "board: 2 while its blocker (1) is unmerged: hook still exits 0" "$rc" 0
grep -q 'is blocked by 1' "$T/outB2" && ok "  names the blocker" || bad "  names the blocker"
check "  row 2 unchanged (write was refused, never saved)" "$(row5d 2)" "$before2"

echo "== I5: non-tl-* subagent_type does nothing on PostToolUse =="
PTC='{"hook_event_name":"PostToolUse","cwd":"'$p5d'","tool_name":"Agent","tool_input":{"subagent_type":"generic-fetcher","description":"not ours","prompt":"Brief.\nboard: 1\nGoal: nothing."},"tool_response":{"status":"async_launched","agentId":"pwC","description":"x","prompt":"y"}}'
echo "$PTC" | "$H/record.sh" >"$T/outC" 2>&1; rc=$?
check "non-tl-* subagent_type: exit 0" "$rc" 0
check "  row 1 untouched" "$(row5d 1)" "queued,None"
check "  no output at all" "$(cat "$T/outC")" ""

echo "== I5/D12: SubagentStart/SubagentStop/SendMessage all drive worker-start/worker-stop =="
S1='{"hook_event_name":"SubagentStop","cwd":"'$p5'","agent_type":"teamlead:tl-sonnet-high","agent_id":"pw1","last_assistant_message":"done for now"}'
ev "$S1" "$H/record.sh" >/dev/null
check "SubagentStop(pw1): row 1 -> returned" "$(row5 1)" "returned,pw1,worktree-agent-pw1"

ST1='{"hook_event_name":"SubagentStart","cwd":"'$p5'","agent_type":"teamlead:tl-sonnet-high","agent_id":"pw1"}'
ev "$ST1" "$H/record.sh" >/dev/null
check "SubagentStart(pw1) resumes: row 1 -> running again" "$(row5 1)" "running,pw1,worktree-agent-pw1"

S2='{"hook_event_name":"SubagentStop","cwd":"'$p5'","agent_type":"teamlead:tl-sonnet-high","agent_id":"pw1","last_assistant_message":"stopped again"}'
ev "$S2" "$H/record.sh" >/dev/null
check "SubagentStop(pw1) again: row 1 -> returned" "$(row5 1)" "returned,pw1,worktree-agent-pw1"

SM1='{"hook_event_name":"PreToolUse","cwd":"'$p5'","tool_name":"SendMessage","tool_input":{"to":"pw1","summary":"resume please"}}'
ev "$SM1" "$H/record.sh" >/dev/null
check "SendMessage resume(pw1): row 1 -> running again, via the resume path" "$(row5 1)" "running,pw1,worktree-agent-pw1"

echo "== I5: no board.json is a no-op and creates nothing =="
p5h=$T/i5-noboard; mkdir -p "$p5h/.claude/teamlead/.state"; : > "$p5h/.claude/teamlead/.state/active"
PTE='{"hook_event_name":"PostToolUse","cwd":"'$p5h'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-high","description":"no board file","prompt":"Brief.\nboard: 1\nGoal: nothing.","isolation":"worktree"},"tool_response":{"status":"async_launched","agentId":"pwE","description":"x","prompt":"y"}}'
echo "$PTE" | "$H/record.sh" >"$T/outE" 2>&1; rc=$?
check "PostToolUse with a marker but no board.json: exit 0" "$rc" 0
check "  no board.json created" "$([ -f "$p5h/.claude/teamlead/.state/board.json" ] && echo yes || echo no)" no
check "  no stderr noise" "$(cat "$T/outE")" ""

echo "== D2: board.py clean cuts the merged rows and nothing else =="
clnp=$T/clean; mkdir -p $clnp
ccmd(){ python3 "$B" "$@" --project $clnp >"$T/cout" 2>&1; echo $?; }
for t in A B C D; do
  python3 "$B" add --project $clnp --task $t --agent tl-sonnet-low --owns cln/$t >/dev/null
done
python3 "$B" update --project $clnp --id 1 --state merged --notes 'swapped the loader' >/dev/null
python3 "$B" update --project $clnp --id 2 --state merged --notes 'fixed the parser' >/dev/null
python3 "$B" update --project $clnp --id 3 --state running --worker cw1 >/dev/null
cln_json=$clnp/.claude/teamlead/.state/board.json
cln_md=$clnp/.claude/teamlead/board.md
cln_open(){ python3 -c "import json; d=json.load(open('$cln_json')); print(json.dumps(sorted([t for t in d['tasks'] if t['state']!='merged'], key=lambda x: x['id']), sort_keys=True))"; }
cln_nid(){ python3 -c "import json; print(json.load(open('$cln_json'))['next_id'])"; }
cln_before=$(cln_open); cln_nid_before=$(cln_nid)
# sanity: the headings must be there BEFORE, or their absence after proves nothing
grep -q '^## Done' $cln_md && ok "before clean: board.md has '## Done'" || bad "before clean: board.md has '## Done'"
grep -q 'How it was solved' $cln_md && ok "before clean: board.md has '### How it was solved'" || bad "before clean: board.md has '### How it was solved'"
check "clean exits 0" "$(ccmd clean)" 0
grep -q 'cleaned 2 merged task(s): #1, #2' "$T/cout" && ok "  names the rows it cut" || bad "  names the rows it cut ($(cat "$T/cout"))"
check "  no merged row survives" \
  "$(python3 -c "import json; print(len([t for t in json.load(open('$cln_json'))['tasks'] if t['state']=='merged']))")" 0
check "  every open row is byte-identical to before" "$(cln_open)" "$cln_before"
check "  next_id is NOT reset by clean" "$(cln_nid)" "$cln_nid_before"
grep -q '^## Done' $cln_md && bad "  '## Done' must be gone from board.md" || ok "  '## Done' is gone from board.md"
grep -q 'How it was solved' $cln_md && bad "  '### How it was solved' must be gone" || ok "  '### How it was solved' is gone from board.md"
check "  check passes after clean" "$(ccmd check)" 0

echo "== D2: clean refuses rather than leave the board invalid =="
# A merged row can be the middle link of the blocked_by chain that is the only
# reason two OPEN rows may own the same path; cutting it would strand them.
clnr=$T/cleanrefuse; mkdir -p $clnr/.claude/teamlead/.state
cat > $clnr/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 4, "tasks": [
  {"id": 1, "task": "a", "agent": "tl-sonnet-low", "owns": ["chn/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "worker": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "b", "agent": "tl-sonnet-low", "owns": ["chn/y"], "state": "merged", "branch": null, "plan": null, "blocked_by": [1], "notes": "done", "worker": null, "created": "x", "updated": "x"},
  {"id": 3, "task": "c", "agent": "tl-sonnet-low", "owns": ["chn/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [2], "notes": null, "worker": null, "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $clnr >/dev/null 2>&1
# The fixture is hand-written on purpose: a merged row blocked by a NON-merged one
# is exactly what _validate_detailed rejects, so this state is unreachable through
# the API and `check` must say so. Assert that up front — otherwise the block below
# could be testing some other board entirely and nobody would notice.
python3 "$B" check --project $clnr >"$T/crchk" 2>&1
check "the fixture really is a board check itself rejects" "$?" 1
grep -q 'task 2 is blocked by 1, which is queued' "$T/crchk" \
  && ok "  check names the merged-row-blocked-by-an-open-row fault the fixture encodes" \
  || bad "  check names the merged-row-blocked-by-an-open-row fault the fixture encodes ($(cat "$T/crchk"))"
check "clean refuses when cutting the merged rows would invalidate the board" \
  "$(python3 "$B" clean --project $clnr >"$T/crout" 2>&1; echo $?)" 1
grep -q 'refused — cleaning would introduce board problems' "$T/crout" && ok "  names the reason" || bad "  names the reason ($(cat "$T/crout"))"
grep -q 'two writers on one path' "$T/crout" && ok "  names the overlap it would have created" || bad "  names the overlap it would have created"
check "  a refused clean mutates nothing" \
  "$(python3 -c "import json; print(len(json.load(open('$clnr/.claude/teamlead/.state/board.json'))['tasks']))")" 3

# F10: the other side of the same coin. A board that is ALREADY invalid for a
# reason clean has nothing to do with — two live rows on one path — plus an
# unrelated merged row. clean now diffs validate() before against after and
# refuses only on problems the cut INTRODUCED, so this must SUCCEED. Before the
# fix it refused, and blamed the cut for a fault that predated it.
clnp2=$T/cleanpre; mkdir -p $clnp2/.claude/teamlead/.state
cat > $clnp2/.claude/teamlead/.state/board.json <<'JSON'
{"next_id": 4, "tasks": [
  {"id": 1, "task": "a", "agent": "tl-sonnet-low", "owns": ["ov/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "worker": null, "created": "x", "updated": "x"},
  {"id": 2, "task": "b", "agent": "tl-sonnet-low", "owns": ["ov/x"], "state": "queued", "branch": null, "plan": null, "blocked_by": [], "notes": null, "worker": null, "created": "x", "updated": "x"},
  {"id": 3, "task": "c", "agent": "tl-sonnet-low", "owns": ["ov/z"], "state": "merged", "branch": null, "plan": null, "blocked_by": [], "notes": "done", "worker": null, "created": "x", "updated": "x"}
]}
JSON
python3 "$B" render --project $clnp2 >/dev/null 2>&1
python3 "$B" check --project $clnp2 >"$T/cpchk" 2>&1
check "the pre-existing overlap is real (check rejects this board too)" "$?" 1
grep -q 'two writers on one path' "$T/cpchk" && ok "  check names the live/live overlap" || bad "  check names the live/live overlap ($(cat "$T/cpchk"))"
check "clean SUCCEEDS despite a pre-existing fault the cut did not cause" \
  "$(python3 "$B" clean --project $clnp2 >"$T/cpout" 2>&1; echo $?)" 0
grep -q 'cleaned 1 merged task(s): #3' "$T/cpout" && ok "  the merged row was actually cut" || bad "  the merged row was actually cut ($(cat "$T/cpout"))"
check "  and the two live rows survive untouched" \
  "$(python3 -c "import json; print(','.join(str(t['id']) for t in json.load(open('$clnp2/.claude/teamlead/.state/board.json'))['tasks']))")" "1,2"
grep -q 'refused' "$T/cpout" && bad "  no refusal, and no false explanation" || ok "  no refusal, and no false explanation"

echo "== D3/D12: board.py drop reports BEFORE it mutates, then empties the board =="
drpp=$T/drop; mkdir -p $drpp/.claude/teamlead/plan
python3 "$B" add --project $drpp --task "keep me" --agent tl-sonnet-low --owns drp/a >/dev/null
python3 "$B" add --project $drpp --task "me too"  --agent tl-sonnet-low --owns drp/b >/dev/null
drp_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  dispatch  agent=tl-sonnet-high\n%s  start     agent=tl-sonnet-high  id=w0ffee\n' \
  "$drp_now" "$drp_now" > $drpp/.claude/teamlead/.state/events.log
drp_plan=$drpp/.claude/teamlead/plan/topic.md
printf '# T\n\n> **Stage 5** — building it\n' > $drp_plan
echo "$drp_plan" > $drpp/.claude/teamlead/.state/active-plan
drp_ap_before=$(cat $drpp/.claude/teamlead/.state/active-plan)
drp_json=$drpp/.claude/teamlead/.state/board.json
drp_bak=$drp_json.dropped
python3 "$B" drop --project $drpp >"$T/drout" 2>&1; drc=$?
check "drop exits 0 even with a worker still out" "$drc" 0
# Ordering, not just presence: the report is only a report if it lands before the act.
drl(){ grep -n -- "$1" "$T/drout" | head -1 | cut -d: -f1; }
l_hdr=$(drl 'drop — about to empty the board:')
l_cnt=$(drl 'open task(s) and 0 merged task(s) will be removed')
l_wrk=$(drl 'workers still out')
l_pln=$(drl 'plan ACTIVE:')
l_mut=$(drl 'dropped 2 task(s); next_id reset to 1')
l_bak=$(drl '  backup: ')
check "  the report opens the output" "$l_hdr" 1
if [ -n "$l_mut" ] && [ -n "$l_cnt" ] && [ -n "$l_wrk" ] && [ -n "$l_pln" ] \
   && [ "$l_cnt" -lt "$l_mut" ] && [ "$l_wrk" -lt "$l_mut" ] && [ "$l_pln" -lt "$l_mut" ]; then
  ok "  every pre-flight line is printed BEFORE the mutation line"
else bad "  pre-flight must precede the mutation (cnt=$l_cnt wrk=$l_wrk pln=$l_pln mut=$l_mut)"; fi
if [ -n "$l_bak" ] && [ -n "$l_mut" ] && [ "$l_bak" -gt "$l_mut" ]; then
  ok "  the backup path is reported after the mutation"
else bad "  the backup path is reported after the mutation (bak=$l_bak mut=$l_mut)"; fi
grep -q '^  2 open task(s) and 0 merged task(s) will be removed$' "$T/drout" && ok "  report states the open-row count" || bad "  report states the open-row count"
grep -q 'w0ffee (tl-sonnet-high)' "$T/drout" && ok "  report names the worker still out, with its agent" || bad "  report names the worker still out, with its agent"
grep -q 'worktrees are NOT touched' "$T/drout" && ok "  report says the worktrees are not touched" || bad "  report says the worktrees are not touched"
grep -qF "plan ACTIVE: $drp_plan" "$T/drout" && ok "  report flags the active plan by path" || bad "  report flags the active plan by path"
grep -q 'active-plan is left alone' "$T/drout" && ok "  report warns check will now miss the plan's steps" || bad "  report warns check will now miss the plan's steps"
grep -q 'stopped worker(s): w0ffee' "$T/drout" && ok "  reports which workers it stopped" || bad "  reports which workers it stopped"
check "  tasks emptied" "$(python3 -c "import json; print(len(json.load(open('$drp_json'))['tasks']))")" 0
check "  next_id reset to 1" "$(python3 -c "import json; print(json.load(open('$drp_json'))['next_id'])")" 1
check "  events.log truncated" "$(wc -c < $drpp/.claude/teamlead/.state/events.log)" 0
check "  backup written" "$([ -f $drp_bak ] && echo 0 || echo 1)" 0
check "  backup parses as JSON holding the pre-drop rows" \
  "$(python3 -c "import json; d=json.load(open('$drp_bak')); print(','.join(sorted(t['task'] for t in d['tasks'])))")" "keep me,me too"
check "  .state/active-plan survives drop, unchanged" "$(cat $drpp/.claude/teamlead/.state/active-plan)" "$drp_ap_before"
check "  the plan file itself is untouched" "$([ -f $drp_plan ] && echo 0 || echo 1)" 0
check "  check passes after drop" "$(python3 "$B" check --project $drpp >/dev/null 2>&1; echo $?)" 0
# Documented, not accidental: the backup is a single slot, overwritten every time.
python3 "$B" add --project $drpp --task "after the drop" --agent tl-sonnet-low >/dev/null
python3 "$B" drop --project $drpp >/dev/null 2>&1
check "  a second drop OVERWRITES the backup — there is no rotation" \
  "$(python3 -c "import json; d=json.load(open('$drp_bak')); print(','.join(t['task'] for t in d['tasks']))")" "after the drop"
check "  and leaves no rotated copy behind" "$(ls $drpp/.claude/teamlead/.state/ | grep -c dropped)" 1

echo "== D4: clean and drop are lead-only, like every other board write =="
check "worker (CLAUDE_AGENT_ID set) clean: refused" \
  "$(CLAUDE_AGENT_ID=x python3 "$B" clean --project $clnp >"$T/cdout" 2>&1; echo $?)" 1
grep -q 'workers report, the lead records' "$T/cdout" && ok "  names the reason" || bad "  names the reason"
check "worker (CLAUDE_AGENT_ID set) drop: refused" \
  "$(CLAUDE_AGENT_ID=x python3 "$B" drop --project $clnp >"$T/cdout2" 2>&1; echo $?)" 1
grep -q 'workers report, the lead records' "$T/cdout2" && ok "  names the reason" || bad "  names the reason"
check "  the refused drop wrote no backup" \
  "$([ -f $clnp/.claude/teamlead/.state/board.json.dropped ] && echo yes || echo no)" no
check "  the refused drop left the rows alone" \
  "$(python3 -c "import json; print(len(json.load(open('$cln_json'))['tasks']))")" 2


echo "== F1: drop --dry-run prints the whole pre-flight report and changes NOTHING =="
# The report is the only place the facts the lead's D3 confirmation needs exist
# (how many open rows, which workers stop, whether a plan is active), so there has
# to be a way to read them WITHOUT the destruction they describe.
dryp=$T/dropdry; mkdir -p $dryp/.claude/teamlead/plan
python3 "$B" add --project $dryp --task "dry a" --agent tl-sonnet-low --owns dry/a >/dev/null
python3 "$B" add --project $dryp --task "dry b" --agent tl-sonnet-low --owns dry/b >/dev/null
python3 "$B" update --project $dryp --id 2 --state merged --notes 'shipped' >/dev/null
dry_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  dispatch  agent=tl-sonnet-high\n%s  start     agent=tl-sonnet-high  id=wdry1\n' \
  "$dry_now" "$dry_now" > $dryp/.claude/teamlead/.state/events.log
dry_plan=$dryp/.claude/teamlead/plan/dt.md
printf '# D\n\n> **Stage 5** — building it\n' > $dry_plan
echo "$dry_plan" > $dryp/.claude/teamlead/.state/active-plan
dry_json=$dryp/.claude/teamlead/.state/board.json
dry_log=$dryp/.claude/teamlead/.state/events.log
cp "$dry_json" "$T/dry-json-before"; cp "$dry_log" "$T/dry-log-before"
python3 "$B" drop --dry-run --project $dryp >"$T/dryout" 2>&1; dryrc=$?
check "drop --dry-run exits 0" "$dryrc" 0
cmp -s "$dry_json" "$T/dry-json-before" && ok "  board.json is byte-identical afterwards" \
  || bad "  board.json is byte-identical afterwards"
cmp -s "$dry_log" "$T/dry-log-before" && ok "  events.log is byte-identical afterwards" \
  || bad "  events.log is byte-identical afterwards"
check "  no board.json.dropped was created" \
  "$([ -f $dry_json.dropped ] && echo yes || echo no)" no
# The report must be the FULL one, not a summary — same facts, same order.
grep -q '^drop — about to empty the board:$' "$T/dryout" && ok "  prints the report header" || bad "  prints the report header"
grep -q '^  1 open task(s) and 1 merged task(s) will be removed$' "$T/dryout" && ok "  states both counts" || bad "  states both counts ($(cat "$T/dryout"))"
grep -q 'wdry1 (tl-sonnet-high)' "$T/dryout" && ok "  names the worker still out" || bad "  names the worker still out"
grep -qF "plan ACTIVE: $dry_plan" "$T/dryout" && ok "  flags the active plan by path" || bad "  flags the active plan by path"
check "  closes with the exact dry-run line" "$(tail -1 "$T/dryout")" \
  "  dry run — nothing was changed; run the same command without --dry-run to do it"
# F1: both paths print ONE shared print_drop_report(), so the blocks must be
# byte-identical. Pin it — a copy-paste second report would drift silently.
python3 "$B" drop --project $dryp >"$T/realout" 2>&1
sed -n '/^drop — about to empty the board:$/,/^  no active plan$\|^  ! the plan/p' "$T/dryout" > "$T/dry-block"
sed -n '/^drop — about to empty the board:$/,/^  no active plan$\|^  ! the plan/p' "$T/realout" > "$T/real-block"
check "  the dry-run block is non-empty (the extractor still matches)" \
  "$([ -s "$T/dry-block" ] && echo ok || echo empty)" ok
cmp -s "$T/dry-block" "$T/real-block" \
  && ok "  dry-run and real drop print a byte-identical report block" \
  || bad "  dry-run and real drop print a byte-identical report block ($(diff "$T/dry-block" "$T/real-block" | head -4 | tr '\n' ' '))"

echo "== F2: drop backs up a CORRUPT board byte-for-byte, and says the counts are junk =="
# Before the fix the backup was json.dumps(load()), and load() swallows the parse
# error — so the one recoverable copy of a damaged board was overwritten with
# {"next_id": 1, "tasks": []}. The backup must be a byte copy.
crpp=$T/dropcorrupt; mkdir -p $crpp
python3 "$B" add --project $crpp --task "ALPHArow" --agent tl-sonnet-low --owns cr/a >/dev/null
python3 "$B" add --project $crpp --task "BETArow"  --agent tl-sonnet-low --owns cr/b >/dev/null
crp_json=$crpp/.claude/teamlead/.state/board.json
# Truncate mid-file: no longer parses, but the rows are still there as readable
# text. Cutting a fixed number of bytes off the END (rather than to a fixed size)
# keeps both row titles intact however the schema grows.
truncate -s $(( $(wc -c < "$crp_json") - 30 )) "$crp_json"
cp "$crp_json" "$T/corrupt-before"
check "the truncated fixture still holds both row titles as text" \
  "$(grep -c 'ALPHArow\|BETArow' "$crp_json")" 2
python3 -c "import json,sys; json.load(open('$crp_json'))" 2>/dev/null \
  && bad "the fixture must NOT parse as JSON" || ok "the fixture really is unparseable JSON"
python3 "$B" drop --project $crpp >"$T/crpout" 2>&1; crprc=$?
check "drop on a corrupt board exits 0" "$crprc" 0
cmp -s "$crp_json.dropped" "$T/corrupt-before" \
  && ok "  the backup is a BYTE COPY of the corrupt original" \
  || bad "  the backup is a BYTE COPY of the corrupt original"
grep -q 'ALPHArow' "$crp_json.dropped" && ok "  a row title is still greppable out of the backup" \
  || bad "  a row title is still greppable out of the backup"
grep -q 'BETArow' "$crp_json.dropped" && ok "  and so is the second one" \
  || bad "  and so is the second one"
grep -q '! .state/board.json could not be parsed' "$T/crpout" \
  && ok "  the report warns the file did not parse" || bad "  the report warns the file did not parse"
# Position is deliberate: the caveat must be readable ABOVE the count it disowns,
# so a lead skimming the report cannot take the count at face value.
crl(){ grep -n -- "$1" "$T/crpout" | head -1 | cut -d: -f1; }
l_warn=$(crl '! .state/board.json could not be parsed'); l_ct=$(crl 'will be removed')
if [ -n "$l_warn" ] && [ -n "$l_ct" ] && [ "$l_warn" -lt "$l_ct" ]; then
  ok "  the unparseable warning is printed ABOVE the count line"
else bad "  the unparseable warning is printed ABOVE the count line (warn=$l_warn count=$l_ct)"; fi

echo "== F4: clean strips the removed ids out of every surviving blocked_by =="
# The existing clean test cannot see this: all four of its rows have an empty
# blocked_by. A dangling blocker id is unsatisfiable forever — _auto_unblock only
# requeues when every blocker is in merged_ids, and an id that no longer exists
# never can be — so the row is stuck for good and board.md points at nothing.
f4p=$T/cleanbb; mkdir -p $f4p
python3 "$B" add --project $f4p --task A --agent tl-sonnet-low --owns f4/a >/dev/null              # id 1
python3 "$B" add --project $f4p --task B --agent tl-sonnet-low --owns f4/b --blocked-by 1 >/dev/null  # id 2
python3 "$B" update --project $f4p --id 1 --state merged --notes done >/dev/null
f4_json=$f4p/.claude/teamlead/.state/board.json
f4_bb(){ python3 -c "import json; d=json.load(open('$f4_json')); print(json.dumps([t['blocked_by'] for t in d['tasks'] if t['id']==2][0]))"; }
check "before clean: row 2 still records blocked_by [1]" "$(f4_bb)" "[1]"
check "clean exits 0" "$(python3 "$B" clean --project $f4p >"$T/f4out" 2>&1; echo $?)" 0
check "  row 2's blocked_by is emptied, not left dangling at the cut row" "$(f4_bb)" "[]"
grep -q 'blocked-by 1' $f4p/.claude/teamlead/board.md \
  && bad "  board.md must not render 'blocked-by 1' pointing at a row that is gone" \
  || ok "  board.md no longer renders a blocker that does not exist"
# The real damage was a PERMANENTLY stuck row: prove it can still be cleared.
check "  row 2 can still be set blocked" \
  "$(python3 "$B" update --project $f4p --id 2 --state blocked >/dev/null 2>&1; echo $?)" 0
check "  and a plain update --state queued clears it again" \
  "$(python3 "$B" update --project $f4p --id 2 --state queued >/dev/null 2>&1; echo $?)" 0
check "  row 2 really is queued now" \
  "$(python3 -c "import json; print([t['state'] for t in json.load(open('$f4_json'))['tasks'] if t['id']==2][0])")" queued
check "  check passes after the clean" "$(python3 "$B" check --project $f4p >/dev/null 2>&1; echo $?)" 0

echo "== F11: drop on a project with no board creates NOTHING =="
nbp=$T/dropnoboard; mkdir -p $nbp
for flags in "" "--dry-run"; do
  if [ -z "$flags" ]; then lbl="(real)"; else lbl="$flags"; fi
  # shellcheck disable=SC2086
  python3 "$B" drop $flags --project $nbp >"$T/nbout" 2>&1; nbrc=$?
  check "drop $lbl with no board: exits 0" "$nbrc" 0
  grep -qF 'drop — nothing to drop: this project has no board (.state/board.json does not exist)' "$T/nbout" \
    && ok "  says there is nothing to drop, naming the missing file" \
    || bad "  says there is nothing to drop, naming the missing file ($(cat "$T/nbout"))"
  grep -q 'no files were created' "$T/nbout" && ok "  and says it created nothing" || bad "  and says it created nothing"
  check "  no board.json created" "$([ -f "$nbp/.claude/teamlead/.state/board.json" ] && echo yes || echo no)" no
  check "  no backup created" "$([ -f "$nbp/.claude/teamlead/.state/board.json.dropped" ] && echo yes || echo no)" no
  check "  the .claude/teamlead tree is not created at all" \
    "$([ -e "$nbp/.claude/teamlead" ] && echo yes || echo no)" no
done

echo "== F12: an unwritable .state/ is a one-line error, never a traceback =="
if [ "$(id -u)" -eq 0 ]; then
  ok "skipped: running as root, chmod a-w does not bite"
else
  f12p=$T/dropro; mkdir -p $f12p
  python3 "$B" add --project $f12p --task "hold me" --agent tl-sonnet-low --owns f12/a >/dev/null
  f12_json=$f12p/.claude/teamlead/.state/board.json
  f12_md5=$(md5sum < "$f12_json")
  chmod a-w "$f12p/.claude/teamlead/.state"
  python3 "$B" drop --project $f12p >"$T/f12out" 2>"$T/f12err"; f12rc=$?
  chmod u+w "$f12p/.claude/teamlead/.state"
  check "drop into an unwritable .state/ exits 1" "$f12rc" 1
  grep -q 'Permission denied' "$T/f12err" && ok "  the error names Permission denied" \
    || bad "  the error names Permission denied ($(cat "$T/f12err"))"
  grep -q 'the board was not modified' "$T/f12err" && ok "  and states nothing was changed" \
    || bad "  and states nothing was changed"
  grep -q 'Traceback (most recent call last)' "$T/f12err" \
    && bad "  a Python traceback escaped to the lead" || ok "  no Python traceback"
  check "  the error is one line" "$(wc -l < "$T/f12err")" 1
  check "  board.json is byte-unchanged" "$(md5sum < "$f12_json")" "$f12_md5"
  check "  and no half-written backup was left behind" \
    "$(ls "$f12p/.claude/teamlead/.state/" | grep -c 'dropped')" 0
fi

echo "== F1: a valueless flag must not swallow the argument after it =="
# main()'s loop advanced i by 2 unconditionally, so `--dry-run` consumed the NEXT
# token: `drop --dry-run --project X` lost --project entirely and fell back to
# CLAUDE_PROJECT_DIR/cwd. The failure mode is operating on the WRONG PROJECT, so
# both orderings are asserted on which project's facts came back, not on exit code.
# This is shared parser behaviour, not a drop quirk — every command inherits it.
pvA=$T/argv-right; pvB=$T/argv-wrong; mkdir -p $pvA $pvB
for t in A1 A2 A3; do python3 "$B" add --project $pvA --task $t --agent tl-sonnet-low --owns av/$t >/dev/null; done
python3 "$B" add --project $pvB --task B1 --agent tl-sonnet-low --owns av/b1 >/dev/null
pvB_json=$pvB/.claude/teamlead/.state/board.json
pvB_md5=$(md5sum < "$pvB_json")
pvrows(){ python3 -c "import json; print(len(json.load(open('$1'))['tasks']))"; }
# cwd AND CLAUDE_PROJECT_DIR both point at the WRONG project, so a lost --project
# is unmistakable: the report would describe 1 row instead of 3.
( cd $pvB && CLAUDE_PROJECT_DIR=$pvB python3 "$B" drop --dry-run --project $pvA >"$T/av1" 2>&1 )
check "drop --dry-run --project X: exits 0" "$?" 0
grep -q '^  3 open task(s) and 0 merged task(s) will be removed$' "$T/av1" \
  && ok "  reports the project passed with --project, not cwd/CLAUDE_PROJECT_DIR" \
  || bad "  reports the project passed with --project, not cwd/CLAUDE_PROJECT_DIR ($(cat "$T/av1"))"
( cd $pvB && CLAUDE_PROJECT_DIR=$pvB python3 "$B" drop --project $pvA --dry-run >"$T/av2" 2>&1 )
check "drop --project X --dry-run: exits 0" "$?" 0
grep -q '^  3 open task(s) and 0 merged task(s) will be removed$' "$T/av2" \
  && ok "  the reverse ordering resolves the same project" \
  || bad "  the reverse ordering resolves the same project ($(cat "$T/av2"))"
cmp -s "$T/av1" "$T/av2" && ok "  both orderings produce identical output" \
  || bad "  both orderings produce identical output"
check "  --dry-run still took effect: the right project is untouched" "$(pvrows "$pvA/.claude/teamlead/.state/board.json")" 3
check "  the wrong project was never read or written (rows)" "$(pvrows "$pvB_json")" 1
check "  the wrong project was never read or written (bytes)" "$(md5sum < "$pvB_json")" "$pvB_md5"
check "  the wrong project got no backup" \
  "$([ -f "$pvB_json.dropped" ] && echo yes || echo no)" no
# And the real thing: --project must actually steer the mutation, not just the report.
( cd $pvB && CLAUDE_PROJECT_DIR=$pvB python3 "$B" drop --project $pvA >/dev/null 2>&1 )
check "  a real drop empties the project named by --project" "$(pvrows "$pvA/.claude/teamlead/.state/board.json")" 0
check "  and leaves cwd/CLAUDE_PROJECT_DIR's board alone" "$(md5sum < "$pvB_json")" "$pvB_md5"
echo "== T65: SubagentStop is final only when the worker's last tool call is SubagentHandback =="
tp=$T/t65; mkdir -p "$tp/.claude/teamlead/.state"; : > "$tp/.claude/teamlead/.state/active"
git -C "$tp" init -q; git -C "$tp" config user.email t@t.t; git -C "$tp" config user.name t
echo a > "$tp/a"; git -C "$tp" add a; git -C "$tp" commit -qm init
python3 "$B" add --project $tp --task "bg job" --agent tl-sonnet-low --owns t65/a >/dev/null   # id 1
python3 "$B" add --project $tp --task "old" --agent tl-sonnet-low --owns t65/b >/dev/null      # id 2
LT=$tp/.claude/teamlead/.state/events.log
TGATE='{"hook_event_name":"Stop","cwd":"'$tp'","stop_hook_active":false}'
rowt(){ python3 -c "import json;d=json.load(open('$tp/.claude/teamlead/.state/board.json'));t=[x for x in d['tasks'] if x['id']==$1][0];print(t['state'])"; }
outt(){ python3 "$B" ledger --project $tp | python3 -c "import json,sys;print(' '.join(json.load(sys.stdin)['outstanding']))"; }
REM='{"type":"user","message":{"role":"user","content":"<system-reminder>\nYour final report is delivered through SubagentHandback: call it when done.\n</system-reminder>\nboard: 1"}}'
BASH_TU='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make","run_in_background":true}}]}}'
HB_TU='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"SubagentHandback","input":{"message":"done"}}]}}'
TXT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Handed back."}]}}'
printf '%s\n' "$REM" "$BASH_TU" > $T/t65-pause.jsonl
printf '%s\n' "$REM" "$BASH_TU" "$HB_TU" "$TXT" > $T/t65-final.jsonl
printf '%s\n' '{"type":"user","message":{"role":"user","content":"board: 2"}}' "$BASH_TU" > $T/t65-old.jsonl
TSTOP(){ echo '{"hook_event_name":"SubagentStop","cwd":"'$tp'","agent_type":"teamlead:tl-sonnet-low","agent_id":"'$1'","agent_transcript_path":"'$2'","transcript_path":"'$T/t65-final.jsonl'","last_assistant_message":"'$3'"}'; }
ev '{"hook_event_name":"PostToolUse","cwd":"'$tp'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-low","description":"bg","prompt":"x\nboard: 1","isolation":"worktree"},"tool_response":{"agentId":"tw1"}}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStart","cwd":"'$tp'","agent_type":"teamlead:tl-sonnet-low","agent_id":"tw1"}' "$H/record.sh" >/dev/null
git -C "$tp" worktree add -q "$tp/.claude/worktrees/agent-tw1" -b worktree-agent-tw1 2>/dev/null
echo wip > "$tp/.claude/worktrees/agent-tw1/wip.txt"
check "pause stop (last tool Bash, Handback offered): exit 0" "$(ev "$(TSTOP tw1 $T/t65-pause.jsonl 'waiting on make')" "$H/record.sh")" 0
check "  row 1 stays running" "$(rowt 1)" running
check "  tw1 still outstanding" "$(outt)" tw1
grep -qE '  pause     agent=teamlead:tl-sonnet-low  id=tw1$' $LT && ok "  pause line in the ledger" || bad "  pause line in the ledger"
grep -q '  return .*id=tw1' $LT && bad "  no return line" || ok "  no return line"
check "  gate passes while tw1 is paused" "$(ev "$TGATE" "$H/gate.sh")" 0; grep -q 'left work behind' $T/out && bad "  gate check 3 skips the paused worker's dirty worktree" || ok "  gate check 3 skips the paused worker's dirty worktree"
grep -q "'running' but only" $T/out && bad "  gate check 1 quiet" || ok "  gate check 1 quiet"
check "final stop (last tool SubagentHandback): exit 0" "$(ev "$(TSTOP tw1 $T/t65-final.jsonl 'Handed back.')" "$H/record.sh")" 0
check "  row 1 -> returned" "$(rowt 1)" returned
check "  tw1 no longer outstanding" "$(outt)" ""
grep -qE '  return    agent=teamlead:tl-sonnet-low  id=tw1  msg=Handed back\.' $LT && ok "  return line written" || bad "  return line written"
ev "$TGATE" "$H/gate.sh" >/dev/null
grep -q 'agent-tw1 — uncommitted changes' $T/out && ok "  gate check 3 now reports its dirty worktree" || bad "  gate check 3 now reports its dirty worktree"
ev "$(TSTOP tw1 $T/t65-pause.jsonl 'late')" "$H/record.sh" >/dev/null
check "a stray pause after the return does not reopen tw1" "$(outt)" ""
ev '{"hook_event_name":"PostToolUse","cwd":"'$tp'","tool_name":"Agent","tool_input":{"subagent_type":"teamlead:tl-sonnet-low","description":"old","prompt":"x\nboard: 2"},"tool_response":{"agentId":"tw2"}}' "$H/record.sh" >/dev/null
ev "$(TSTOP tw2 $T/t65-old.jsonl done)" "$H/record.sh" >/dev/null
check "harness without SubagentHandback (never named): final, row 2 -> returned" "$(rowt 2)" returned
ev "$(TSTOP tw3 $T/nope.jsonl done)" "$H/record.sh" >/dev/null
grep -q '  return    agent=teamlead:tl-sonnet-low  id=tw3' $LT && ok "unreadable transcript: final, return line written" || bad "unreadable transcript: final, return line written"

echo "== #4/#9: a worktree kept on purpose is held, not re-flagged every turn =="
# The flaw class: check 3 cannot tell "kept on purpose" from "forgotten", so it fires
# every turn on a correct state. `board.py hold` is the acknowledgement; it lapses on
# a row state change or re-dispatch, and, only with --until-change (#16), on a new
# commit or edit in the worktree.
hp=$T/h4; mkdir -p "$hp/.claude/teamlead/.state"; : > "$hp/.claude/teamlead/.state/active"
git -C "$hp" init -q; git -C "$hp" config user.email t@t.t; git -C "$hp" config user.name t
echo a > "$hp/a"; git -C "$hp" add a; git -C "$hp" commit -qm init
HGATE='{"hook_event_name":"Stop","cwd":"'$hp'","stop_hook_active":false}'
HJ=$hp/.claude/teamlead/.state/board.json
hjq(){ python3 -c "import json;d=json.load(open('$HJ'));t=[x for x in d['tasks'] if x['id']==$1][0];print($2)"; }
hwt(){ git -C "$hp" worktree add -q "$hp/.claude/worktrees/agent-$1" -b "worktree-agent-$1" 2>/dev/null; }
python3 "$B" add --project $hp --task "h1 work" --agent tl-sonnet-low --owns h4/a >/dev/null   # id 1
python3 "$B" add --project $hp --task "h2 work" --agent tl-sonnet-low --owns h4/b >/dev/null   # id 2
python3 "$B" add --project $hp --task "h3 work" --agent tl-sonnet-low --owns h4/c >/dev/null   # id 3
# #4: workers stopped (TaskStop + forget), rows requeued, worktrees kept with partial work
python3 "$B" update --project $hp --id 1 --state running --worker h1 --branch worktree-agent-h1 >/dev/null
hwt h1; echo partial > "$hp/.claude/worktrees/agent-h1/wip.txt"
printf '%s  start     agent=teamlead:tl-sonnet-medium  id=h1\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $hp/.claude/teamlead/.state/events.log
python3 "$B" forget h1 --project $hp >/dev/null 2>&1
check "  setup: row 1 requeued by forget" "$(hjq 1 "t['state']")" queued
check "no hold: turn 1 flags the kept worktree" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'agent-h1 — uncommitted changes' $T/out && ok "  and names it" || bad "  and names it"
check "no hold: turn 2 flags it again (the flaw)" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'board.py hold' $T/out && ok "  the message names the way to acknowledge it" || bad "  the message names the way to acknowledge it"
python3 "$B" hold 1 --reason "paused by the user" --project $hp >"$T/hout" 2>&1
check "hold 1 (worktree resolved from the row's branch): exit 0" "$?" 0
check "  the row records the hold" "$(hjq 1 "t['held']['reason']")" "paused by the user"
check "  and the worktree path" "$(hjq 1 "t['held']['worktree']")" "$hp/.claude/worktrees/agent-h1"
check "held: turn 1 is silent" "$(ev "$HGATE" "$H/gate.sh")" 0
check "held: turn 2 is silent" "$(ev "$HGATE" "$H/gate.sh")" 0
check "held: turn 3 is silent" "$(ev "$HGATE" "$H/gate.sh")" 0
grep -q 'left work behind' $T/out && bad "  nothing about left-behind work" || ok "  nothing about left-behind work"
python3 "$B" status --project $hp >"$T/hstat" 2>&1
grep -q 'held.*agent-h1.*paused by the user' "$T/hstat" && ok "  board.py status still lists it, with the reason" || bad "  board.py status still lists it, with the reason (got: $(cat $T/hstat))"
# #16: a default hold survives new work in the worktree. The gate shows ONE note (a
# systemMessage on exit 0, never a block), once per hold, and the hold stays good.
echo more > "$hp/.claude/worktrees/agent-h1/more.txt"
check "#16 an edit in a default-held worktree does not block" "$(ev "$HGATE" "$H/gate.sh")" 0
grep -q 'agent-h1.*row 1.*new commits or edits since the hold' $T/out && ok "  a one-line note says so" || bad "  a one-line note says so (got: $(cat $T/out))"
grep -q 'systemMessage' $T/out && ok "  as a systemMessage, not a block" || bad "  as a systemMessage (got: $(cat $T/out))"
check "  the hold is still on the row, marked noted" "$(hjq 1 "t['held'].get('noted')")" True
check "  next turn: silent" "$(ev "$HGATE" "$H/gate.sh")" 0
[ -s $T/out ] && bad "  next turn prints nothing (got: $(cat $T/out))" || ok "  next turn prints nothing"
git -C "$hp/.claude/worktrees/agent-h1" add -A; git -C "$hp/.claude/worktrees/agent-h1" commit -qm "more work"
check "#16 a new commit in a default-held worktree does not block" "$(ev "$HGATE" "$H/gate.sh")" 0
[ -s $T/out ] && bad "  and the note is not repeated (got: $(cat $T/out))" || ok "  and the note is not repeated"
python3 "$B" status --project $hp >"$T/hstat" 2>&1
grep -q 'held.*agent-h1.*new work since the hold' "$T/hstat" && ok "  board.py status flags the new work" || bad "  board.py status flags the new work (got: $(cat $T/hstat))"
check "  held: not lapsed" "$(python3 "$B" held --project $hp | python3 -c "import json,sys;print([v['lapsed'] for v in json.load(sys.stdin).values()])")" "[None]"
# when the turn is blocked anyway (an unheld finding), the note rides along in the block, once
python3 "$B" add --project $hp --task "h1n work" --agent tl-sonnet-low --owns h4/n >/dev/null
hn=$(python3 -c "import json;print(max(t['id'] for t in json.load(open('$HJ'))['tasks']))")
hwt h1n; python3 "$B" update --project $hp --id $hn --state queued --worker h1n --branch worktree-agent-h1n >/dev/null
python3 "$B" hold $hn --reason "r" --project $hp >/dev/null 2>&1
hwt h1m; echo y > "$hp/.claude/worktrees/agent-h1m/y.txt"
echo z > "$hp/.claude/worktrees/agent-h1n/z.txt"
check "#16 with another finding the turn is blocked" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'note (shown once)' $T/out && grep -q 'agent-h1n' $T/out && ok "  and carries the note for the held worktree" || bad "  and carries the note (got: $(cat $T/out))"
check "  next turn: still blocked by the real finding" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'note (shown once)' $T/out && bad "  but without the note again" || ok "  but without the note again"
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h1m"; git -C "$hp" branch -D worktree-agent-h1m >/dev/null 2>&1
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h1n"; git -C "$hp" branch -D worktree-agent-h1n >/dev/null 2>&1
python3 "$B" update --project $hp --id $hn --state merged >/dev/null 2>&1
check "  worktrees removed: silent again" "$(ev "$HGATE" "$H/gate.sh")" 0
# --until-change keeps the older behaviour: the hold lapses on a new commit or edit
python3 "$B" hold 1 --reason "paused by the user" --until-change --project $hp >/dev/null 2>&1
check "--until-change is stored on the hold" "$(hjq 1 "t['held'].get('until_change')")" True
check "  held and unchanged: silent" "$(ev "$HGATE" "$H/gate.sh")" 0
echo more2 > "$hp/.claude/worktrees/agent-h1/more2.txt"
check "an edit in an --until-change worktree lapses the hold: flagged again" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'agent-h1 — uncommitted changes.*hold on row 1 lapsed' $T/out && ok "  and says why" || bad "  and says why (got: $(grep agent-h1 $T/out))"
python3 "$B" hold 1 --reason "paused by the user" --until-change --project $hp >/dev/null 2>&1
check "  re-holding it silences it again" "$(ev "$HGATE" "$H/gate.sh")" 0
git -C "$hp/.claude/worktrees/agent-h1" add -A; git -C "$hp/.claude/worktrees/agent-h1" commit -qm "more work 2"
check "a commit in an --until-change worktree lapses the hold" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q '2 commit(s) not in .*hold on row 1 lapsed' $T/out && ok "  and says so" || bad "  and says so (got: $(grep agent-h1 $T/out))"
python3 "$B" hold 1 --project $hp >/dev/null 2>&1
check "  re-held (default)" "$(ev "$HGATE" "$H/gate.sh")" 0
check "  a default hold has no until_change flag" "$(hjq 1 "'until_change' in t['held']")" False
# re-dispatch: the row goes running under a new worker; the hold is gone, the worktree is flagged again
python3 "$B" worker-start --id h1b --board 1 --branch worktree-agent-h1b --project $hp >/dev/null 2>&1
check "re-dispatch drops the hold from the row" "$(hjq 1 "'held' in t")" False
check "  and the old worktree is flagged again" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'agent-h1 —' $T/out && ok "  naming it" || bad "  naming it"
python3 "$B" hold 1 --project $hp >"$T/hout" 2>&1
check "  a running row cannot be held (its worker is out)" "$?" 1
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h1"; git -C "$hp" branch -D worktree-agent-h1 >/dev/null 2>&1
python3 "$B" update --project $hp --id 1 --state merged >/dev/null 2>&1
# release is explicit and immediate
hwt h4r; echo wip > "$hp/.claude/worktrees/agent-h4r/w.txt"
python3 "$B" update --project $hp --id 3 --state queued --worker h4r --branch worktree-agent-h4r >/dev/null
python3 "$B" hold 3 --reason "r" --project $hp >/dev/null 2>&1
check "setup: row 3 held, gate silent" "$(ev "$HGATE" "$H/gate.sh")" 0
python3 "$B" release 3 --project $hp >/dev/null 2>&1
check "release 3: flagged again" "$(ev "$HGATE" "$H/gate.sh")" 2
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h4r"; git -C "$hp" branch -D worktree-agent-h4r >/dev/null 2>&1
# #9: a superseded commit kept as reference, row blocked, waiting on the user's OK to delete
python3 "$B" update --project $hp --id 2 --state blocked --worker h2 --branch worktree-agent-h2 --owns "" --notes "superseded, kept as reference" >/dev/null 2>&1
hwt h2; echo x > "$hp/.claude/worktrees/agent-h2/x.txt"
git -C "$hp/.claude/worktrees/agent-h2" add -A; git -C "$hp/.claude/worktrees/agent-h2" commit -qm "superseded commit"
check "#9: a blocked row's worktree with an unmerged commit is flagged (no hold yet)" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q '1 commit(s) not in' $T/out && ok "  as '1 commit(s) not in <branch>'" || bad "  as '1 commit(s) not in <branch>'"
python3 "$B" hold 2 --reason "superseded; deleting the unmerged commit needs the user's OK" --project $hp >"$T/hout" 2>&1
check "  hold works on a blocked row: exit 0" "$?" 0
check "  the hold keeps the row blocked" "$(hjq 2 "t['state']")" blocked
for i in 1 2 3; do check "  #9 held: turn $i is silent" "$(ev "$HGATE" "$H/gate.sh")" 0; done
# the user said delete it -> the row is merged/removed; here: merged while the worktree is still there
python3 "$B" update --project $hp --id 2 --state merged >/dev/null 2>&1
check "  row merged while the worktree is still there: flagged again" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'agent-h2' $T/out && ok "  naming the worktree" || bad "  naming the worktree"
check "  and the hold is gone from the row" "$(hjq 2 "'held' in t")" False
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h2"; git -C "$hp" branch -D worktree-agent-h2 >/dev/null 2>&1

# #9 (b): the message has to be enough on its own. A fresh lead has not read the skill's
# hold paragraph; the gate names the row and prints a command it can run as written.
python3 "$B" update --project $hp --id 3 --state blocked --worker h5 --branch worktree-agent-h5 --owns "" --notes "superseded, kept as reference" >/dev/null 2>&1
hwt h5; echo x > "$hp/.claude/worktrees/agent-h5/x.txt"
git -C "$hp/.claude/worktrees/agent-h5" add -A; git -C "$hp/.claude/worktrees/agent-h5" commit -qm "superseded commit"
check "#9 message: the blocked row's worktree is flagged" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'agent-h5 — 1 commit(s) not in .* (board row 3)' $T/out && ok "  the line names the board row to hold" || bad "  the line names the board row to hold (got: $(grep agent-h5 $T/out))"
grep -qE 'python3 [^ ]*scripts/board\.py hold 3 --reason' $T/out && ok "  and prints a runnable command for that row, not a <row> placeholder" || bad "  runnable hold command for row 3 (got: $(grep 'board.py hold' $T/out))"
grep -qF 'queued, blocked or returned' $T/out && ok "  and says which rows can be held" || bad "  and says which rows can be held"
eval "$(grep -oE 'python3 [^ ]*scripts/board\.py hold 3 --reason' $T/out | head -1) \"kept for the user\" --project $hp" >/dev/null 2>&1
check "  running the printed command (reason added) silences the gate" "$(ev "$HGATE" "$H/gate.sh")" 0
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h5"; git -C "$hp" branch -D worktree-agent-h5 >/dev/null 2>&1
python3 "$B" update --project $hp --id 3 --state merged >/dev/null 2>&1

# check 3 scope (#9): only the plugin's own worktrees. A worktree the user made by hand
# for their own branch has no board row and cannot be held; flagging it fired every turn.
# Worker worktrees are always .claude/worktrees/agent-<id>, so nothing of a worker's escapes.
git -C "$hp" worktree add -q "$T/h4-own" -b my-own-branch 2>/dev/null
echo mine > "$T/h4-own/m.txt"; git -C "$T/h4-own" add -A; git -C "$T/h4-own" commit -qm "my own work"; echo wip > "$T/h4-own/wip.txt"
check "check 3: a hand-made worktree (own branch, no row), commit + dirty: not flagged" "$(ev "$HGATE" "$H/gate.sh")" 0
hwt h6; echo y > "$hp/.claude/worktrees/agent-h6/y.txt"
git -C "$hp/.claude/worktrees/agent-h6" add -A; git -C "$hp/.claude/worktrees/agent-h6" commit -qm "orphaned worker commit"
check "  an agent-* worktree with no board row is still flagged" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q 'agent-h6 — 1 commit(s) not in .* (no board row)' $T/out && ok "  naming it, with no row" || bad "  naming it, with no row (got: $(grep agent-h6 $T/out))"
grep -q 'h4-own' $T/out && bad "  and never the hand-made one" || ok "  and never the hand-made one"
git -C "$hp" worktree remove --force "$hp/.claude/worktrees/agent-h6"; git -C "$hp" branch -D worktree-agent-h6 >/dev/null 2>&1
# a worktree outside .claude/worktrees whose branch IS a board row's is the plugin's
python3 "$B" add --project $hp --task "own-branch row" --agent tl-sonnet-low --owns h4/own >/dev/null
hrow=$(python3 -c "import json;print(max(t['id'] for t in json.load(open('$HJ'))['tasks']))")
python3 "$B" update --project $hp --id $hrow --state blocked --worker ob1 --branch my-own-branch >/dev/null 2>&1
check "  a hand-made worktree whose branch a board row names is flagged" "$(ev "$HGATE" "$H/gate.sh")" 2
grep -q "h4-own — .*(board row $hrow)" $T/out && ok "  naming that row" || bad "  naming that row (got: $(grep h4-own $T/out))"
python3 "$B" hold $hrow --worktree "$T/h4-own" --reason "r" --project $hp >/dev/null 2>&1
check "  and holding that row silences it" "$(ev "$HGATE" "$H/gate.sh")" 0
git -C "$hp" worktree remove --force "$T/h4-own"; git -C "$hp" branch -D my-own-branch >/dev/null 2>&1
python3 "$B" update --project $hp --id $hrow --state merged >/dev/null 2>&1

echo "== T76: a real return reaps the background tasks the worker left open =="
t76d=$T/t76; mkdir -p "$t76d/tasks"
# Fake transcript: $1 file, $2 launched ids. Launches are "Command running in
# background" tool_results as the harness writes them; the NOTIFY / STOPPED /
# HANDBACK / PAUSE env vars select how (or whether) the worker closed them.
t76tr(){ python3 - "$t76d" "$@" <<'PY'
import json, os, sys
d, out, launch = sys.argv[1], sys.argv[2], sys.argv[3].split()
w = json.dumps
L = [w({"type": "user", "message": {"role": "user", "content": "<system-reminder>\nYour final report is delivered through SubagentHandback: call it when done.\n</system-reminder>\nboard: 1"}})]
for i in launch:
    L.append(w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "u" + i, "name": "Bash", "input": {"command": "sleep 300", "run_in_background": True}}]}}))
    L.append(w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "u" + i, "content": f"Command running in background with ID: {i}. Output is being written to: {d}/tasks/{i}.output. You will be notified when it completes."}]}, "toolUseResult": {"backgroundTaskId": i}}))
for i in filter(None, os.environ.get("NOTIFY", "").split()):
    L.append(w({"type": "attachment", "attachment": {"type": "queued_command", "prompt": f"<task-notification><task-id>{i}</task-id><summary>x</summary><status>completed</status></task-notification>"}}))
for i in filter(None, os.environ.get("STOPPED", "").split()):
    L.append(w({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "s" + i, "content": f"Successfully stopped task: {i} (sleep 300)"}]}}))
if os.environ.get("HANDBACK"):
    L.append(w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "h", "name": "SubagentHandback", "input": {"message": os.environ["HANDBACK"]}}]}}))
elif not os.environ.get("PAUSE"):
    L.append(w({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "h", "name": "SubagentHandback", "input": {"message": "done"}}]}}))
open(out, "w").write("\n".join(L) + "\n")
PY
}
T76PIDS=""
# t76p ID [sh]: a long sleep whose stdout/stderr is tasks/ID.output; "sh" adds a child.
t76p(){ if [ "${2:-}" = sh ]; then ( exec sh -c 'sleep 300 & wait' ) >"$t76d/tasks/$1.output" 2>&1 & else ( exec sleep 300 ) >"$t76d/tasks/$1.output" 2>&1 & fi
  T76PIDS="$T76PIDS $!"; eval "p_$1=$!"; }
t76up(){ kill -0 "$1" 2>/dev/null && ! grep -q '^State:.Z' /proc/$1/status 2>/dev/null && echo up || echo down; }
T76STOP(){ echo '{"hook_event_name":"SubagentStop","cwd":"'$tp'","agent_type":"teamlead:tl-sonnet-low","agent_id":"'$1'","agent_transcript_path":"'$2'","transcript_path":"'$T/t65-final.jsonl'","last_assistant_message":"'$3'"}'; }
t76p tka sh; t76p tkb; t76p tkc; t76p tkd; t76p tke; t76p tkf
sleep 0.4
kid=$(pgrep -P "$p_tka" | head -1)
T76PIDS="$T76PIDS $kid"
check "  setup: the sh task has a child holding its output" "$([ -n "$kid" ] && echo y || echo n)" y
# tkb: terminal notification; tkc: named in last_assistant_message; tkd: named only
# in the Handback input; tke: TaskStop'd by the worker; tka, tkf: genuinely open.
HANDBACK="leaving tkd running as asked" NOTIFY="tkb" STOPPED="tke" t76tr $T/t76-ret.jsonl "tka tkb tkc tkd tke tkf"
check "return with open tasks: exit 0" "$(ev "$(T76STOP tw76 $T/t76-ret.jsonl 'kept tkc running on request')" "$H/record.sh")" 0
check "  open task tka killed" "$(t76up $p_tka)" down
check "  and its child" "$(t76up $kid)" down
check "  open task tkf killed" "$(t76up $p_tkf)" down
check "  task with a terminal notification (tkb) left alone" "$(t76up $p_tkb)" up
check "  task named in last_assistant_message (tkc) left alone" "$(t76up $p_tkc)" up
check "  task named in the Handback input (tkd) left alone" "$(t76up $p_tkd)" up
check "  task the worker TaskStop'd (tke) left alone" "$(t76up $p_tke)" up
grep -qE '  reap      agent=teamlead:tl-sonnet-low  id=tw76  tasks=tka,tkf  pids=3$' $LT \
  && ok "  reap line: tasks=tka,tkf pids=3" || bad "  reap line: tasks=tka,tkf pids=3 ($(grep '  reap ' $LT))"
grep -q '  return .*id=tw76' $LT && ok "  return line still written" || bad "  return line still written"
# pause: nothing killed, the open ids are listed
t76p tkg; sleep 0.2
PAUSE=1 t76tr $T/t76-pause.jsonl "tkg"
check "pause stop with an open task: exit 0" "$(ev "$(T76STOP tw77 $T/t76-pause.jsonl 'waiting')" "$H/record.sh")" 0
check "  paused worker's task not killed" "$(t76up $p_tkg)" up
grep -qE '  pause     agent=teamlead:tl-sonnet-low  id=tw77  open=tkg$' $LT && ok "  pause line carries open=tkg" || bad "  pause line carries open=tkg ($(grep 'id=tw77' $LT))"
grep -q '  reap .*id=tw77' $LT && bad "  no reap line on a pause" || ok "  no reap line on a pause"
# unparseable transcript: fail safe
printf 'Command running in background with ID: tkg. Output is being written to: %s/tasks/tkg.output.\n{{{ not json\n\377\376\n' "$t76d" > $T/t76-bad.jsonl
check "unparseable transcript: exit 0" "$(ev "$(T76STOP tw78 $T/t76-bad.jsonl 'done')" "$H/record.sh")" 0
check "  nothing killed" "$(t76up $p_tkg)" up
grep -q '  reap .*id=tw78' $LT && bad "  no reap line" || ok "  no reap line"
grep -q '  return .*id=tw78' $LT && ok "  return still recorded" || bad "  return still recorded"
# the same task, once the worker really returns, is reaped
t76tr $T/t76-ret2.jsonl "tkg"
ev "$(T76STOP tw79 $T/t76-ret2.jsonl 'done')" "$H/record.sh" >/dev/null
check "  a real return does reap it" "$(t76up $p_tkg)" down
kill $T76PIDS 2>/dev/null; kill -9 $T76PIDS 2>/dev/null; wait 2>/dev/null

echo "== SKILL.md: auto-mode merge/cleanup guidance (#3) =="
grep -q '^## Merging and cleanup under auto mode' "$SK" && ok "  section present" || bad "  section present"
grep -q 'Permission refusal → stop, tell the user, offer the rule; never route around it' "$SK" && ok "  general refusal rule" || bad "  general refusal rule"
grep -q 'Bash(bash \*/scripts/worker-cleanup.sh \*)' "$SK" && ok "  names the worker-cleanup allow rule" || bad "  names the worker-cleanup allow rule"
grep -q 'tells a worker to merge' <(tr '\n' ' ' < "$SK" | sed 's/  */ /g') && ok "  briefs never tell a worker to merge" || bad "  briefs never tell a worker to merge"
[ -f "$CLAUDE_PLUGIN_ROOT/docs/permissions.md" ] && ok "  docs/permissions.md exists" || bad "  docs/permissions.md exists"

echo "== worker-cleanup.sh: leftover processes, worktree, branch =="
WC="$CLAUDE_PLUGIN_ROOT/scripts/worker-cleanup.sh"
wm="$T/wc"; mkdir -p "$wm"
git -C "$wm" init -q; git -C "$wm" config user.email t@t.t; git -C "$wm" config user.name t
echo a > "$wm/a"; git -C "$wm" add -A >/dev/null; git -C "$wm" commit -qm init
for n in merged dirty unmerged; do git -C "$wm" worktree add -q -b "agent-$n" "$T/wc-$n"; done
echo w > "$T/wc-merged/w"; git -C "$T/wc-merged" add -A >/dev/null; git -C "$T/wc-merged" commit -qm work
git -C "$wm" merge -q --no-edit agent-merged >/dev/null 2>&1
echo w > "$T/wc-unmerged/u"; git -C "$T/wc-unmerged" add -A >/dev/null; git -C "$T/wc-unmerged" commit -qm work
echo x > "$T/wc-dirty/untracked"
mkdir -p "$T/wc-merged/sub"
(cd "$T/wc-merged/sub" && exec sleep 300) >/dev/null 2>&1 & inpid=$!
(cd "$T" && exec sleep 300) >/dev/null 2>&1 & outpid=$!
sleep 0.3
check "  /proc cwd sees the sleep inside the worktree" "$(readlink /proc/$inpid/cwd)" "$T/wc-merged/sub"
bash "$WC" "$T/wc-merged" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  clean merged worktree: exit 0" "$rc" 0
kill -0 "$inpid" 2>/dev/null && bad "  process inside the worktree was killed" || ok "  process inside the worktree was killed"
kill -0 "$outpid" 2>/dev/null && ok "  process outside the worktree left alone" || bad "  process outside the worktree left alone"
grep -q "pid $inpid" "$T/wcout" && ok "  output names the killed pid" || bad "  output names the killed pid"
[ -d "$T/wc-merged" ] && bad "  worktree directory removed" || ok "  worktree directory removed"
git -C "$wm" rev-parse --verify -q agent-merged >/dev/null && bad "  merged branch deleted" || ok "  merged branch deleted"
kill "$outpid" 2>/dev/null; wait 2>/dev/null
bash "$WC" "$T/wc-dirty" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  dirty worktree: refused (exit 1)" "$rc" 1
[ -f "$T/wc-dirty/untracked" ] && ok "  dirty worktree left intact" || bad "  dirty worktree left intact"
git -C "$wm" rev-parse --verify -q agent-dirty >/dev/null && ok "  dirty worktree's branch kept" || bad "  dirty worktree's branch kept"
bash "$WC" "$T/wc-unmerged" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  unmerged branch: refused (exit 1)" "$rc" 1
git -C "$wm" rev-parse --verify -q agent-unmerged >/dev/null && ok "  unmerged branch kept" || bad "  unmerged branch kept"
bash "$WC" "$wm" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  main checkout: refused (exit 1)" "$rc" 1

# git locks: only a stale "claude agent" lock is lifted; a live one or a foreign one refuses.
mypid=$$; mystart=$(sed 's/^.*) //' /proc/$mypid/stat | awk '{print $20}')
true & deadpid=$!; wait $deadpid 2>/dev/null
mkdir -p "$wm/.claude/teamlead/.state"
printf '%s  start     agent=teamlead:tl-sonnet-high  id=lkrun\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$wm/.claude/teamlead/.state/events.log"
printf '%s  start     agent=teamlead:tl-sonnet-high  id=lkpause\n%s  pause     agent=teamlead:tl-sonnet-high  id=lkpause\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$wm/.claude/teamlead/.state/events.log"
git -C "$wm" worktree add -q -b agent-lkpause "$T/wc-lkpause"
git -C "$wm" worktree lock --reason "claude agent agent-lkpause (pid $mypid start $mystart)" "$T/wc-lkpause"
bash "$WC" "$T/wc-lkpause" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  agent lock, pid alive, agent outstanding but last event is pause: removed" "$rc" 0
[ -d "$T/wc-lkpause" ] && bad "  ... worktree gone" || ok "  ... worktree gone"
for n in dead idle run foreign; do git -C "$wm" worktree add -q -b "agent-lk$n" "$T/wc-lk$n"; done
git -C "$wm" worktree lock --reason "claude agent agent-lkdead (pid $deadpid start 1)" "$T/wc-lkdead"
git -C "$wm" worktree lock --reason "claude agent agent-lkidle (pid $mypid start $mystart)" "$T/wc-lkidle"
git -C "$wm" worktree lock --reason "claude agent agent-lkrun (pid $mypid start $mystart)" "$T/wc-lkrun"
git -C "$wm" worktree lock --reason "my own lock, hands off" "$T/wc-lkforeign"
bash "$WC" "$T/wc-lkdead" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  stale agent lock, dead pid: removed (exit 0)" "$rc" 0
grep -q "unlocked stale agent lock (claude agent agent-lkdead" "$T/wcout" && ok "  ... says it unlocked the stale lock" || bad "  ... says it unlocked the stale lock"
[ -d "$T/wc-lkdead" ] && bad "  ... worktree gone" || ok "  ... worktree gone"
bash "$WC" "$T/wc-lkidle" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  agent lock, pid alive but agent not working in the ledger: removed" "$rc" 0
[ -d "$T/wc-lkidle" ] && bad "  ... worktree gone" || ok "  ... worktree gone"
bash "$WC" "$T/wc-lkrun" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  agent lock, pid alive, agent working in the ledger: refused" "$rc" 1
grep -q "still running" "$T/wcout" && ok "  ... says the worker is still running" || bad "  ... says the worker is still running"
[ -d "$T/wc-lkrun" ] && ok "  ... worktree kept" || bad "  ... worktree kept"
git -C "$wm" worktree list --porcelain | grep -q "^locked claude agent agent-lkrun" && ok "  ... lock kept" || bad "  ... lock kept"
bash "$WC" "$T/wc-lkforeign" --project "$wm" >"$T/wcout" 2>&1; rc=$?
check "  foreign lock reason: refused" "$rc" 1
grep -q "my own lock, hands off" "$T/wcout" && ok "  ... prints the lock reason" || bad "  ... prints the lock reason"
[ -d "$T/wc-lkforeign" ] && git -C "$wm" worktree list --porcelain | grep -q "^locked my own lock" && ok "  ... worktree and lock kept" || bad "  ... worktree and lock kept"

echo "== plugin-bug marker: a worker's 🐞 PLUGIN BUG report reaches the lead via mode.sh =="
pbp=$T/pbug; mkdir -p $pbp/.claude/teamlead/.state; : > $pbp/.claude/teamlead/.state/active
ev '{"hook_event_name":"SubagentStart","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"pb1"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"pb1","last_assistant_message":"🐞 PLUGIN BUG: widget breaks\n   repro: x\n   at: hooks/a.sh:1\nrest"}' "$H/record.sh" >/dev/null
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/pbout" 2>&1
grep -q 'plugin bug (🐞 PLUGIN BUG: widget breaks)' "$T/pbout" && ok "  marked report: reminder with the first line" || bad "  marked report: reminder with the first line"
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/pbout" 2>&1
grep -q 'plugin bug' "$T/pbout" && bad "  reminder repeated on the next prompt" || ok "  reminder shown once"
ev '{"hook_event_name":"SubagentStart","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"pb2"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"pb2","last_assistant_message":"all done, no bugs"}' "$H/record.sh" >/dev/null
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/pbout" 2>&1
grep -q 'plugin bug' "$T/pbout" && bad "  unmarked report: no reminder" || ok "  unmarked report: no reminder"
# the report may live only in the SubagentHandback input, not in last_assistant_message
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"🐞 PLUGIN BUG: from handback\nrest"}}]}}' > "$T/pbtr"
ev '{"hook_event_name":"SubagentStart","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"pb3"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"pb3","agent_transcript_path":"'$T'/pbtr","last_assistant_message":""}' "$H/record.sh" >/dev/null
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/pbout" 2>&1
grep -q 'from handback' "$T/pbout" && ok "  marker found in the SubagentHandback input" || bad "  marker found in the SubagentHandback input"

echo "== scope-request marker: a blocked worker's SCOPE REQUEST hand-back reaches the lead =="
ev '{"hook_event_name":"SubagentStart","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"sr1"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"sr1","last_assistant_message":"SCOPE REQUEST: docs/extra.md\nwhy: needs a doc\nrow: 7\nrest"}' "$H/record.sh" >/dev/null
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/srout" 2>&1
grep -q 'asked for more scope (SCOPE REQUEST: docs/extra.md)' "$T/srout" && ok "  marked report: reminder with the requested path" || bad "  marked report: reminder with the requested path"
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/srout" 2>&1
grep -q 'asked for more scope' "$T/srout" && bad "  scope reminder repeated" || ok "  scope reminder shown once"
ev '{"hook_event_name":"SubagentStart","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"sr2"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"sr2","last_assistant_message":"done; I did not need a SCOPE REQUEST: nothing"}' "$H/record.sh" >/dev/null
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/srout" 2>&1
grep -q 'asked for more scope' "$T/srout" && bad "  mid-line mention: no reminder" || ok "  mid-line mention: no reminder"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"SCOPE REQUEST: src/x/**\nwhy: y\nrow: 3"}}]}}' > "$T/srtr"
ev '{"hook_event_name":"SubagentStart","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"sr3"}' "$H/record.sh" >/dev/null
ev '{"hook_event_name":"SubagentStop","cwd":"'$pbp'","agent_type":"tl-sonnet-high","agent_id":"sr3","agent_transcript_path":"'$T'/srtr","last_assistant_message":""}' "$H/record.sh" >/dev/null
echo '{"hook_event_name":"UserPromptSubmit","cwd":"'$pbp'","prompt":"hi"}' | "$H/mode.sh" > "$T/srout" 2>&1
grep -q 'SCOPE REQUEST: src/x/\*\*' "$T/srout" && ok "  marker found in the SubagentHandback input" || bad "  marker found in the SubagentHandback input"

echo "== stale-base guard: SubagentStart tells a worker to fast-forward when local is ahead of origin =="
sbo="$T/sb-origin.git"; git init -q --bare "$sbo"
sbs="$T/sb-seed"; git init -q "$sbs"; git -C "$sbs" config user.email t@t.t; git -C "$sbs" config user.name t
echo one > "$sbs/f.txt"; git -C "$sbs" add -A >/dev/null; git -C "$sbs" commit -qm one
git -C "$sbs" push -q "$sbo" HEAD:refs/heads/main 2>/dev/null; git -C "$sbo" symbolic-ref HEAD refs/heads/main
sbp="$T/sb"; git clone -q "$sbo" "$sbp" 2>/dev/null; git -C "$sbp" config user.email t@t.t; git -C "$sbp" config user.name t
mkdir -p "$sbp/.claude/teamlead/.state"; : > "$sbp/.claude/teamlead/.state/active"
sbev() { printf '{"hook_event_name":"SubagentStart","cwd":"%s","agent_type":"%s","agent_id":"%s"}' "$1" "${2:-teamlead:tl-sonnet-high}" "${3:-sb1}" | "$H/record.sh" >"$T/sbout" 2>"$T/sberr"; echo $?; }
check "local equal to origin: exit 0" "$(sbev "$sbp")" 0
[ ! -s "$T/sbout" ] && ok "  and prints nothing" || bad "  and prints nothing"
echo two > "$sbp/f.txt"; git -C "$sbp" commit -qam two
sbsha=$(git -C "$sbp" rev-parse HEAD)
check "local ahead of origin: exit 0" "$(sbev "$sbp")" 0
jq -e . "$T/sbout" >/dev/null 2>&1 && ok "  output is valid JSON" || bad "  output is valid JSON"
check "  hookEventName is SubagentStart" "$(jq -r .hookSpecificOutput.hookEventName "$T/sbout" 2>/dev/null)" SubagentStart
sbctx=$(jq -r .hookSpecificOutput.additionalContext "$T/sbout" 2>/dev/null)
case "$sbctx" in *"git merge-base --is-ancestor $sbsha HEAD || git merge --ff-only $sbsha"*) ok "  context carries the sha and the exact command";; *) bad "  context carries the sha and the exact command";; esac
[ "$(printf '%s\n' "$sbctx" | wc -l)" -le 2 ] && ok "  context is at most two lines" || bad "  context is at most two lines"
check "  line 2: the stop instruction is for a fresh worktree; a worker with its own commits skips the command and carries on" "$(printf '%s\n' "$sbctx" | sed -n 2p | grep -c 'in a fresh worktree.*stop and report.*already has its own commits on its branch skips the command and carries on')" "1"
check "  line 1 keeps the command text unchanged and has no stop instruction of its own" "$(printf '%s\n' "$sbctx" | sed -n 1p | grep -c 'stop and report')/$(printf '%s\n' "$sbctx" | sed -n 1p | grep -c "Before anything else run: git merge-base --is-ancestor $sbsha HEAD || git merge --ff-only $sbsha\$")" "0/1"
check "non-tl agent: exit 0" "$(sbev "$sbp" general-purpose)" 0
[ ! -s "$T/sbout" ] && ok "  and prints nothing" || bad "  and prints nothing"
# Real stale worktree: branched from origin/main (what baseRef=fresh does), then run the printed command.
sbw="$T/sb-wt"; git -C "$sbp" worktree add -q -b worktree-agent-sb1 "$sbw" origin/main 2>/dev/null
[ "$(git -C "$sbw" rev-parse HEAD)" != "$sbsha" ] && ok "  fixture: the worktree starts stale" || bad "  fixture: the worktree starts stale"
(cd "$sbw" && eval "$(printf '%s\n' "$sbctx" | sed -n 's/.*run: //p')") >/dev/null 2>&1
check "  printed command fast-forwards the stale worktree" "$(git -C "$sbw" rev-parse HEAD)" "$sbsha"
(cd "$sbw" && eval "$(printf '%s\n' "$sbctx" | sed -n 's/.*run: //p')") >/dev/null 2>&1; rc=$?
check "  and is idempotent (ancestor check passes at once)" "$rc" 0
# The existing behind-main check flags that stale-base branch once the worker returns, if not fast-forwarded.
sbw2="$T/sb-wt2"; git -C "$sbp" worktree add -q -b worktree-agent-sb2 "$sbw2" origin/main 2>/dev/null
echo w > "$sbw2/w.txt"; git -C "$sbw2" add -A >/dev/null; git -C "$sbw2" -c user.email=t@t.t -c user.name=t commit -qm work
printf '.claude/teamlead/.state/\n.claude/teamlead/board.md\n' > "$sbp/.gitignore"; git -C "$sbp" add .gitignore; git -C "$sbp" commit -qm ignore
python3 "$B" add --project "$sbp" --task w --agent tl-sonnet-high --owns w.txt >/dev/null
python3 "$B" update --project "$sbp" --id 1 --state returned --branch worktree-agent-sb2 >/dev/null
python3 "$B" check --project "$sbp" >"$T/sbchk" 2>&1; rc=$?
check "board check fails on a stale-base returned branch" "$rc" 1
grep -q "branch worktree-agent-sb2 is behind .* — rebase before merging" "$T/sbchk" && ok "  with the existing behind-main message" || bad "  with the existing behind-main message"
# After the guard's fast-forward, the same branch is not flagged.
sbw3="$T/sb-wt3"; git -C "$sbp" worktree add -q -b worktree-agent-sb3 "$sbw3" origin/main 2>/dev/null
sbsha2=$(git -C "$sbp" rev-parse HEAD); git -C "$sbw3" merge -q --ff-only "$sbsha2" 2>/dev/null
echo w3 > "$sbw3/w3.txt"; git -C "$sbw3" add -A >/dev/null; git -C "$sbw3" -c user.email=t@t.t -c user.name=t commit -qm work3
python3 "$B" update --project "$sbp" --id 1 --branch worktree-agent-sb3 >/dev/null
python3 "$B" check --project "$sbp" >"$T/sbchk" 2>&1; rc=$?
check "  fast-forwarded branch passes the same check" "$rc" 0
# No remote / no origin/HEAD: nothing to do.
sbn="$T/sb-noremote"; git init -q "$sbn"; git -C "$sbn" config user.email t@t.t; git -C "$sbn" config user.name t
echo x > "$sbn/x"; git -C "$sbn" add -A >/dev/null; git -C "$sbn" commit -qm x
mkdir -p "$sbn/.claude/teamlead/.state"; : > "$sbn/.claude/teamlead/.state/active"
check "no remote: exit 0" "$(sbev "$sbn")" 0
[ ! -s "$T/sbout" ] && ok "  and prints nothing" || bad "  and prints nothing"
git -C "$sbn" remote add origin "$sbo"; git -C "$sbn" config remote.origin.followRemoteHEAD never   # git >= 2.48 would otherwise create origin/HEAD on fetch
git -C "$sbn" fetch -q origin 2>/dev/null
check "remote but no origin/HEAD: exit 0" "$(sbev "$sbn")" 0
[ ! -s "$T/sbout" ] && ok "  and prints nothing" || bad "  and prints nothing"
# git failure: a broken HEAD must stay silent and exit 0.
sbb="$T/sb-broken"; git clone -q "$sbo" "$sbb" 2>/dev/null
mkdir -p "$sbb/.claude/teamlead/.state"; : > "$sbb/.claude/teamlead/.state/active"
echo 'ref: refs/heads/does-not-exist-xyz' > "$sbb/.git/HEAD"; rm -f "$sbb/.git/refs/heads/main"
check "git failure (unborn HEAD): exit 0" "$(sbev "$sbb")" 0
[ ! -s "$T/sbout" ] && ok "  and prints nothing" || bad "  and prints nothing"
echo garbage > "$sbb/.git/HEAD"
check "git failure (corrupt HEAD): exit 0" "$(sbev "$sbb")" 0
[ ! -s "$T/sbout" ] && ok "  and prints nothing" || bad "  and prints nothing"

echo "== superdoc map: link graph (map.py, #19) =="
MAP="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/map.py"
mapin() { local d=$1; shift; (cd "$d" && python3 "$MAP" "$@"); }   # run map.py from inside a fixture dir
MP=$T/mpf; gfix $MP; mkdir -p $MP/superdoc/meta $MP/superdoc/features/sub
printf '# P\n<!-- superdoc:start v4 -->\nHub: [docs](superdoc/README.md); not a link: `[x](nope.md)`\n@superdoc/meta/TERMINOLOGY.md\n<!-- superdoc:end -->\n' > $MP/CLAUDE.md
printf '# Index\n\n- [a](features/a.md)\n- [b](features/b.md)\n- [gone](features/gone.md)\n- [deep](features/sub/deep.md)\n' > $MP/superdoc/README.md
cat > $MP/superdoc/features/a.md <<'EOF'
# A
## Dup
## Dup
## With: Punct & Stuff!
<a name="expl"></a>
Good: [b](b.md) [sec](b.md#bsec) [dup1](#dup-1) [dup0](#dup) [slug](#with-punct--stuff) [expl](#expl) [up](../README.md#index)
Bad anchor: [bad](b.md#nosuch)
Ignored: [ext](https://example.org/x.md) [mail](mailto:a@example.org) `[code](ghost2.md)`
```
[fenced](ghost.md)
```
EOF
printf '# B\n## Bsec\n' > $MP/superdoc/features/b.md
printf '# O\nnothing links here\n' > $MP/superdoc/features/orphan.md
printf '# T\n' > $MP/superdoc/meta/TERMINOLOGY.md
printf '# Deep\n[a](../a.md)\n' > $MP/superdoc/features/sub/deep.md
out_m=$(mapin $MP); rc_m=$?
check "map: exit 1 with dangling links" "$rc_m" "1"
check "map: a link to a missing file is DANGLING (file missing), with path:line and the resolved target" "$(printf '%s\n' "$out_m" | grep -c '^DANGLING  superdoc/README.md:5 -> superdoc/features/gone.md  (file missing)$')" "1"
check "map: a link to a heading that is not there is DANGLING (anchor missing)" "$(printf '%s\n' "$out_m" | grep -c '^DANGLING  superdoc/features/a.md:7 -> superdoc/features/b.md#nosuch  (anchor missing)$')" "1"
check "map: exactly those two are dangling (valid link, dup slugs -1, punctuation slug, explicit <a name>, external, mailto, code fence and code span are not)" "$(printf '%s\n' "$out_m" | grep -c '^DANGLING')" "2"
check "map: a page nothing links to is an ORPHAN" "$(printf '%s\n' "$out_m" | grep '^ORPHAN' | tr '\n' '|')" "ORPHAN    superdoc/features/orphan.md  (no inbound links)|"
check "map: summary line counts pages, links, dangling and orphans, and says FAIL" "$(printf '%s\n' "$out_m" | tail -n 1)" "FAIL      7 pages, 14 links, 2 dangling, 1 orphan"
check "map: a README index link, a CLAUDE.md link and an @-ref count as inbound (b.md, README.md, TERMINOLOGY.md are not orphans; CLAUDE.md never is)" "$(printf '%s\n' "$out_m" | grep -c '^ORPHAN.*\(b.md\|README.md\|TERMINOLOGY.md\|CLAUDE.md\)')" "0"
check "map: the structure lists each page per folder with out: and in:" "$(printf '%s\n' "$out_m" | grep -c '^superdoc/features/$')/$(printf '%s\n' "$out_m" | grep -c '^  b.md  out: -  in: superdoc/README.md, superdoc/features/a.md$')" "1/1"
out_c=$(mapin $MP --check); rc_c=$?
check "map --check: findings and summary only (no structure), same exit code" "$(printf '%s\n' "$out_c" | grep -c '  out: ')/$(printf '%s\n' "$out_c" | wc -l | tr -d ' ')/$rc_c" "0/4/1"
check "map: works from a subdirectory of the repo" "$(cd $MP/superdoc/features/sub && python3 "$MAP" --check | tail -n 1)" "FAIL      7 pages, 14 links, 2 dangling, 1 orphan"
check "map --links-to: path:line -> target of each link that points at the page, a self-link is not one; the page may be given repo-, doc- or cwd-relative" "$(mapin $MP --links-to superdoc/features/b.md | tr '\n' '|')/$(mapin $MP --links-to features/b.md | wc -l | tr -d ' ')/$(cd $MP/superdoc/features && python3 "$MAP" --links-to b.md | wc -l | tr -d ' ')" "superdoc/README.md:4 -> superdoc/features/b.md|superdoc/features/a.md:6 -> superdoc/features/b.md|superdoc/features/a.md:6 -> superdoc/features/b.md#bsec|superdoc/features/a.md:7 -> superdoc/features/b.md#nosuch  (anchor missing)|/4/4"
check "map --links-from: every link the page contains, path:line form; a missing target is marked" "$(mapin $MP --links-from superdoc/README.md | tr '\n' '|')" "superdoc/README.md:3 -> superdoc/features/a.md|superdoc/README.md:4 -> superdoc/features/b.md|superdoc/README.md:5 -> superdoc/features/gone.md  (file missing)|superdoc/README.md:6 -> superdoc/features/sub/deep.md|"
check "map --links-to: a page nothing links to prints nothing, exit 0" "$(mapin $MP --links-to superdoc/features/orphan.md; echo rc=$?)" "rc=0"
check "map --links-to: the @-ref of CLAUDE.md is listed as such" "$(mapin $MP --links-to superdoc/meta/TERMINOLOGY.md)" "CLAUDE.md:4 -> superdoc/meta/TERMINOLOGY.md  (@-ref)"
mapin $MP --bogus >/dev/null 2>&1; check "map: an unknown flag is exit 2" "$?" "2"
# fix the two dangling links: exit 0, OK; the orphan alone stays a warning
sed -i '/gone.md/d' $MP/superdoc/README.md; sed -i '/Bad anchor/d' $MP/superdoc/features/a.md
out_o=$(mapin $MP --check); rc_o=$?
check "map: only an orphan left is a warning: exit 0, OK line names it" "$rc_o/$(printf '%s\n' "$out_o" | tail -n 1)" "0/OK        7 pages, 12 links, 0 dangling, 1 orphan"
printf -- '- [o](features/orphan.md)\n' >> $MP/superdoc/README.md
check "map: linking the orphan from the README index clears it" "$(mapin $MP --check | tail -n 2 | tr '\n' '|')" "OK        7 pages, 13 links, 0 dangling, 0 orphan|"
printf 'x\n' > $MP/superdoc/features/with\ space.md; printf -- '- [sp](features/sub/sp.md)\n' >> $MP/superdoc/README.md; printf '[s](../with%%20space.md) [t](<../with space.md>)\n' > $MP/superdoc/features/sub/sp.md
check "map: percent-encoded and <angle> targets with spaces resolve (no dangling)" "$(mapin $MP --check | grep -c '^DANGLING')" "0"
NS=$T/mpn; mkdir -p $NS; (cd $NS && git init -q); printf '# P\n' > $NS/CLAUDE.md
check "map: a project with no superdoc: one note, exit 0" "$(mapin $NS; echo rc=$?)" "map: no superdoc in this project, nothing to map
rc=0"
check "map: outside a git repo with no superdoc: the same, exit 0" "$(mkdir -p $T/mpnogit && cd $T/mpnogit && python3 "$MAP"; echo rc=$?)" "map: no superdoc in this project, nothing to map
rc=0"
# a linked worktree: the repo root is the worktree's own
(cd $MP && git add -A && git commit -qm base && git worktree add -q -b mpwt $T/mpwt 2>/dev/null)
check "map: a linked worktree maps its own tree" "$(mapin $T/mpwt --check | tail -n 1)" "OK        9 pages, 16 links, 0 dangling, 0 orphan"
# #20: the playbook's Part 5 CLAUDE.md block must link the hub for real (a code span is blanked by map.py -> ORPHAN)
HUB=$T/mph; gfix $HUB; mkdir -p $HUB/superdoc/architecture $HUB/superdoc/features $HUB/superdoc/ui
sed -n '/^<!-- superdoc:start v4 -->$/,/^<!-- superdoc:end -->$/p' "$PB" | sed '/^<!-- superdoc:end -->$/q' | sed 's/<capability>/features/g' > $HUB/CLAUDE.md
printf '# Hub\n' > $HUB/superdoc/architecture/overview.md; printf '# F\n' > $HUB/superdoc/features/a.md
printf '# S\n' > $HUB/superdoc/ui/STYLING-GUIDE.md; printf '# R\n' > $HUB/superdoc/README.md
mkdir -p $HUB/superdoc/meta $HUB/superdoc/claude-instructions; printf '# T\n' > $HUB/superdoc/meta/TERMINOLOGY.md
printf '# D\n' > $HUB/superdoc/claude-instructions/documentation.md; printf '# V\n' > $HUB/superdoc/claude-instructions/documentation-version-policy.md
out_h=$(mapin $HUB --check); rc_h=$?
check "map: the Part 5 template links the hub (no ORPHAN for overview.md), no dangling, exit 0 (#20)" "$rc_h/$(printf '%s\n' "$out_h" | grep -c 'overview.md')/$(printf '%s\n' "$out_h" | grep -c '^DANGLING')" "0/0/0"
check "map: the Part 5 template block was extracted (guard against a vacuous pass)" "$(grep -c 'superdoc/architecture/overview.md' $HUB/CLAUDE.md)" "1"

echo "== superdoc map: gate shows dangling links once (gate.sh check 8, #19) =="
GM=$T/mpg; sgmk $GM
printf '# I\n[a](features/a.md)\n[old](features/old-gone.md)\n' > $GM/superdoc/README.md; (cd $GM && git add superdoc && git commit -qm readme)
sgstop $GM >/dev/null
sgmerge $GM bmp1 superdoc/features/c.md '# C\n[a](a.md)\n[ghost](ghost.md)\n[sec](a.md#nosuch)\n'
rc_mg=$(sgstop $GM)
check "gate map: a merge that brings dangling links blocks and names each (file:line -> target, reason) once" "$rc_mg/$(grep -c '^ *DANGLING  superdoc/features/c.md:3 -> superdoc/features/ghost.md  (file missing)$' $T/sgout)/$(grep -c '^ *DANGLING  superdoc/features/c.md:4 -> superdoc/features/a.md#nosuch  (anchor missing)$' $T/sgout)" "2/1/1"
check "  old debt in a file the merge did not touch (README -> old-gone.md) is not shown" "$(grep -c 'old-gone' $T/sgout)" "0"
check "  it fires ONCE: the next Stop is silent" "$(sgstop $GM)/$(cat $T/sgout | wc -c | tr -d ' ')" "0/0"
(cd $GM && git checkout -qb bmp2 && printf '# I\n[a](features/a.md)\n' > superdoc/README.md && git rm -q superdoc/features/a.md && git commit -qm del --no-verify && git checkout -q master && git merge -q --no-ff -m m-bmp2 bmp2)
rc_md=$(sgstop $GM)
check "gate map: deleting a page shows the links that now dangle, in files the merge did not touch (c.md, README.md)" "$rc_md/$(grep -c '^ *DANGLING  superdoc/README.md:2 -> superdoc/features/a.md  (file missing)$' $T/sgout)/$(grep -c '^ *DANGLING  superdoc/features/c.md:2 -> superdoc/features/a.md  (file missing)$' $T/sgout)" "2/1/1"
check "  and fires once" "$(sgstop $GM)" "0"
lk=(); for i in $(seq 1 60); do lk+=("[l$i](nofile$i.md)\n"); done
sgmerge $GM bmp3 superdoc/features/many.md "# M\n$(printf '%s' "${lk[@]}")"
rc_mc=$(sgstop $GM)
check "gate map: the DANGLING output is capped at 40 lines, with how many more" "$rc_mc/$(grep -c '^ *DANGLING  superdoc/features/many.md' $T/sgout)/$(grep -c 'and 20 more line(s) not shown' $T/sgout)" "2/40/1"
(cd $GM && printf '# C\nclean\n' > superdoc/features/c.md && printf '# M\nclean\n' > superdoc/features/many.md && printf '# I\n' > superdoc/README.md && git add superdoc && git commit -qm clean --no-verify)
sgstop $GM >/dev/null
sgmerge $GM bmp4 superdoc/features/ok.md '# Ok\n[c](c.md)\n' superdoc/README.md '# I\n[c](features/c.md)\n[m](features/many.md)\n[ok](features/ok.md)\n'
check "gate map: a merge with no dangling link is silent" "$(sgstop $GM)/$(cat $T/sgout | wc -c | tr -d ' ')" "0/0"

echo "== test.sh never writes a real project's board, wherever TMPDIR points (2026-11-09 incident) =="
# A worker ran ./test.sh with TMPDIR inside its worktree; the fixtures then lived
# under the real project and hooks/board.py resolved them up to its real board.
# Model that project, run test.sh's own temp-root selection with TMPDIR (and the
# identity env) pointing into it, and require the board and log untouched. The
# probe mode stops right after the root is chosen, so this stays fast; the old
# test.sh ignored it, ran the whole suite there, and rewrote both files.
IP=$T/inc; mkdir -p $IP
(cd $IP && git init -q && git config user.email t@t.t && git config user.name t && echo x > f && git add -A \
  && git commit -qm init && mkdir -p .claude/teamlead/.state && : > .claude/teamlead/.state/active \
  && git worktree add -q .claude/worktrees/agent-x -b wx)
IW=$IP/.claude/worktrees/agent-x; mkdir -p $IW/.tl-scratch/tmp
printf '%s\n' '{"next_id":2,"tasks":[{"id":1,"task":"real work","agent":"tl-sonnet-high","owns":["a"],"state":"running","worker":"real1"}]}' > $IP/.claude/teamlead/.state/board.json
printf '%s\n' '2026-01-01T00:00:00Z  start     agent=teamlead:tl-sonnet-high  id=real1' > $IP/.claude/teamlead/.state/events.log
incsnap(){ cksum < $IP/.claude/teamlead/.state/board.json; cksum < $IP/.claude/teamlead/.state/events.log; ls -A $IP/.claude/teamlead/.state; }
inc_before=$(incsnap)
inc_root=$(cd $IW && env TMPDIR=$IW/.tl-scratch/tmp CLAUDE_PROJECT_DIR=$IP CLAUDE_AGENT_ID=x TL_TEST_PROBE_TMP=1 bash "$CLAUDE_PLUGIN_ROOT/test.sh" 2>$T/inc.err); inc_rc=$?
check "TMPDIR inside a worker worktree: test.sh still starts" "$inc_rc" 0
case "$inc_root" in
  "") bad "  it reports a temp root" ;;
  "$IP"/*) bad "  its temp root is outside the project (got $inc_root)" ;;
  *) ok "  its temp root is outside the project" ;;
esac
check "  the project's board, events.log and state files are byte-identical" "$(incsnap)" "$inc_before"
inc_rc=$(cd $IW && env TMPDIR=$IW/.tl-scratch/tmp HOME=$IW TL_TEST_PROBE_TMP=1 bash "$CLAUDE_PLUGIN_ROOT/test.sh" >/dev/null 2>$T/inc.err; echo $?)
check "no safe temp root anywhere (TMPDIR and \$HOME/tmp both inside the project): refuses to run" "$inc_rc" 2
check "  and says why" "$(grep -c 'refusing to run' $T/inc.err)" 1
check "  still nothing written to the project's board or events.log" "$(incsnap | head -2)" "$(printf '%s\n' "$inc_before" | head -2)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
