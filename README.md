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

**Requires:** `inotify-tools`, `git`, `jq`, and access to both Opus 5 and Sonnet 5 — the
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
**persists across sessions** until you say `stop teamlead`.

## Modes

| | |
|---|---|
| **orchestration** | The always-on mode. Board, dispatch, gates. |
| **`/teamlead plan <topic>`** | Interactive planning in a file you keep open in your editor. Scouts first, asks second, never decides the plan is finished — you type "Go". |
| **`/teamlead brainstorm <agents> <iterations> <topic>`** | N independent thinkers × M rounds, overlapping lenses, questions back to you between rounds, a final Opus verify. |
| **`/teamlead superdoc`** | Sets up / audits the agent-facing knowledge base in `superdoc/`. `docs/` stays user-facing. |

## Seeing what's happening

```bash
python3 <plugin>/scripts/board.py status --project "$PWD"
```

Open tasks, workers still out, and anything the checks would flag.

## State

```
.claude/teamlead/
├── settings.md      effort / opus / prompting        (committed)
├── board.md         live working set                 (gitignored)
├── plan/            plan files you open              (committed)
├── brainstorm/      live brainstorm runs             (committed)
└── .state/          hook-owned, never hand-edited    (gitignored)
```

Nothing is stored in your home folder. Everything is per project.

## License

MIT
