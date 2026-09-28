# claude-teamlead v2

A [Claude Code](https://code.claude.com) plugin that turns the main agent into a **team lead**:
it splits work into a tracked task list, dispatches sub-agent workers, picks the model and
effort for each, and keeps the state on disk so nothing is lost when context is compacted.

> 🚧 **Ready for human testing, not yet battle-tested.** Rework of
> [claude-teamlead](https://github.com/Ritze03/claude-teamlead) from a skill into a plugin.
> Every mode has been exercised end-to-end against real projects — orchestration, plan mode
> (both gates, live editor watching), brainstorm, superdoc, greenfield, and an adversarial
> run. 94 unit tests. See [`docs/plan.md`](docs/plan.md) for the design and every bug the
> testing found.

## Core idea

A smart lead that **thinks** plus cheap sub-agents that **implement** is the efficient shape.
The lead's context is the scarce resource, so task state, worker results and settings live in
files under `.claude/teamlead/` — not in its head.

That matters because the failures this rewrite targets are all one bug: **the lead had no
durable ledger.** Ignoring its own task list, losing a worker's result, leaving worktrees
behind, never merging a branch back — every one of those is state that lived only in
conversation context, and context gets thrown away.

## What's enforced, not just asked

v1 defended its rules with prose and lost. v2 uses hooks where an invariant should be
impossible to break rather than merely discouraged:

- **Decompose** — changed 2+ files without writing a board? Blocked once.
- **Outstanding** — dispatched workers that never returned? Blocked once.
- **Reconcile** — the ledger says a worker returned but the board still says `running`?
  Blocked once. That gap is where work used to evaporate.
- **Worktrees** — uncommitted or unmerged worker branches? Blocked once.
- **Board format** — an invented format silently breaks every check, so it is checked.
- **Worker fence** — a worker can only write inside its own worktree. Claude Code already
  refuses writes into the shared checkout; this closes everywhere else on disk.
- **Restore** — after `/clear` or a compaction, open state is re-injected automatically.
- **Merged means merged** — a task marked merged whose branch still has unmerged commits is
  caught against git, not taken on trust.

Workers are tracked by agent id, so a worker is followed however long it runs, and a worktree
is only flagged once its worker has actually **finished** — a check that fires during normal
work teaches you to ignore it.

A `Stop` hook can only block once per turn, so the worst case is a forced second look, never
a stuck session.

## Linux only

v2 targets **Linux**, deliberately. macOS and Windows are not supported and not planned.

Planning mode watches the plan file with `inotify`, so you edit it in your own editor and the
lead reacts to your changes without you retyping them into chat. Rather than carry a
portability layer for a personal tool, v2 requires it outright.

**Requires:** `inotify-tools`, `git`, `jq`, and access to both Opus 5.5 and Sonnet 5 — the
workers pin exact model IDs and reasoning-effort levels.

## Install

```bash
claude plugin marketplace add Ritze03/claude-teamlead-v2
claude plugin install teamlead@teamlead
```

Or run against a local checkout without installing:

```bash
claude --plugin-dir /path/to/claude-teamlead-v2
```

Then say `/teamlead` — or just ask it to act as a team lead. Activation is per project and
**persists across sessions** until you say `/teamlead stop`.

## Modes

| | |
|---|---|
| **orchestration** | The always-on mode. Board, dispatch, gates. |
| **`/teamlead plan <topic>`** | Interactive planning in a file you keep open in your editor. Scouts first, asks second, never decides the plan is finished — you type "Go". |
| **`/teamlead brainstorm <agents> <iterations> <topic>`** | N independent thinkers × M rounds, overlapping lenses, questions back to you between rounds, a final Opus verify. |
| **`/teamlead superdoc`** | Sets up / audits the agent-facing knowledge base in `superdoc/`. `docs/` stays user-facing. |

## What a session looks like

```
$ claude
> act as teamlead for this project
✅ TEAMLEAD ACTIVATED
```

First run in a project asks three questions once (effort direction, hard cap, Opus policy)
and never asks again. Then give it work:

```
> every page needs an intro paragraph and a meta description
```

It writes the task list to the board *before* dispatching, fans out one worker per
independent unit in its own git worktree, and reports back when they land. Ask it something
else meanwhile — the main thread never blocks.

```
> /teamlead status
teamlead — 2 open task(s), 1 worker(s) out
  #3   running   Intro + meta for seasonal.html, about.html [wt/task-3]
  #4   blocked   QC over 3
```

## Commands

| | |
|---|---|
| `/teamlead` | Activate. Persistent, per project. |
| `/teamlead stop` | Deactivate. This exact command is the only phrase that deactivates the mode — loose wordings are deliberately not matched, because a subagent quoting one used to kill the mode. |
| `/teamlead help` | Print the help card. |
| `/teamlead status` | Open tasks, workers still out, and anything the checks would flag. |
| `/teamlead board` | The full board table, inline in the terminal. |
| `/teamlead board clean` | Forget every finished task, and with it the "how it was solved" notes. Open tasks are untouched and ids keep counting up. No confirmation — nothing live is at risk. |
| `/teamlead board drop` | Empty the board completely, open tasks included. It tells you first how many open rows and which workers it is about to stop, then asks once. Workers are stopped; **their worktrees are not touched** — removing those is a separate question it asks afterwards, naming any worktree holding commits you have not merged. The old board is backed up to `.state/board.json.dropped`, which is overwritten by the next drop, so it is one level of undo and no more — and it is a **board-only** undo: the drop also clears the event ledger, which is not backed up, so restoring the file brings back rows with no worker history behind them (a restored `running` task then reads as a worker that is not there). |
| `/teamlead plan <topic>` | Interactive planning — see below. |
| `/teamlead plan continue` | Resume the active plan from where it left off; the way back in after a `/clear`. |
| `/teamlead brainstorm <agents> <iterations> <topic>` | N thinkers over M rounds, then an Opus verify. |
| `/teamlead superdoc` | Set up / audit the agent-facing docs in `superdoc/`. |

## Dials

Asked once per project, stored in `.claude/teamlead/settings.md`, changeable anytime.
Running any of these with no argument re-opens the picker.

| | |
|---|---|
| `/teamlead effort <level>` | `low` · `xlow` · **`medium`** · `xmedium` · `high` · `xhigh` — biases which worker tier gets reached for first. The `x` levels are hard caps, not just a bias. |
| `/teamlead opus <mode>` | **`on-demand`** (Opus only after a Sonnet worker actually fails) · `role-dependant` (Opus first-choice when the role calls for it, ordinary execution still starts on Sonnet) · `always` (every task goes to an Opus worker first-choice, Sonnet is never dispatched, and the effort dial only picks which Opus tier) · `never` (no Opus workers at all — a stuck worker reports its blocker and the lead reasons through it) |
| `/teamlead settings` | Re-opens the picker for both dials at once. |

**Vision is exempt from both dials.** Anything whose input is an image goes to
`tl-opus-medium` automatically — Opus reads images materially better and there's no Sonnet
fallback worth having — but capped below high effort so the exemption stays cheap.

## Planning mode

The mode worth trying first, because it's the one that isn't just delegation.

`/teamlead plan <topic>` creates the file and shows you its **absolute path first** — before
it starts scouting, so you can open it while that runs rather than waiting to find out where
it is. Passing the topic in the command skips the "what are we planning" step entirely. It scouts the repo before asking you anything, then asks. You can
answer in chat *or* type into the file and save — it watches the file and picks up your edit,
promotes it into a decision, and strikes the question.

It never decides the plan is finished. Every turn ends with the same fixed line:

```
Type "Go" if you want me to plan the implementation.
```

"Go" advances exactly one stage — first to the implementation plan, where it **stops again**,
then to execution. Your plan of *what*, and its plan of *how*, are separate approvals.

## Status line (optional)

A plugin **cannot** install a main status line — only your `settings.json` can. So this ships
a segment and leaves the slot alone rather than claiming it:

```
⚑ teamlead 📄 Planning: recipes-section · stage 3/5 working it out · 2 open
```

Each part appears only when it applies, so the line is short almost always and grows exactly
when something needs you:

| | |
|---|---|
| `📄 Planning: <name> · stage N/5 <what it is for>` | Plan mode, which plan, and what the current stage is actually doing. The stage comes from the plan file's header so it disappears at handoff; the label is keyed on the *number* rather than the header prose, which can go stale when a stage is bumped without rewording. Stage 4 adds an amber `Go ⏎` — that stage is finished and waiting on you specifically. A trailing `👀` means the file is being watched right now, so an edit you save will be picked up; it disappears while the agent holds control and is writing. |
| `N open` | Unfinished tasks. |
| `N working` | Workers actually running, paired by agent id — accurate however long they run. Deliberately not called `running`: the board has a `running` state, and when the two disagree that divergence is the bug the reconcile gate catches. |
| `N returned` | **A worker came back and you have not acted on it.** The window where work used to evaporate; amber because it is the one number worth chasing. |
| `N blocked` | Tasks that cannot proceed. |
| `⚠` | A real problem: board/JSON drift, a `merged` task git says is not merged, or two unfinished tasks owning the same path. |

It prints nothing unless teamlead is active in the current project, and resolves a worker's
worktree back to the main checkout so it reads the same everywhere — including in non-git
projects, where worktree resolution is skipped rather than fatal.

If you have no status line yet:

```json
{ "statusLine": { "type": "command",
    "command": "bash \"$HOME/.claude/plugins/cache/teamlead/teamlead/*/hooks/statusline.sh\"" } }
```

**If you already have one, compose — don't replace.** Point `statusLine` at a small script of
your own that runs both and joins the output:

```bash
#!/usr/bin/env bash
in=$(cat)
a=$(printf '%s' "$in" | bash /path/to/your/existing/statusline.sh)
b=$(printf '%s' "$in" | bash "$HOME"/.claude/plugins/cache/teamlead/teamlead/*/hooks/statusline.sh)
printf '%s' "$a"; [ -n "$b" ] && printf ' · %s' "$b"
```

Note the glob instead of a pinned version directory: a hard-coded `.../4.7.0/...` path breaks
silently the next time the plugin updates.

## Seeing what's happening

```bash
python3 <plugin>/scripts/board.py status --project "$PWD"
```

Open tasks, workers still out, and anything the checks would flag.

## State

```
.claude/teamlead/
├── settings.md      effort / opus                    (committed)
├── board.md         live working set                 (gitignored)
├── plan/            plan files you open              (committed)
├── brainstorm/      live brainstorm runs             (committed)
└── .state/          hook-owned, never hand-edited    (gitignored)
```

Nothing is stored in your home folder. Everything is per project.

## Troubleshooting

**The gate blocked me and I disagree.** Say so plainly — *"skipping the worktree check, that
branch is deliberate"* — and it proceeds. It blocks once per turn, never traps a session. If
you're dismissing it repeatedly for the same reason, that's a bug in the check; file it.

**`board.md` looks wrong.** It's generated from `.claude/teamlead/.state/board.json`. Don't
hand-edit it — `board.py render` rebuilds it, and `board.py check` will tell you if the two
have drifted.

**It says a worker is working but nothing is running.** A cancelled or killed agent
emits no stop event, so the ledger counts it until a long timeout. Close it out:

```bash
python3 <plugin>/scripts/board.py forget --project "$PWD"
```

`board.py status` lists the stuck ids first. This appends a `cancel` event rather
than editing history.

**A worker couldn't write somewhere.** Workers are fenced to their own worktree. That's
deliberate: the refusal message tells them to report to the lead instead.

**I edited the plan file and nothing happened.** The watcher is armed at stage 2 of plan
mode. If the session was restarted since, re-enter plan mode on that topic.

**`CLAUDE_PLUGIN_ROOT` is empty in a shell.** It isn't set in the agent's shell, only in
hooks. The absolute path is in `.claude/teamlead/.state/plugin-root`.

## License

MIT
