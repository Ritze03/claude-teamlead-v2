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
| **3 Work it out** | Scout, then ask what they want out of this — one question — and derive the specific questions from their answer. Update the header to `> **Stage 3**`. Back-and-forth until "Go". | The user says "Go" |
| **4 Done when + implementation plan** | You alone write the acceptance criteria and the wave table, inserting both **above `## Open questions`**. Then **stop again** — the header can't move to 5 without it; `plan-fence.sh` refuses the bump until a "Go" is recorded. | The user says "Go" |
| **5 Build** | Translate into `board.md` and execute. Update the header to `> **Stage 5**` — `board-fence.sh` refuses `board_add` until this header is set. | Every task merged, board empty |
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
becomes `Stage 3` when you post that first question and are genuinely waiting on it.

**"Go" advances exactly one stage.** From 3 it means *write the implementation
plan, then stop*. From 4 it means *start implementing*. One word, never a skip
straight to execution — your plan of *how* is separate work from their plan of
*what*.

This used to be pure discipline; `plan-fence.sh` now enforces the shape of it.
It refuses a header bump of more than one stage at a time (recording the last
accepted one to `.state/plan-stage`), and refuses 3→4 or 4→5 unless
`.state/plan-go` has an entry newer than that last accepted bump. So a skipped
stage is not a discipline failure any more — it is a refused tool call. When the
edit comes back refused, do not work around it: the user has not actually said
Go.

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
  *not* a Go. Go comes from chat — literally: `mode.sh` watches the *chat* prompt
  for the word "go" and logs it to `.state/plan-go`; a "Go" typed into the file is
  never seen by that hook.

Instead, end every planning turn with one **fixed** line, set off from the body:

- Stages 1–3: `Type "Go" if you want me to plan the implementation.`
- Stage 4 only: `Type "Go" if you want me to start implementing.`

**Byte-identical every turn.** The moment it tracks your sense of progress —
*"Type Go, I think we're about there"* — it becomes the banned question again.
A static line is not you judging readiness; it is the command staying visible.

**`gate.sh` checks it.** It reads the transcript at Stop; at stages 1–4, a turn
whose last line is not this exact text is blocked. That is the other reason it
is byte-exact — a paraphrase reads fine to a person and fails a string compare.

## Stage 3 opens with a scout

Before asking the user anything, dispatch scouts to gather what the repo can
answer. Findings go in `## Context`. Research first, questions second — never ask
what you could have looked up.

## Stage 3 asks one question first, and derives the rest

After the scout reports, the **only** thing you ask is what the user actually wants
out of this. One open question, in chat and in `## Open questions`. Nothing else
goes with it.

Do **not** open stage 3 with a list of questions worked up from the topic. A topic
plus your own reading generates the questions *you* found interesting; handing those
over as a menu makes the user read five of yours to reach the one that was theirs,
and the one that was theirs may not be on the list at all. The scout tells you what
the repo is. It does not tell you what they want.

So the order is: **scout → ask what they want → derive the specific questions from
their answer.** The detailed questions come out of what they say, not out of the
topic. Once their answer is in hand you almost always have fewer questions than you
would have invented, and every one of them is load-bearing — an ambiguity their
answer actually created, not one you supplied.

Write that first question the same way as any other (see *Never ask a bare
question*): your `*Suggest:*` for what this probably is, or `*Your call:*` when it
is genuinely only theirs. It is numbered like any other question and it keeps that
number for the plan's life — the questions you derive next simply continue the
sequence (see *Everything ends up in Decisions*). Nothing is ever renumbered.

Everything else about stage 3 is unchanged: the watcher is running, they can answer
in chat *or* type into the file and save, and either channel folds the same way.

The scout reports facts — file:line, what exists, what is already enforced and
where — never improvement proposals or a change list. Those come only from a
brainstorm the user actually asked for (see *Brainstorm request*, below).

The scout runs **after** the path is on screen, never before it (see *Order inside
the first turn*). An empty repo is not a reason to skip scouting — scout the
machine instead: language runtimes, build tools, what is actually installed. That
is the context a greenfield choice turns on.

## Sharing the file with the user

They have it open; you write to it between turns. Without discipline this eats
their work.

- **Targeted edits only, never full-file rewrites.** Re-read before every write.
- **Write it with the Edit/Write tools — never through shell** (`sed`, a heredoc,
  python). `plan-fence.sh` only sees writes made through the file tools; an edit
  that bypasses it is an edit nobody checked, the two rules below included.
- **`## Notes from me` is theirs to write.** Never add your own content there and
  never reword a line; the only edit you make is removing a note once it is folded
  into a Decision (see *Everything ends up in Decisions*). `plan-fence.sh` refuses
  any add or reword there outright; removing a folded note still goes through.
- After every write of yours, refresh the snapshot so the watcher stays quiet:
  `cp <plan> <project>/.claude/teamlead/.state/snap/<file>`
- If the file changed since you last read it, they edited it — **merge first**.
  The watcher is convenience; this check is correctness.
- **Collapse blank runs after every write.** Striking a question into
  `### Answered` or removing a folded note leaves empty lines behind, and
  `plan-lint` fails on two or more consecutive blank lines anywhere in the file.
  A `cat -s`-style squeeze (or a `re.sub(r'\n{3,}', '\n\n', text)`) right before
  you save is enough — do it every time, not just when lint catches it.

**The clobber.** The user's editor can save from a stale buffer and silently
revert a line you added seconds earlier — the watcher's diff then shows a `-`
line of *your own* text. That is not the user deleting it; it is a stale buffer
winning a race. Re-apply it the same way as any other divergence: re-read,
merge your line back in, write. Observed today.

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

Each save emits a diff plus any lint failures. It needs `inotifywait`
(inotify-tools, Linux only). If the watcher can't start for that reason, there is
no watcher — re-read the plan file before every write instead, and tell the user
their edits are picked up on their next message rather than live.

Starting it while one is already running is safe: the script kills the previous
watcher itself, so there is never more than one instance. That is also how you
re-arm it — the Monitor tool expires after ~30 minutes, and re-arming is just
starting `watch-plan.sh` again.

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

## Brainstorm request
Initial brainstorm [y/n]: 

## Notes from me
Theirs to write. You only ever remove a line once it is folded into a Decision.
```

**`## Done when` and `## Implementation plan` do not exist until stage 4.** Create
the file with the other five sections only, and insert both *above* `## Open
questions` when you write them.

**Why there.** The last three sections — `Open questions`, `Brainstorm request`,
`Notes from me` — are the user's half of the file, the only ones they type into.
They stay at the bottom, where they are quick to scroll to and easy to append to,
with nothing large growing underneath them. A wave table parked below the boxes
they are typing in pushes their half of the file out of reach, and an empty
stage-4 header sitting there from stage 2 is worse: it is a placeholder in their way
for the entire time they are actually writing.

**Same wave = runs in parallel.** No prose annotations like *"parallel with I2"* —
a dependency column plus a prose note is two sources of truth that can disagree.
The table may also group waves under phase rows for a large plan — see *Phases
split a big plan*, below — but that is the exception; most plans are one phase
and this table as shown.

**`Owns` is the load-bearing column**: the write scope handed verbatim to the
worker. Without it "parallel" is an assertion, not a proof — two steps both
writing `api/routes/` is the one-writer-per-file violation everything rests on
avoiding. Read-only steps own nothing and are always safe to fan out.

**`## Brainstorm request` starts with one line**, written at stage 2 alongside the
other sections: `Initial brainstorm [y/n]: ` — lowercase `n`, no default; the user
answers `y` or `n`. `y` runs the brainstorm and the line goes; `n` means you remove
the line and leave the section empty. Left unanswered, it stays through **all** of
stage 3 untouched alongside the questions — stage 2 auto-advances into stage 3, so
there is no moment to answer it before the questions land. Only at the 3→4 bump,
if it is still unanswered, do you drop the line and leave the section empty — the
offer lapses, not the section. It stays available for the rest of
planning: writing `initial brainstorm` under it at any later stage runs a full
brainstorm over the plan as it stands then, exactly as answering `y` would have;
anything else written there is a focused brainstorm on that topic instead.
`plan-lint` treats the section as optional but requires it empty by stage 5 — run
it or clear it (see *Brainstorm request*, below, for what running one does).

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

## Brainstorm request

A brainstorm is asked for two ways: in chat ("brainstorm the caching approach") or
by writing under `## Brainstorm request` in the file — `initial brainstorm` for a
full pass over the plan, anything else for a focused one on that topic. It is a
stage-3/4 feature; there is nothing worth brainstorming before `## Context` and
`## Decisions` exist.

Ask one or two clarifying questions in chat first if the topic is ambiguous, then
dispatch read-only agents (`tl-sonnet-medium`, no worktree — they never edit the
plan) over the plan file. Brief them to hand back suggestions already in the
open-question format: each a `- ` item with `*Suggest:*` / `*Or:*` and one empty
`> me: ` line. That is what lets you merge their output straight into
`## Open questions` without rewriting it, then clear `## Brainstorm request`.

This is lighter than the `/teamlead brainstorm` skill — one round, read-only,
scoped to this plan file, not the multi-round general-purpose mode.

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

## Phases split a big plan

The wave table can group waves under phase rows when the user asks for it, or
when the changes are unrelated enough that one big table would push all testing
to the very end:

```markdown
| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| — | **A** | **Bold phase title** | | | |
| 1 | I1 | … | `tl-sonnet-medium` | *(read-only)* | — |
| — | **B** | **Next phase title** | | | |
| 2 | I2 | … | `tl-sonnet-high` | `src/x/` | I1 |
```

A phase row carries no wave number, agent, `Owns` or `After` — it only labels.
Waves keep numbering across the whole table; they do not restart per phase.
`## Done when` items may carry the same grouping, a bold `**Phase A — …**` line
above the criteria it covers. `plan-lint` ignores phase rows entirely in its
dependency and `Owns` checks — they carry nothing to validate.

With phases, stages 5→6→7 run **per phase**: phase A's tasks merge, get
agent-tested, get user-tested, and only then does the header return to stage 5
for phase B. Say which phase in the header's body line —
`> **Stage 5** — building phase B (I9–I14) · started <date>` — so the status
line and a resumed session both know where you are. `board.py check` only
requires the *current* phase's `I<n>` rows on the board — it finds the current
phase by which one already has a step there, so nothing complains that phase C
hasn't been added yet.

## Stage 6 — Agent-Testing

When the board is empty and every implementation step has merged, set the header to
`> **Stage 6**` and work the `verified by: agent` list:

1. **Really run them.** Dispatch the runs to a worker like any other work — a
   command, a request, a test, actually executed, not reasoned about. A criterion
   you argued your way through is not verified, and the whole point of splitting
   `agent` from `user` was to make this half mechanical.
2. **Tick each box from the worker's report**, and record how, on the same line:
   `` - [x] <criterion> — *verified by: agent* — ran `cmd` → result ``. `plan-lint`
   at stage ≥ 6, and `plan-archive.sh`, both reject a ticked agent item with no
   `` ran `...` `` on it — a bare `[x]` is indistinguishable from a guess.
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
the answer — present the list and wait for them to actually report back. Offering
archiving comes only after they have confirmed (see below).

Whatever they find goes back on the board and the plan returns to stage 5. A plan
can cycle 5 → 6 → 7 → 5 as many times as it takes; that is the mode working, not
the mode failing.

If a plan has no `user` criteria at all, stage 7 is still theirs: say the agent
checks all passed, say there is nothing needing their eyes, and let them close it.

## Retiring a finished plan

Once the user closes out stage 7, tell them everything is done and that the plan can be
archived — say "archive it" and I will, or they can run the command below. **Never archive
on your own**: their confirming the stage-7 checks is not a request to archive. Run
`plan-archive.sh` only when they explicitly ask. Archive, never delete: a plan is the record of *why* the code looks the
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

**Numbers are stable for the plan's life.** A question keeps its number when it is
struck into `### Answered`; new questions continue the sequence — never renumber
or reuse a spent number, since "1" and "7" must mean the same question next turn
as they do now. `plan-lint` refuses any `## Open questions` number that repeats
an answered number or another open one.

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

Copy **all waves of the current phase** into `.claude/teamlead/board.md` in one
`board_add` call, column for column: `plan: I<n>` set on each row — that field
is the actual link back to the plan step; board.py renders it as the `— I<n>`
suffix on the task text — and `blocked_by` copied from the `After` column, by
mapping each `I<n>` named in `After` to the board id of that step's row (add
the rows in wave order so `board_add`'s returned ids are available to
reference — it assigns them in the order given, and takes several tasks in one
call; if a task's `After` names a step whose row already exists from an
earlier `board_add`, use that existing id). This is safe because overlapping
`Owns` between two unfinished rows is allowed exactly when one is in the
other's `blocked_by` chain, and a row cannot go `running` or `merged` while
any blocker is unmerged — so the wave order is enforced by the board itself,
not by the lead remembering it. `board-fence.sh` refuses `board_add` while the
plan is below stage 5, so nothing can land early. And once you're here,
`board.py check` (run every turn by the gate) reports any current-phase
wave-table step with no matching board row, so a half-copied table does not
go unnoticed.

Phases still go **one at a time**: board only the current phase's waves. The
next phase is boarded only after the current one has passed stage 7 and the
header is back at stage 5 — stage 6/7 testing between phases is the point.

**Leave `.claude/teamlead/.state/active-plan` set.** It used to be cleared here, and
that is what made the session dangle: implementation would start, plan mode would
quietly vanish, and a plan that was not actually finished looked like no plan at
all. The pointer now survives stages 5–7 and is cleared by `plan-archive.sh`, which
runs only when the user asks for it. Update the header to `> **Stage 5**` so the status line tracks it.

**Plan is frozen intent; board is live state.** When execution diverges, record it
on the board — never silently patch the plan. Losing the fact that reality
departed from the plan loses the interesting part.

## The second Go: offer a fresh context

The second "Go" (stage 4 → 5) is also D14's handoff point: building is cheaper
in a small context, and the plan file plus the board were designed to be the
whole handoff. In this order:

1. Set the header to `> **Stage 5**`.
2. Print, **byte-exact**, on its own paragraph:

   ```
   To build this on a fresh context: `/clear`, then `/teamlead plan continue`.
   Or say "here" to continue in this session.
   ```

3. **Stop — dispatch nothing.** Wait for the user to say "here", or for the plan
   to be picked up again via `/teamlead plan continue`. Never run `/clear`
   yourself.

## `/teamlead plan continue`

The general "pick the plan back up" command — after the fresh-context handoff
above, after a compaction, or just a new day. Nothing is re-derived from
memory; the plan file and the board are the whole handoff (D14):

1. Read the state block's plan lines — `stage`, `go`, `next` — printed at
   session start and on activation by `state.sh`.
2. Read the plan file **in full**, not just the header.
3. Act on `next` for that stage:

| Stage | Action |
|:----:|---|
| 3 or 4, with a recorded Go | The user already said Go — write the implementation plan (3) or start implementing (4). |
| 5 | Put **all of the current phase's** wave rows on the board — when the table has no phase rows, the whole table counts as one phase — (`board_add`, `plan: I<n>`, `blocked_by` from `After`) if they are not there yet — `board.py check` names any that are missing — then dispatch. |
| 6 | Run the `verified by: agent` criteria for real. |
| 7 | Hand the `verified by: user` criteria back to the user. |

If the state block shows the watcher **NOT running** and the stage is 2–4,
restart it first — see *The watcher follows who has control*.
