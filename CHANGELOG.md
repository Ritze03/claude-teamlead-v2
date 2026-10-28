# Changelog

Newest first. One line per change, commit id at the end.

Versioning: every push that changes what users get bumps `.claude-plugin/plugin.json` and adds an entry here.

## 2.1.0 — 2026-10-28

First version bump since 2.0.0. Claude Code caches installs by version, so earlier changes may not have reached you; update the plugin (`claude plugin update teamlead@teamlead`, then restart) to get everything below. The session-start line now reads `[teamlead v2.1.0] Active for this project. ...`.

- Board fence: only `plan:` rows wait for plan stage 5; scouts, read-only rows and unrelated `owns:` work are allowed before it (GH#1). #e591db8 #c143868
- superdoc playbook: no hardcoded machine paths (GH#2). #13e7595
- Plugin bugs a worker finds are offered to you as an anonymized GitHub issue (nothing is sent as Claude Code feedback); workers flag them with a `🐞 PLUGIN BUG` line, relayed to you in a single-cell table, and `record.sh` reminds the lead. #4f3cd64 #6446610 #0c16538
- Planning: a `## Handoff` section in the plan, and the lead recommends `/clear` between phases; `restore.sh` points at the handoff after clear, compact or resume. #e42ae65
- Planning: the first Go audits context against the plan file; 6 to 7 happens on its own when there is nothing to test, 7 to 5 is explicit, phases by default; the watcher keeps running through stage 7; the plan file always ends with one empty line. #1e9b664 #ea2b4a6 #9561129 #e043aac
- Every dispatch, scouts and QC included, gets a board row first; relevant `docs/` and `superdoc/` pages go into every worker brief. #85460c0 #73af0c8
- Statusline prints a cached segment and refreshes in a detached single-flight child, so it no longer gets cancelled on slow disks. #d20afcf

- `worker-cleanup.sh` lifts a stale Claude Code agent lock (`claude agent agent-<id> (pid P start S)`: pid dead or reused, or the ledger no longer lists the agent as working) before removing the worktree; a live agent's lock or any foreign lock still refuses.
- When a `tl-*` worker really returns, `record.sh` stops the background Bash tasks it launched and left open (found via the task's `.output` file; ones the worker finished, TaskStop'd or named in its report are kept) and logs a `reap` event; a `pause` event now lists the worker's `open=` task ids. Covers read-only workers with no worktree; Monitors are not covered.
- Finished workers leave nothing behind: workers stop their own monitors/background shells before returning, and the lead closes each one out with `worker-cleanup.sh` (kills leftovers in its worktree, removes worktree and branch), including rows stuck `running` on a paused worker.
- Planning: a `## Research request` section (`Initial research [y/n]: `) above the brainstorm one — an opt-in pass where one worker searches the web for libraries, API gotchas, pitfalls and prior art; findings land in `## Context` with sources.
- Plans are never archived automatically; the agent says it is done and runs `plan-archive.sh` only on request.
- Gentle nudge for agents, planning scouts and the lead to use quick web searches when something is complicated or unfamiliar; never required.

## 2026-09-22

- Hardened board.py against races: render outside the lock, stop `remove`'s cascade from escaping a refusal, fix find-then-mutate in worker-stop/worker-start/forget. #10337fd
- Added worker lifecycle to board.py (`worker-start` / `worker-stop`); `forget` now requeues orphaned rows. #f7bf838
- Wired the worker lifecycle to hooks — PostToolUse(Agent), SubagentStart/Stop and SendMessage-resume. #3daafd2
- Regression test for crash-safety of atomic writes. #bb80be8

## 2026-09-21

- board.py now locks and writes atomically, tracks a worker field, and guards bad updates. #54abfb5
- Closed the remaining lock gap on the MCP `board_add` write path. #2f697ef
- Squash-merge detection, board file integrity check, and auto-unblock. #7bf4143
- Transitive `blocked_by`, blocker-unmerged gate, behind-main and leftover-worktree checks. #02ba0ce
- `remove` op, worker refusal on CLI writes, `forget` filters. #6b0a9cd
- Empty `blocked_by` is treated as vacuously satisfied instead of blocking forever. #bd63779
- plan-lint enforces stable open-question numbers. #e494fbf
- Session start renders the board before state and forgets stale workers. #34cbedc
- Ignore `__pycache__` and the whole `.claude/teamlead` dir; untracked a stale `.pyc`. #62437e0
- Docs: board id in dispatch briefs, rebase gate row, `remove` / `forget` / plan-stage gate. #800d085 #72a6a2d
- Test fixtures for all of the above. #1e511a0 #53b04cd

## 2026-09-20

- Plan-aware Stop hook, re-checking the plan stage at Stop so bypassed writes are caught. #2db8792 #594752b
- Plan header stage machine is enforced. #fa1527a
- Board checks that every plan-step id has a matching task. #c02e1ae
- Slash-only activation/deactivation; the Go is recorded. #fe1955a
- Plan watcher never double-starts. #3775737
- Statusline: per-stage plan emoji, case-insensitive header parse. #72a84a9
- plan-lint phase-B rules: Owns-prefix overlap, brainstorm request, blank-line and evidence checks. #eb76ed1
- `plan-archive --abandon` now forgets the board rows too. #2097032
- Docs: enforcement.md rebuilt, plan.md reconciled. #0bfc248

## 2026-09-19

- Opt-in statusline segment, then planning mode, colour, and a watch indicator. #09b453b #bb3ffc8 #8949d09
- Added the statusline installer. #f5dd1a2
- Plan flow reshaped: create-and-show before the scout, everything folds into Decisions, archive once done. #fcbb0ad #5167caa #5e48abb
- Plan mode runs through Agent-Testing and User-Testing. #f44e954
- Questions to the user always carry a recommendation. #8dadfa7
- Renamed `out` to `working`. #63f80e2
- superdoc verifies that @-refs resolve, and says why. #ee66232 #d815293
- Cancelled workers are closed out; start-line token parsing fixed. #19a9cf4

## 2026-09-16

- teamlead v2: plugin rewrite with a durable ledger. #a6674b5
- Board JSON is the truth, markdown is rendered, tools do the writing. #ff0f52e
- Only the lead writes to the board. #4292772
- Hardening: liveness-aware gate, git-verified merges, status, rotation. #9730220
- Abandoned dispatches age out instead of blocking the gate. #647e438
- board-lint validates the model-written half of the ledger. #27134e8
- A worktree resolves back to the main checkout. #5aa7cee
- The ledger tracks resumed workers. #3bd3f04
- Concise output for the user; briefs and worker returns stay dense. #3c312b2 #e289e5e
- Added `/teamlead help` and expanded the README. #eb7b0bb
