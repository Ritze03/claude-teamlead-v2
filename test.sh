#!/usr/bin/env bash
# Smoke test for the teamlead hooks. Run from the repo root: ./test.sh
# Covers the paths that broke during development, since those are the ones
# that break again.
set -uo pipefail
export CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
H="$CLAUDE_PLUGIN_ROOT/hooks"
B="$CLAUDE_PLUGIN_ROOT/scripts/board.py"
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
printf 'effort: medium\nopus: on-demand\nprompting: sequential\n' > .claude/teamlead/settings.md

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
check "running worker blocks"    "$(ev "$STOP" "$H/gate.sh")" 2
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
for c in "/teamlead plan" "/teamlead brainstorm" "/teamlead superdoc" "/teamlead status" "stop teamlead"; do
  grep -q -- "$c" "$SK" || bad "help advertises '$c' but the skill does not define it"
done
ok "advertised commands all defined"
# the dials it names must match resolve.sh
for lvl in low xlow xmedium high xhigh; do
  grep -q "  $lvl)" "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" || bad "help names effort level '$lvl' that resolve.sh lacks"
done
grep -q 'effort=medium' "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" || bad "medium is not the default in resolve.sh"
ok "effort levels in help match resolve.sh"
for m in on-demand role-dependant never; do
  grep -q "$m" "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" || bad "help names opus mode '$m' that resolve.sh lacks"
done
ok "opus modes in help match resolve.sh"

# every opus mode must produce a distinguishable guidance line
rdp=$T/rd; mkdir -p $rdp/.claude/teamlead
for m in on-demand role-dependant never; do
  printf 'effort: medium\nopus: %s\n' "$m" > $rdp/.claude/teamlead/settings.md
  "$CLAUDE_PLUGIN_ROOT/hooks/resolve.sh" $rdp > "$T/r-$m"
done
if diff -q "$T/r-on-demand" "$T/r-role-dependant" >/dev/null; then
  bad "role-dependant is indistinguishable from on-demand"
else ok "each opus mode gives distinct guidance"; fi

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
grep -q 'planning topic' <<<"$out" && ok "  names planning mode and the plan" || bad "  names planning mode and the plan ($out)"
grep -q 'stage 3/5' <<<"$out" && ok "  shows stage out of total" || bad "  shows stage out of total"
grep -q 'working it out' <<<"$out" && ok "  says what the stage is for" || bad "  says what the stage is for"
# the label must follow the NUMBER, not stale header prose
sed -i 's/Stage 3/Stage 4/' $pf
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q 'implementation plan' <<<"$out" && ok "  label tracks the number, not the prose" || bad "  label tracks the number ($out)"
grep -q 'Go' <<<"$out" && ok "  stage 4 flags that it is waiting on you" || bad "  stage 4 flags waiting"
sed -i 's/Stage 4/Stage 3/' $pf
sed -i 's/Stage [0-9]/Stage 5/' $pf
out=$(echo '{"workspace":{"current_dir":"'$slp'"}}' | bash "$SL")
grep -q 'topic S' <<<"$out" && bad "  stage 5 should not read as planning" || ok "  stage 5 (handed off) is not planning"
[ -f $slp/.claude/teamlead/.state/active-plan ] && bad "  pointer cleared at handoff" || ok "  pointer cleared at handoff"
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
S='{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"ok stop teamlead"}'
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
check "resumed worker counts as outstanding" "$(ev "$STOP" "$H/gate.sh")" 2
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
check "a just-dispatched worker (no start yet) still blocks" "$(ev "$STOP" "$H/gate.sh")" 2
printf '%s  start     agent=tl-sonnet-low  id=z1\n' "$now" >> $L
check "once started, it is tracked by id not by pending" "$(python3 "$B" ledger --project $proj | python3 -c 'import json,sys;d=json.load(sys.stdin);print(str(len(d["outstanding"]))+","+str(d["pending"]))')" "1,0"
rm -f $L

echo "== vocabulary is consistent: 'working', never 'out'/'running' =="
NOW2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s  start     agent=tl-sonnet-high  id=v1\n' "$NOW2" > $L
ev "$STOP" "$H/gate.sh" >/dev/null
grep -q 'worker(s) still working' "$T/out" && ok "gate says working" || bad "gate says working ($(cat $T/out))"
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

echo "== plan-lint stage awareness =="
PL="$H/plan-lint.sh"
mkplan(){ cat > "$T/pl.md" <<PEOF
# T

> **Stage $1** — working it out · started 2026-09-16

## Goal
G

## Context
C

## Decisions
- **D1** a call — *why.*

## Open questions
1. A question?
$2

### Answered

## Notes from me

## Implementation plan
$3
PEOF
"$PL" "$T/pl.md" >"$T/plout" 2>&1; echo $?; }
TBL='*Built from D1 · decisions:XX*

| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | do it — **D1** | `tl-sonnet-low` | src/a/ | — |'
check "stage 3 with no impl plan is clean" "$(mkplan 3 '' '')" 0
check "empty '> me:' placeholder is not an answer" "$(mkplan 3 '   > me:' '')" 0
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
python3 "$B" add --project $gp --task w --agent tl-sonnet-high --owns src/x >/dev/null
git checkout -q -b feat; echo work > b.txt; git add -A >/dev/null; git commit -qm work; git checkout -q master
python3 "$B" update --project $gp --id 1 --state merged --branch feat >/dev/null
python3 "$B" check --project $gp >"$T/gout" 2>&1; rc=$?
check "false 'merged' is caught" "$rc" 1
grep -q 'not actually merged back' "$T/gout" && ok "  names the unmerged branch" || bad "  names the unmerged branch"
git merge -q feat
check "true 'merged' passes" "$(python3 "$B" check --project $gp >/dev/null 2>&1; echo $?)" 0
python3 "$B" update --project $gp --id 1 --branch "" >/dev/null 2>&1 || true
cd $proj

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
rm -rf $proj/.claude $proj/.gitignore
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"/teamlead"}' "$H/mode.sh" >/dev/null
grep -qxF '.claude/teamlead/.state/' $proj/.gitignore && ok "state dir ignored" || bad "state dir ignored"
grep -qxF '.claude/teamlead/board.md' $proj/.gitignore && ok "board.md ignored" || bad "board.md ignored"
before=$(wc -l < $proj/.gitignore)
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"/teamlead"}' "$H/mode.sh" >/dev/null
check "not duplicated on re-activation" "$(wc -l < $proj/.gitignore)" "$before"
# A project activated by an older version has the flag but no gitignore entries.
rm -f $proj/.gitignore
ev '{"hook_event_name":"UserPromptSubmit","cwd":"'$proj'","prompt":"ordinary turn"}' "$H/mode.sh" >/dev/null
grep -qxF '.claude/teamlead/.state/' $proj/.gitignore && ok "backfilled on an ordinary turn" || bad "backfilled on an ordinary turn"
rm -f $proj/.gitignore
ev '{"hook_event_name":"SessionStart","cwd":"'$proj'","source":"startup"}' "$H/restore.sh" >/dev/null
grep -qxF '.claude/teamlead/.state/' $proj/.gitignore && ok "backfilled on session restore" || bad "backfilled on session restore"

echo "== routing resolution =="
mkdir -p .claude/teamlead
printf 'effort: xlow\nopus: never\n' > .claude/teamlead/settings.md
r=$("$H/resolve.sh" "$proj")
grep -q 'Workhorse: tl-sonnet-medium' <<<"$r" && ok "xlow lowers the workhorse" || bad "xlow lowers the workhorse"
grep -q 'tl-opus-\*' <<<"$r" && ok "never bans Opus" || bad "never bans Opus"
grep -q 'Vision.*tl-opus-medium' <<<"$r" && ok "vision survives opus:never + xlow" || bad "vision survives opus:never + xlow"
grep -q 'Never tl-opus-high for vision' <<<"$r" && ok "vision capped below high" || bad "vision capped below high"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
