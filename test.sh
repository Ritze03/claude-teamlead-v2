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
grep -q "Planning: topic" <<<"$out" && ok "  names planning mode and the plan" || bad "  names planning mode and the plan ($out)"
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
grep -q 'teamlead-v2/hooks/statusline.sh' $ic/statusline.sh && ok "  adds teamlead" || bad "  adds teamlead"
[ "$(sl)" = "bash \"$ic/statusline.sh\"" ] && ok "  points settings at the combiner" || bad "  points settings at combiner ($(sl))"
python3 -c "import json;d=json.load(open('$ic/settings.json'));assert d['model']=='opus'" && ok "  leaves other settings alone" || bad "  leaves other settings alone"
ls $ic/settings.json.bak.* >/dev/null 2>&1 && ok "  wrote a backup" || bad "  wrote a backup"
run --combined >/dev/null
check "idempotent" "$(grep -c 'teamlead-v2/hooks/statusline.sh' $ic/statusline.sh)" 1
run --uninstall >/dev/null
check "uninstall restores the original" "$(sl)" 'bash "/tmp/prior.sh"'
# version pinning is removed so a plugin update cannot break the segment
printf '{"statusLine":{"type":"command","command":"bash \\"$HOME/.claude/plugins/cache/x/y/1.2.3/s.sh\\""}}\n' > $ic/settings.json
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; run --combined >/dev/null
grep -q '/x/y/\*/s.sh' $ic/statusline.sh && ok "un-pins a versioned plugin path" || bad "un-pins a versioned plugin path"
# a glob inside quotes never expands, so the de-pinned path must be unquoted
grep -qE '"bash [^"]*/x/y/\*/s\.sh"' $ic/statusline.sh && ok "  leaves the glob unquoted so it expands" || bad "  glob must be unquoted"
# a path containing spaces stays quoted and therefore stays pinned
printf '{"statusLine":{"type":"command","command":"bash \\"/a b/plugins/cache/x/y/1.2.3/s.sh\\""}}\n' > $ic/settings.json
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; run --combined >/dev/null
grep -q '1.2.3' $ic/statusline.sh && ok "  a path with spaces stays pinned and quoted" || bad "  path with spaces must stay quoted"
# never clobber a hand-written combiner
rm -f $ic/statusline.sh $ic/.teamlead-statusline-prev; printf '# mine\n' > $ic/statusline.sh
run --combined >/dev/null; grep -q '^# mine' $ic/statusline.sh && ok "refuses to clobber a hand-written combiner" || bad "refuses to clobber"

echo "== a finished plan has empty inboxes =="
mkfin(){ printf '# T\n\n> **Stage %s** — x\n\n## Goal\nG\n\n## Context\nC\n\n## Decisions\n- **D1** a — *why.*\n\n## Open questions\n%s\n\n### Answered\n- ~~old~~ → yes → **D1**\n\n## Notes from me\n%s\n\n## Implementation plan\n*Built from D1 · decisions:XX*\n\n| Wave | ID | Task | Agent | Owns | After |\n|:----:|:--:|---|---|---|---|\n| 1 | I1 | do — **D1** | `tl-sonnet-low` | src/a | — |\n' "$1" "$2" "$3" > "$T/fin.md"
  fh=$(sed -n '/^## Decisions/,/^## Open questions/p' "$T/fin.md" | grep '^- \*\*D' | md5sum | cut -c1-4)
  sed -i "s/decisions:XX/decisions:$fh/" "$T/fin.md"
  "$PL" "$T/fin.md" >"$T/finout" 2>&1; echo $?; }
check "stage 4, both inboxes empty" "$(mkfin 4 '*(none open)*' '')" 0
check "stage 4 with an open question" "$(mkfin 4 '1. unanswered?' '')" 1
grep -q 'fold each answer into a Decision' "$T/finout" && ok "  says to fold it into a Decision" || bad "  says to fold it"
check "stage 4 with a leftover note" "$(mkfin 4 '*(none)*' 'remember billing')" 1
grep -q "left in 'Notes from me'" "$T/finout" && ok "  names the leftover note" || bad "  names the leftover note"
check "stage 3 may hold both" "$(mkfin 3 '1. open?' 'a note')" 0
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
grep -q 'stage 2/5 open it in your editor' <<<"$out" && ok "  stage 2 tells the user to open it" || bad "  stage 2 label ($out)"
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
