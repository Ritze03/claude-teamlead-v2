---
name: teamlead-plan
description: Use for /teamlead plan <topic>, or when the user wants to work out a plan interactively before implementing. Opens a plan file the user edits in their own editor while you both work it out, then writes an implementation plan and hands off to the board.
---

# Plan mode

Interactive. You and the user work out a plan **in a file they keep open in their
own editor**. You never try to open it for them.

**Present the path as a single-cell table**, so it stands out from the surrounding
prose instead of being one more line to scan past:

```markdown
| 📄 Open this in your editor |
|---|
| `/abs/path/to/.claude/teamlead/plan/<topic>.md` |
```

Always the **full absolute path**, in backticks so it stays monospace. Show it at
stage 2, and again whenever the user could have lost it — after a compaction, a
`/clear`, or a long gap.

Plan files: `<project>/.claude/teamlead/plan/<topic-slug>.md`

## Stages

| Stage | What happens | Ends when |
|---|---|---|
| **1 Topic** | Settle what is being planned and derive the filename. **Skip it entirely when the topic came with the command** (`/teamlead plan <topic>`) — that is the normal case. If the file already exists, offer to **continue** it; never silently overwrite. | You have a filename |
| **2 Create and show** | Create the near-empty plan — the five sections, **no `## Done when` and no `## Implementation plan`** — with `> **Stage 2**` in its header, write `.state/active-plan`, start the watcher, and **show the path table**. | The path is on screen |
| **3 Work it out** | Scout, then ask. Update the header to `> **Stage 3**`. Back-and-forth until "Go". | The user says "Go" |
| **4 Done when + implementation plan** | You alone write the acceptance criteria and the wave table, inserting both **above `## Open questions`**. Then **stop again**. | The user says "Go" |
| **5 Build** | Translate into `board.md` and execute. Update the header to `> **Stage 5**`. | Every task merged, board empty |
| **6 Agent-Testing** | Run every `verified by: agent` criterion for real and tick it. | They all pass |
| **7 User-Testing** | Hand the `verified by: user` criteria over and **wait**. | The user says it is good |

Plan mode runs to the end of **7**, not to the handoff. The plan is not finished
when the code is written; it is finished when it has been checked.

### Order inside the first turn

Stage 2 is short and must not be buried. In one turn, in this order:

1. Create the file and **say the path, in the table, as your first output** — before
   any slow work. Scouting takes a minute or more; the user should be opening the
   file *during* it, not waiting to learn where it is.
2. Start the watcher and write `.state/active-plan`.
3. *Then* dispatch the scout and move to stage 3.

Getting this backwards — scouting first and mentioning the path in the same message
as the findings and questions — is the observed failure. It looks like the plan
jumped from stage 1 straight to stage 3, and the user has no chance to open the
file while there is still something to watch it for.

The header tracks this: the file says `Stage 2` while the scout runs (the status
line then reads *"open it in your editor"*, which is exactly the thing to do), and
becomes `Stage 3` when you post the questions and are genuinely waiting on them.

**"Go" advances exactly one stage.** From 3 it means *write the implementation
plan, then stop*. From 4 it means *start implementing*. One word, never a skip
straight to execution — your plan of *how* is separate work from their plan of
*what*.

### Do not block on the user opening the file

You cannot tell whether they opened it. `IN_OPEN` fires for every process that
reads the file — your own linter and watcher included — and carries no PID, so
"the user opened it" is indistinguishable from "plan-lint ran". Do not wait on it,
and do not ask them to confirm they opened it; the path is shown, and reading the
plan in chat instead is a legitimate choice.

What *is* unambiguous is a **save**: the watcher records
`.state/plan-touched` the first time the file changes on disk. Use it once, as a
nudge rather than a gate — if the user sends the first **"Go"** and that marker
does not exist, say so in one line before writing the implementation plan:

> You haven't edited the plan file — happy to proceed on what's there, or open it
> first if you want to change anything.

Then proceed if they say go again. Never hold the plan hostage to it.

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

The scout runs **after** the path is on screen, never before it (see *Order inside
the first turn*). An empty repo is not a reason to skip scouting — scout the
machine instead: language runtimes, build tools, what is actually installed. That
is the context a greenfield choice turns on.

## Sharing the file with the user

They have it open; you write to it between turns. Without discipline this eats
their work.

- **Targeted edits only, never full-file rewrites.** Re-read before every write.
- **`## Notes from me` is theirs to write.** Never add your own content there and
  never reword a line; the only edit you make is removing a note once it is folded
  into a Decision (see *Everything ends up in Decisions*).
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

Each save emits a diff plus any lint failures.

**Record the Monitor's task id** to `.claude/teamlead/.state/plan-watch` as soon as
you start it, so you can still stop it after a compaction has wiped your memory of
the id.

### The watcher follows who has control

The watcher exists to catch *the user's* edits. While **you** hold control there are
none to catch, and your own multi-edit writes will trip it — writing a whole
implementation plan takes several edits over more than the settle delay, so the
watcher fires mid-write, compares against a snapshot you have not refreshed yet,
and reports your own work as theirs.

So hand the watcher back and forth with control:

| moment | do |
|---|---|
| Stage 2, file created | **start** the watcher, record its task id |
| User sends **"Go"** (→ stage 4) | **TaskStop** it, delete `.state/plan-watch` — you are writing now |
| Stage 4 written, footer shown | **start** it again, record the new id — the user may want to change the plan |
| User sends **"Go"** (→ stage 5) | **TaskStop** it, delete `.state/plan-watch` — planning is over |
| Stages 5–7 | stays off — the plan is frozen intent now; findings go on the board |

Stop it on leaving plan mode by any other route too; a monitor otherwise outlives
the mode.

**Cancelling a plan is one of those routes.** If the user calls it off mid-way:
stop the watcher, delete `.state/plan-watch`, clear `.state/active-plan`, and run
`board.py forget --project "$PWD"` — a scout killed mid-plan emits no stop event
and would otherwise be counted as working for hours.

**This does not weaken the safety net.** The watcher is convenience — the
correctness rule is unchanged: re-read and compare before every write, and merge
first if the file moved. That still catches a user edit made while the watcher is
off.

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

## Done when
- [ ] A concrete, checkable condition — *verified by: agent* (`pytest -q` passes)
- [ ] Something only a person can judge — *verified by: user*

## Implementation plan
*Built from D1–D5 · decisions:a3f9*

| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | … | `tl-sonnet-medium` | *(read-only)* | — |
| 2 | I2 | … — **D1** | `tl-sonnet-high` | `src/x/` | I1 |

## Open questions
1. The question?
   *Suggest:* what you'd do — *why, in one line.* *Or:* the real alternative and its cost.
   > me: 

### Answered
- ~~Old question~~ → answer → **D1**

## Notes from me
Theirs to write. You only ever remove a line once it is folded into a Decision.
```

**`## Done when` and `## Implementation plan` do not exist until stage 4.** Create
the file with the other five sections only, and insert both *above* `## Open
questions` when you write them.

**Why there.** The last two sections are the user's half of the file — the only ones
they type into. They stay at the bottom, where they are quick to scroll to and easy
to append to, with nothing large growing underneath them. A wave table parked below
the boxes they are typing in pushes their half of the file out of reach, and an empty
stage-4 header sitting there from stage 2 is worse: it is a placeholder in their way
for the entire time they are actually writing.

**Same wave = runs in parallel.** No prose annotations like *"parallel with I2"* —
a dependency column plus a prose note is two sources of truth that can disagree.

**`Owns` is the load-bearing column**: the write scope handed verbatim to the
worker. Without it "parallel" is an assertion, not a proof — two steps both
writing `api/routes/` is the one-writer-per-file violation everything rests on
avoiding. Read-only steps own nothing and are always safe to fan out.

Leave each question a `> me: ` line to answer on — **with one trailing space**, so
the cursor lands in the right place when the user clicks at the end of it. Write it
empty; an empty one is a placeholder, not an answer.

## Never ask a bare question

Every open question carries what **you** would do about it. You have read the code
and they have not; a question with no recommendation hands the thinking back to the
person with less context, and the usual answer to one is *"I don't know, what do you
think?"* — a whole round trip to get to where you should have started.

```
1. Rate limit per API key or per IP?
   *Suggest:* per key — *most traffic is server-side and shares IPs, so per-IP would
   throttle unrelated customers together.* *Or:* per IP if you expect browser traffic.
```

- **`*Suggest:*`** — your pick and the one-line reason. Add **`*Or:*`** when there is
  a real alternative, with what it costs. Say so when it is just convention:
  *"usually done as X"* is useful information.
- **`*Your call:*`** — for the questions you genuinely cannot answer: their
  priorities, their deadline, something only they know. Say what you'd need to
  decide it yourself. Use it honestly; a suggestion you made up to fill the slot is
  worse than admitting the question is theirs.

This is a suggestion, not a decision. Do not write it into `## Decisions` and carry
on as though it were answered — it stays an open question until they answer it.

## Decide "done" once the decisions are made

`## Done when` is written at **stage 4**, with the implementation plan and from the
same settled decisions. Criteria are what the decisions imply — written while the
Goal still says `TBD` they only get written twice — so derive them from `## Decisions`
the same way the wave table is, and every item names **who verifies it**:

| verifier | for | example |
|---|---|---|
| `agent` | anything with an objective answer | tests pass, the endpoint returns 200, every page has a meta description |
| `user` | anything needing judgement or eyes | it reads well, the layout looks right, this is the behaviour I meant |

**Writing it last has one failure mode**: by stage 4 both of you want to be finished,
and `agent` is the verifier that closes the plan fastest. Two things keep it honest.
Every criterion traces to a decision or the Goal, so the list is derived rather than
invented at the end. And the user reads it at the stage-4 review, before the second
"Go" — call the list out there, because that review is their chance to say a
criterion you marked `agent` is one they want to look at themselves.

**Prefer `agent`, but do not fake it.** If a criterion cannot be checked
mechanically, marking it `agent` does not make it verified — it makes the
verification a guess with a tick next to it. Say `user` and let it wait.

## Stage 6 — Agent-Testing

When the board is empty and every implementation step has merged, set the header to
`> **Stage 6**` and work the `verified by: agent` list:

1. **Really run them.** A command, a request, a test — actually execute it. Do not
   reason about whether it would pass; a criterion you argued your way through is
   not verified, and the whole point of splitting `agent` from `user` was to make
   this half mechanical.
2. **Tick each box** in `## Done when` and report the evidence next to it — the
   command and its output, not "confirmed".
3. **A failure is a task, not a caveat.** Put it back on the board, return to stage
   5, and come back. Do not carry a broken criterion forward as a footnote.

Only when every `agent` box is ticked does stage 6 end.

## Stage 7 — User-Testing

Set the header to `> **Stage 7**` and hand over the `verified by: user` list. Say
what you already verified, then give them their list and **stop**.

**This is the third place in plan mode where the user is the only way forward** —
the same rule as the two "Go" gates, for the same reason. Never tick a `user` box
yourself. Never read silence, a thumbs-up on something else, or your own confidence
in the code as a pass. Never ask "shall I archive this now?" as a way of getting
the answer — present the list and wait for them to actually report back.

Whatever they find goes back on the board and the plan returns to stage 5. A plan
can cycle 5 → 6 → 7 → 5 as many times as it takes; that is the mode working, not
the mode failing.

If a plan has no `user` criteria at all, stage 7 is still theirs: say the agent
checks all passed, say there is nothing needing their eyes, and let them close it.

## Retiring a finished plan

Once the user closes out stage 7, archive it — never delete it. A plan is the record of *why* the code looks the
way it does, and that outlives the work:

```
$(cat .claude/teamlead/.state/plugin-root)/scripts/plan-archive.sh <plan-file> --project "$PWD"
```

It datestamps the file into `.claude/teamlead/plan/done/YYYY-MM-DD-<topic>.md`,
stops the watcher, and clears `active-plan` and the snapshot. Say where it went.

It **refuses** a plan with an unticked `Done when` box, or with no criteria at all —
step 1–3 above are not optional, and filing a plan away is exactly how the last
unfinished item gets lost. If the user drops a plan instead of finishing it, pass
`--abandon`; it files it as `YYYY-MM-DD-abandoned-<topic>.md` so the history says
which it was.

## Everything ends up in Decisions

`Open questions` and `Notes from me` are **inboxes, not storage**. A finished plan
has both empty, with every one of their contents folded into `## Decisions` (or, if
it changes what is being built at all, into `## Goal`).

| input | becomes |
|---|---|
| A `> me:` answer | a Decision, plus the question struck into `### Answered` pointing at it (`→ **D4**`) |
| A chat answer | the same — the channel does not matter |
| A line in `Notes from me` | a Decision (or a `Goal` edit), then **removed from Notes** once it is safely represented |

**Folding is not transcription.** An answer or a note can raise something new — a
constraint that conflicts with an existing decision, an assumption that turns out
to be untested, a scope change. When it does, **write the new open question**.
Questions going *up* after an answer is normal and good; it means the answer
taught you something.

**The one thing you may write in `Notes from me` is nothing.** Never add your own
content there, never rewrite a note — but once a note is folded into a Decision,
remove it, and say in one line which Decision it became. Do that when you are
already editing in response to the user, never while they may be mid-sentence, and
apply the usual re-read-before-write rule. A note you cannot fold yet stays put and
becomes an open question instead.

**Definition of done for the plan:** `Open questions` holds nothing unanswered,
`Notes from me` is empty, `Goal` is not `TBD`, and every decision is referenced by
an implementation step. `plan-lint` enforces all four at stage 4 — a plan that
still has an inbox is not finished being planned.

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

**Leave `.claude/teamlead/.state/active-plan` set.** It used to be cleared here, and
that is what made the session dangle: implementation would start, plan mode would
quietly vanish, and a plan that was not actually finished looked like no plan at
all. The pointer now survives stages 5–7 and is cleared by `plan-archive.sh` at the
very end. Update the header to `> **Stage 5**` so the status line tracks it.

**Plan is frozen intent; board is live state.** When execution diverges, record it
on the board — never silently patch the plan. Losing the fact that reality
departed from the plan loses the interesting part.
