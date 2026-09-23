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
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
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
for m in on-demand role-dependant always never; do
  grep -q "$m" "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" || bad "help names opus mode '$m' that resolve.sh lacks"
done
ok "opus modes in help match resolve.sh"

# every opus mode must produce a distinguishable guidance line
rdp=$T/rd; mkdir -p $rdp/.claude/teamlead
for m in on-demand role-dependant always never; do
  printf 'effort: medium\nopus: %s\n' "$m" > $rdp/.claude/teamlead/settings.md
  "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $rdp > "$T/r-$m"
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
cmdset_table(){ awk '/^## Commands/,/^## Help text/' "$1" \
  | grep -oP '^\| `\K/teamlead[^`]*' | sed -E 's/\s*[<[].*$//' | sort -u; }
cmdset_fence(){ awk '/^## Help text/,/^## Project setup/' "$1" \
  | grep -oP '^  \K/teamlead.*' | sed -E 's/(\s{2,}|\s*[<[]).*$//' | sort -u; }
cmdset_table "$SK" > "$T/cs-table"; cmdset_fence "$SK" > "$T/cs-fence"
check "both copies are non-empty (the extractors still match the file's shape)" \
  "$([ -s "$T/cs-table" ] && [ -s "$T/cs-fence" ] && echo ok || echo empty)" ok
only_t=$(comm -23 "$T/cs-table" "$T/cs-fence" | tr '\n' ' ')
only_f=$(comm -13 "$T/cs-table" "$T/cs-fence" | tr '\n' ' ')
[ -z "$only_t" ] && ok "every Commands-table command is in the help fence" \
  || bad "in the Commands table but MISSING from the help fence:$( echo " $only_t" | sed 's/ *$//')"
[ -z "$only_f" ] && ok "every help-fence command is in the Commands table" \
  || bad "in the help fence but MISSING from the Commands table:$( echo " $only_f" | sed 's/ *$//')"
# Pin the set itself too, so a command added to BOTH copies still gets looked at here.
check "the shared set is exactly the commands that exist today" \
  "$(tr '\n' ' ' < "$T/cs-table")" \
  "/teamlead /teamlead board /teamlead board clean /teamlead board drop /teamlead brainstorm /teamlead effort /teamlead help /teamlead opus /teamlead plan /teamlead plan continue /teamlead settings /teamlead status /teamlead stop /teamlead superdoc "
# A third source: board.py's own usage line, so `/teamlead board <sub>` cannot name a
# subcommand the script does not implement.
python3 "$B" no-such-command --project $T >"$T/bcmds" 2>&1
bsubs=$(grep -m1 '^commands: ' "$T/bcmds")
for s in clean drop; do
  if grep -q "^/teamlead board $s$" "$T/cs-table" && grep -qE "(: |, )$s(,|$)" <<<"$bsubs"; then
    ok "  /teamlead board $s is implemented as board.py '$s'"
  else bad "  /teamlead board $s is implemented as board.py '$s' (board.py says: $bsubs)"; fi
done

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
grep -q 'does not exist' "$SD" && ok "  detects a dangling @-ref" || bad "  detects a dangling @-ref"
grep -q 'no longer exists' "$SD" && ok "  health-check audits @-refs too" || bad "  health-check audits @-refs"
# the detection snippet itself must work
sdp=$T/sdref; mkdir -p $sdp/superdoc/meta
printf '@superdoc/meta/TERMINOLOGY.md and @superdoc/meta/GONE.md\n' > $sdp/CLAUDE.md
printf 'terms\n' > $sdp/superdoc/meta/TERMINOLOGY.md
miss=$(cd $sdp && grep -oE '@superdoc/[^ )`]+' CLAUDE.md | sed 's/^@//' | while read -r f; do test -f "$f" || echo "$f"; done)
check "flags exactly the missing ref" "$miss" "superdoc/meta/GONE.md"

echo "== the @-budget rule keeps its reasoning =="
PB="$CLAUDE_PLUGIN_ROOT/skills/teamlead-superdoc/playbook.md"
grep -q 'nothing else, ever' "$PB" && ok "the exact set is still mandated" || bad "the exact set is still mandated"
grep -q 'does not suggest a file, it \*pastes\* it' "$PB" && ok "  explains @ pastes the file" || bad "  explains @ pastes the file"
grep -q 'every turn of every' "$PB" && ok "  names the per-turn cost" || bad "  names the per-turn cost"
grep -q 'permanent tax' "$SD" && ok "  the lead is told to hold the line at QC" || bad "  lead told to hold the line"

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
mkdw(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *why.*\n\n%b\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" "$2" | cat -s > "$T/dw.md"
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
mkfin(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *why.*\n\n## Done when\n- [x] it works — *verified by: agent*\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n%s\n\n### Answered\n- ~~old~~ → yes → **D1**\n\n## Notes from me\n%s\n' "$1" "$2" "$3" > "$T/fin.md"
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
mknum(){ printf '# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n%b\n\n### Answered\n%b\n\n## Notes from me\n' "$1" "${2:-}" | cat -s > "$T/num.md"
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
git worktree add -q "$T/wt" -b w1 2>/dev/null; echo dirty > "$T/wt/new.txt"
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
git -C "$T/wt" reset -q --hard 2>/dev/null; rm -f "$T/wt/new.txt" 2>/dev/null
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
mkq(){ printf '# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n%b\n\n### Answered\n%b\n\n## Notes from me\n' "$1" "${2:-}" | cat -s > "$T/q.md"
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
mkord(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n%b## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" "$2" > "$T/o.md"
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
check "a misspelled heading is caught" "$(printf '# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open Questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' > "$T/o.md"; "$PL" "$T/o.md" >"$T/oout" 2>&1; echo $?)" 1
grep -q 'unexpected section' "$T/oout" && ok "  named as unexpected" || bad "  named as unexpected"
grep -q 'missing section' "$T/oout" && ok "  and as missing" || bad "  and as missing"
grep -q 'do not exist until stage 4' "$PS2" && ok "  the skill says when they appear" || bad "  skill says when"

echo "== the plan stays finished through stages 5-7 =="
# Keying the finished-plan checks on "== 4" would let every one of them slide the
# moment the header ticked over to building.
mkst(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:SS*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n%b\n\n### Answered\n\n## Notes from me\n%b\n' "$1" "$2" "$3" | cat -s > "$T/st.md"
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

m=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Edit|Write|MultiEdit|NotebookEdit") | .hooks[].command' "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json")
grep -q 'plan-fence.sh' <<<"$m" && ok "  hooks.json wires plan-fence.sh under Edit|Write|MultiEdit|NotebookEdit" || bad "  hooks.json wires plan-fence.sh"

echo "== board-fence.sh: board_add is also gated by the plan's stage =="
bfp=$T/bfence; mkdir -p $bfp/.claude/teamlead/plan $bfp/.claude/teamlead/.state
bff=$bfp/.claude/teamlead/plan/topic.md
echo "$bff" > $bfp/.claude/teamlead/.state/active-plan
RB=mcp__plugin_teamlead_teamlead-board
bfdecide(){ out=$(echo "$1" | "$H/board-fence.sh"); [ -z "$out" ] && echo allow || jq -r .hookSpecificOutput.permissionDecision <<<"$out"; }

printf '# T\n\n> **Stage 3** — x\n' > $bff
check "board_add while the plan is at stage 3: denied" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_add","tool_input":{}}')" deny

printf '# T\n\n> **Stage 5** — x\n' > $bff
check "board_add once the plan reaches stage 5: allowed" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_add","tool_input":{}}')" allow

printf '# T\n\n> **Stage 3** — x\n' > $bff
check "board_update at stage 3: allowed (closing pre-existing work stays open)" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_update","tool_input":{}}')" allow

printf '# T\n\n> **Stage 5** — x\n' > $bff
check "a worker's board_add at stage 5: still refused (worker, not stage)" \
  "$(bfdecide '{"hook_event_name":"PreToolUse","cwd":"'$bfp'","tool_name":"'$RB'__board_add","tool_input":{},"agent_id":"w1"}')" deny

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

printf '# T\n\n> **Stage 4** — x\n\n## Goal\nTBD\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' > $gtf
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

python3 "$B" update --project $gtp --id 2 --state merged >/dev/null
printf '# T\n\n> **Stage 3** — x\n' > $gtf
check "no transcript_path: footer check skipped, exit 0" "$(gtev '{"hook_event_name":"Stop","cwd":"'$gtp'","stop_hook_active":false}')" 0

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
grep -q 'watcher: off (stages 5-7)' <<<"$stout" && ok "stage 5: watcher reported off" || bad "watcher off"
grep -q '^  next:' <<<"$stout" && ok "  and still has a next: line" || bad "  next: line"

echo "== restore.sh: flags a plan left mid-flight after /clear =="
: > $stp/.claude/teamlead/.state/active
printf '# T\n\n> **Stage 6** — x\n' > $stf
rsout=$(echo '{"hook_event_name":"SessionStart","source":"clear","cwd":"'$stp'"}' | "$H/restore.sh")
grep -q 'Session was cleared mid-plan' <<<"$rsout" && ok "stage 6: flags the clear" || bad "stage 6: flags the clear"
printf '# T\n\n> **Stage 3** — x\n' > $stf
rsout=$(echo '{"hook_event_name":"SessionStart","source":"clear","cwd":"'$stp'"}' | "$H/restore.sh")
grep -q 'Session was cleared mid-plan' <<<"$rsout" && bad "stage 3: should not flag the clear" || ok "stage 3: does not flag the clear"

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
mkrows(){ printf '# T\n\n> **Stage 4** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n%b\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" > "$T/rows.md"
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
mktbd(){ printf '# T\n\n> **Stage 5** — x\n\n## Goal\n%s\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n%s\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" "$2" > "$T/tbd.md"
  th=$(awk '/^## Decisions/{o=1;next} /^## /{o=0} o' "$T/tbd.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$th/" "$T/tbd.md"; "$PL" "$T/tbd.md" >"$T/tbdout" 2>&1; echo $?; }
check "TBD inside '## Goal' at stage 5 fails" \
  "$(mktbd 'TBD: decide later' '| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |')" 1
grep -q 'placeholder marker (TBD)' "$T/tbdout" && ok "  names it" || bad "  names it"
check "TBD only in a wave-table row does not trip it" \
  "$(mktbd 'G' '| 1 | I1 | fix the TBD bug — **D1** | `tl-sonnet-low` | src/a | — |')" 0

echo "== plan-lint (I9): two-or-more blank lines (D17) =="
mkblank(){ printf '%b' "$1" > "$T/bl.md"; "$PL" "$T/bl.md" >"$T/blout" 2>&1; echo $?; }
BLANKBAD='# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n'
BLANKGOOD='# T\n\n> **Stage 3** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n'
check "two consecutive blank lines fail" "$(mkblank "$BLANKBAD")" 1
grep -qE 'two or more consecutive blank lines \(first at line [0-9]+\)' "$T/blout" && ok "  names the line" || bad "  names the line"
check "a single blank line is fine" "$(mkblank "$BLANKGOOD")" 0

echo "== plan-lint (I9): D10 tick evidence at stage >= 6 =="
mkevid(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n%b\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" "$2" > "$T/ev.md"
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
    printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Brainstorm request\n%b## Notes from me\n' "$1" "$2" > "$T/brn.md"
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

echo "== plan-lint (I9): a phase row is display-only, not a real step =="
mkphase(){ printf '# T\n\n> **Stage 5** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n%b\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" > "$T/ph.md"
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
d2write(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *w.*\n\n## Done when\n- [x] ok — *verified by: agent* — ran `x` → ok\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n\n## Open questions\n*(none)*\n\n### Answered\n\n## Notes from me\n' "$1" > "$d2f"
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
qc3_stop_racer() {
  python3 -c "
import sys, time
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    time.sleep(0.5)
    orig(db, project)
board.save = slow
board.worker_stop('A', '$qc3rp')
"
}
qc3_forget_racer() {
  python3 -c "
import sys, time
sys.path.insert(0, '$bd')
import board
orig = board.save
def slow(db, project=None):
    time.sleep(0.5)
    orig(db, project)
board.save = slow
board.forget(['A'], '$qc3rp')
"
}
for i in 1 2 3; do
  rm -rf $qc3rp; mkdir -p $qc3rp
  python3 "$B" add --project $qc3rp --task "qc3 race row" --agent tl-sonnet-low --owns "qc3r/$i" >/dev/null  # id 1
  python3 "$B" update --project $qc3rp --id 1 --state running --worker A >/dev/null
  printf '%s  start     agent=teamlead:tl-sonnet-medium  id=A\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > $qc3rp/.claude/teamlead/.state/events.log
  qc3_stop_racer & sp1=$!
  qc3_forget_racer & sp2=$!
  wait $sp1 $sp2
  race3=$(python3 -c "import json; d=json.load(open('$qc3rp/.claude/teamlead/.state/board.json')); t=[x for x in d['tasks'] if x['id']==1][0]; print(t['state']+'|'+str(t['notes']))")
  check "race iteration $i: row 1 is returned with no requeue note (stop wins, precondition re-checked under the lock)" "$race3" "returned|None"
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

echo "== I5/D3/D4: hooks.json wires PostToolUse(Agent) -> record.sh =="
check "hooks.json declares the PostToolUse Agent matcher" \
  "$(jq -e '.hooks.PostToolUse[0].matcher == "Agent"' "$H/hooks.json")" "true"
check "record.sh's silent-stderr sites did not grow (no new board call swallows stderr)" \
  "$(grep -c '2>/dev/null' "$H/record.sh")" 4

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
check "clean refuses when cutting the merged rows would invalidate the board" \
  "$(python3 "$B" clean --project $clnr >"$T/crout" 2>&1; echo $?)" 1
grep -q 'refused — cleaning would leave the board invalid' "$T/crout" && ok "  names the reason" || bad "  names the reason"
grep -q 'two writers on one path' "$T/crout" && ok "  names the overlap it would have created" || bad "  names the overlap it would have created"
check "  a refused clean mutates nothing" \
  "$(python3 -c "import json; print(len(json.load(open('$clnr/.claude/teamlead/.state/board.json'))['tasks']))")" 3

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

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
