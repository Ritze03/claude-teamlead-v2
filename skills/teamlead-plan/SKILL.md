---
name: teamlead-plan
description: Use for /teamlead plan <topic>, or when the user wants to work out a plan interactively before implementing. Opens a plan file the user edits in their own editor while you both work it out, then writes an implementation plan and hands off to the board.
---

# Plan mode

Interactive. You and the user work out a plan **in a file they keep open in their
own editor**. You print its absolute path once so it can be copy-pasted. You never
try to open it for them.

Plan files: `<project>/.claude/teamlead/plan/<topic-slug>.md`

## Stages

| Stage | What happens |
|---|---|
| **1 Topic** | Ask what's being planned. Derive the filename. If the file exists, offer to **continue** it — never silently overwrite. |
| **2 Open it** | Create the near-empty plan, print the **full absolute path**, record it to `.claude/teamlead/.state/active-plan`, start the watcher. |
| **3 Work it out** | Scout first, then ask. Back-and-forth until the user says Go. |
| **4 Implementation plan** | You alone write the wave table. Then **stop again**. |
| **5 Go** | Translate into `board.md` and execute. |

**"Go" advances exactly one stage.** From 3 it means *write the implementation
plan, then stop*. From 4 it means *start implementing*. One word, never a skip
straight to execution — your plan of *how* is separate work from their plan of
*what*.

## Never assume planning is finished

The default state of a plan is **unfinished**. You do not decide it is done, and
you do not ask whether to start. Banned:

- "The plan looks complete — shall I start?" — the banned question in a coat.
- "I think we've covered everything." — the implicit version.
- Treating **silence** as consent.
- Treating a **file save** as consent. "looks good to me" typed into the file is
  *not* a Go. Go comes from chat.

Instead, end every planning turn with one **fixed** line, set off from the body:

- Stages 1–3: `Type "Go" if you want me to plan the implementation.`
- Stage 4 only: `Type "Go" if you want me to start implementing.`

**Byte-identical every turn.** The moment it tracks your sense of progress —
*"Type Go, I think we're about there"* — it becomes the banned question again.
A static line is not you judging readiness; it is the command staying visible.

## Stage 3 opens with a scout

Before asking the user anything, dispatch scouts to gather what the repo can
answer. Findings go in `## Context`. Research first, questions second — never ask
what you could have looked up.

## Sharing the file with the user

They have it open; you write to it between turns. Without discipline this eats
their work.

- **Targeted edits only, never full-file rewrites.** Re-read before every write.
- **`## Notes from me` is theirs.** Never write there.
- After every write of yours, refresh the snapshot so the watcher stays quiet:
  `cp <plan> <project>/.claude/teamlead/.state/snap/<file>`
- If the file changed since you last read it, they edited it — **merge first**.
  The watcher is convenience; this check is correctness.

`CLAUDE_PLUGIN_ROOT` is **not** set in your shell — the plugin's absolute path is in
`.claude/teamlead/.state/plugin-root`, and the injected state block prints it. Use it.

Write the plan's absolute path to `.claude/teamlead/.state/active-plan` at stage 2, so a
session that resumes after a compaction is told which plan is live.

**Start the watcher at stage 2** with the **Monitor** tool. Monitor is usually a
*deferred* tool — `ToolSearch("select:Monitor")` first, or the call will fail. Give
it the longest `timeout_ms` allowed (1800000) and re-arm on expiry; there is no
`persistent` parameter:

```
$(cat .claude/teamlead/.state/plugin-root)/hooks/watch-plan.sh "$PWD" <plan-file>
```

Each save emits a diff plus any lint failures. Stop it with TaskStop when plan
mode ends — a persistent monitor otherwise outlives the mode.

## File structure — fixed, always this order

```markdown
# <Topic>

> **Stage 3** — working it out · started <date>
> Typing "Go" now → I write the implementation plan.

## Goal
One or two lines. `TBD` until stated.

## Context
Constraints, what exists, what must not break. Scout findings land here.

## Decisions
- **D1** The call — *why, in one line.*

## Open questions
1. The question?
   > me: (the user may answer inline here)

### Answered
- ~~Old question~~ → answer → **D1**

## Notes from me
Theirs. Never write here.

## Implementation plan
*Built from D1–D5 · decisions:a3f9*

| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | … | `tl-sonnet-medium` | *(read-only)* | — |
| 2 | I2 | … — **D1** | `tl-sonnet-high` | `src/x/` | I1 |
```

**Same wave = runs in parallel.** No prose annotations like *"parallel with I2"* —
a dependency column plus a prose note is two sources of truth that can disagree.

**`Owns` is the load-bearing column**: the write scope handed verbatim to the
worker. Without it "parallel" is an assertion, not a proof — two steps both
writing `api/routes/` is the one-writer-per-file violation everything rests on
avoiding. Read-only steps own nothing and are always safe to fan out.

When an inline `> me:` answer appears, promote it to a Decision and strike the
question into `### Answered`.

## Lint before offering Go

Run after every write, and always before the stage-4 footer:

```
$(cat .claude/teamlead/.state/plugin-root)/hooks/plan-lint.sh <plan-file>
```

It checks section order, dependency waves, `Owns` overlap, agent tiers, decisions
with no step, un-promoted `> me:` answers, stray `TBD`s at stage 4, and the
staleness stamp. **Re-stamp whenever the Decisions section changes** — planning is
not linear, and a stage-4 plan that predates a new decision keeps looking
authoritative while the ground under it has moved.

## Stage 5 — handoff

Copy the wave table into `.claude/teamlead/board.md`, column for column. Each
board row keeps `— I<n>` linking back to its plan step.

**Plan is frozen intent; board is live state.** When execution diverges, record it
on the board — never silently patch the plan. Losing the fact that reality
departed from the plan loses the interesting part.
