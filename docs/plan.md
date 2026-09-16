# teamlead-v2 — implementation plan

Living document. Started 2026-08-30. Companion to `docs/enforcement.md` (what the harness
can mechanically enforce). This file is *what we're building and why*; that one is *what's
possible*.

Status key: **DECIDED** · **OPEN** (needs a call) · **LATER** (deliberately deferred)

---

## 0. Core philosophy

> A smart lead that **thinks** + cheap sub-agents that **implement** is the efficient shape.

Everything below follows from this. Two consequences worth naming, because they're easy to
lose:

1. **The lead's context is the scarce resource.** It's the expensive model and the only one
   holding the whole picture. Anything that can live on disk instead of in its head, should —
   task state, worker results, settings, resolved routing. This is not a tidiness preference,
   it's the main performance lever.
2. **Workers are cheap and disposable.** Default to Sonnet. Opus is escalation, not a first
   choice. The lead does the reasoning that justifies its price; workers do the typing.

### 0.1 Platform — **DECIDED: Linux only**

v2 targets Linux, deliberately. macOS and Windows are not supported and not planned. The live
plan-file watch (§5) is built on `inotify`; carrying a portability layer for a personal tool
buys nothing. `inotify-tools` is a hard dependency, not a soft one — no mtime-poll fallback
gets written.

Stated up front in the README so nobody installs it on a Mac and finds a plan mode that
silently never notices their edits.

---

## 1. What v1 actually gets wrong

Not the thing we assumed. Measured against how the tool is actually used (always-on
orchestration mode, long sessions, regular compaction, all four modes in use):

| Reported failure | Root cause |
|---|---|
| Ignores its own todo list | State lives in conversation context |
| Worker returns, result evaporates | Same |
| Worktrees left behind | Same |
| Branches never merged back | Same |

**All four are one bug: the lead has no durable ledger.** Compaction hits regularly, and when
it does, everything the lead knew about in-flight work is gone. This is not disobedience and
prose cannot fix it — the model isn't ignoring a rule, it's forgetting a fact.

Secondary, real but smaller:

- **487-line SKILL.md doing five jobs.** Orchestration + plan + brainstorm + superdoc +
  settings wizard all load for every invocation.
- **Prose defending invariants.** The git log is a record of losing that fight
  (`make the activation check mandatory, not deferrable`).
- **The effort dial is a lookup table** the model re-derives on every routing decision.

---

## 2. The ledger — the spine of v2

**DECIDED.** Two files, different owners. The split is the point: you cannot verify a ledger
the model writes with a ledger the model writes — the same lapse that drops a result drops
the line recording it.

### `.claude/teamlead/board.md` — model-owned

The task list. Lead decomposes every substantive prompt into it, rewrites it in place, works
it off. Single file (one read = whole picture; a directory walk is worse for an LLM).

**Same table shape as the plan's implementation section (§5)** — one format to learn, and the
columns carry over directly when a plan is translated into a board.

```markdown
# Board — rate limiting for the public API

| ✓ | ID | Task | Agent | Owns | State | Branch |
|:-:|:--:|------|-------|------|-------|--------|
| x | 1 | Confirm endpoints share one entry point — I1 | `tl-sonnet-medium` | *(read-only)* | merged | — |
| x | 2 | Token bucket, Redis-backed — I2 | `tl-sonnet-high` | `api/limits/` | returned | wt/task-2 |
|   | 3 | Config schema + allowlist — I3 | `tl-sonnet-medium` | `api/config/` | running | wt/task-3 |
|   | 4 | Wire into decorator stack — I4 | `tl-sonnet-high` | `api/routes/` | blocked-by 2,3 | — |

## Done
*(capped at ~10; older entries live in events.log)*
```

**Columns.** `Owns` carries over from the plan and stays the worker's write scope — it is what
makes "one writer per file" checkable at execution time, not just at planning time. The
`— I2` suffix in `Task` is the link back to the plan step, using the same idiom the plan uses
for decisions (`— D1 D2`). Ad-hoc work with no plan behind it leaves the suffix off.

**States.** `queued` → `running` → `returned` → `merged`, plus `blocked-by N`. `returned` is
load-bearing: it is the state a task sits in after its worker finished but before the lead
acted on the result, which is exactly the window where work used to evaporate. The reconcile
gate (§3) fires when `events.log` records a return and the board still says `running`.

Single writer (the lead), so the read-modify-write is safe.

### `.claude/teamlead/events.log` — hook-owned, append-only

The model never writes or edits this. Hooks do.

```
2026-08-30T20:14:03  dispatch  task=2  agent=tl-sonnet-high  id=sub-a1
2026-08-30T20:19:41  return    task=2  id=sub-a1  branch=wt/task-2
```

`SubagentStart` appends the dispatch line, `SubagentStop` appends the return line — a few
lines of shell each. Short appends are atomic, so N workers returning at once can't clobber
it.

### Why two files pay for themselves

The **gap between them is the bug detector**. One comparison at `Stop` catches every reported
failure:

- events say `return`, board still says `running` → **work evaporated**
- board says `[x]`, no matching `return` event → marked done without being done
- `return` carried a branch, nothing recorded it merging → **never merged back**

With one file this check is unwriteable. There's nothing to compare against.

### Not per-task files

**DECIDED — rejected.** Fragments what the LLM needs holistically, and you'd end up
maintaining an index anyway. A task needing a real spec gets a doc the board line *links to*.

### DECIDED — board lifetime: live working set, not archive

**The board is never wiped.** Done tasks move to a `## Done` section capped at ~10; only
**open** items are re-injected after `/clear` or compaction. Anything older lives in
`events.log`.

Why not the alternatives:

- **Per-prompt wipe is actively dangerous.** A follow-up prompt sent while wave 1 workers are
  still running would wipe the in-flight tasks — reproducing "loses returned work" via the
  mechanism built to prevent it. Any heuristic for "is this a new job?" will eventually
  discard live work, so there is no job-boundary detection at all.
- **Fully cumulative is redundant.** `events.log` is *already* the permanent, append-only
  history and is never injected. Making the board carry history too means paying tokens to
  re-inject a growing done-list after every compaction, duplicating the one file that cannot
  lie.

Result: one file, one rule, no boundary logic, and **injection cost stays flat** however long
the session runs.

---

## 3. Enforcement — mechanism, not prose

Rule: **prose for judgment, hooks for invariants.** If breaking it should be *impossible*
rather than discouraged, it's a hook. Every hook must let us delete prose; if it doesn't, it
wasn't enforcing anything.

All hooks are registered statically and gated on a **project-scoped** flag file —
`${CLAUDE_PROJECT_DIR}/.claude/teamlead/.state/active`, first line
`[ -f "$FLAG" ] || exit 0`. Zero tokens, zero prompt-cache impact when inactive. Rationale in
`enforcement.md` §5c — but note §6 overrides that document's global `~/.claude/` path:
**no teamlead state is ever stored in the home folder.**

### The gates

| Gate | Event | Fixes |
|---|---|---|
| **Decompose** — prompt dispatched work but the board was never written | `Stop`, block once | "split prompts into task lists on its own", as mechanism |
| **Reconcile** — board and events.log disagree | `Stop`, block once | work evaporating, false completions |
| **Worktrees** — unmerged/dirty worker branches remain | `Stop`, block once | branches never merged back, leftover worktrees |
| **Restore** — re-inject open board items | `SessionStart(clear\|compact\|resume)` | the compaction problem, directly |
| **Record** — dispatch/return lines | `SubagentStart` / `SubagentStop` | makes the ledger unforgettable |
| **Mode** — own the flag, catch "stop teamlead", one-line role re-assert | `UserPromptSubmit` | mode survives, drift resisted |

**Interaction with planning mode:** the Decompose gate must **not** fire during a plan-mode
turn. Plan stages 3–4 legitimately dispatch scouts while writing a *plan* file, not a board —
the gate would false-positive on every planning round. It keys off the plan-mode state in
`.claude/teamlead/`, not just "did the board change".

### DECIDED — blocking, not warning

A `Stop` hook can only block **once per turn**; the retry sees `stop_hook_active: true` and
must let go, or it loops forever. So the strongest available behaviour is a **forced second
look, then it proceeds** — not a trapped session. Downside of a wrong block is one wasted
round-trip, which is cheap enough that warning (what v1 already does, and what's failing)
isn't worth it.

### DECIDED — visible ledger

Plain files in the repo at `.claude/teamlead/`, not hidden state. Not because they'll be read
often — because when the ledger is *wrong*, it can be opened and fixed instead of fought.
Invisible state that's occasionally wrong is worse than visible state that's occasionally
wrong.

**OPEN:** committed to git (trail survives, teammates see it) or gitignored scratch?

**Note:** a plugin **cannot** install a main status line (`enforcement.md` §6) — that would
mean shipping a script plus a manual `~/.claude/settings.json` line that breaks quietly.
Deferred; the files are the surface.

### LATER — deliberately not building

Per-agent `Stop` test hooks · `Agent` `updatedInput` forcing worktree isolation ·
`PreModelSwitch` veto · `ConfigChange` self-defence · `prompt`-type LLM quality judges.
Each fires on cases we can't predict, and the worker briefs already cover the first.
Revisit when a real failure demands one.

### DECIDED — no blanket lead edit ban

`PreToolUse` deny on `Edit|Write` when `agent_id` is absent (`enforcement.md` §7) was the
research doc's centrepiece. Dropped, for two independent reasons:

1. It is **not a reported pain.** The lead doing work itself never came up; the reported
   failures are all state-loss.
2. **It breaks planning mode** (§5), where the lead must write the plan file itself in a live
   conversation.

If it is ever wanted, it must carve out `.claude/teamlead/`. Not scheduled.

---

## 4. Context offloading

The lead's context is the scarce resource (§0). Two v1 sections that are pure context tax:

**Activation state → injected, not procedured.** Skill body `` !`…` `` runs shell before the
model's first token: git regime, worktrees, settings, open board items. Deletes the whole
"On activation — mandatory, runs before anything else" section, which the git log shows being
re-litigated three separate times. It stops being a rule and becomes a fact already present.

**Effort dial → resolved, not derived.** The 6-level × 3-mode routing table is a pure function
of two settings values. Compute it in ~20 lines of shell and inject the answer:

```
Workhorse: tl-sonnet-medium · Scout: tl-sonnet-low · Escalate: tl-opus-low→medium · Banned: *-high
```

Three names instead of two tables. ~60 lines of prose gone, and a class of routing mistakes
with it. The dial itself stays — it's used, set per project, occasionally retuned.

---

## 5. The four modes

All four are in active use. None get dropped.

### Orchestration (core) — the always-on mode

The main rework target. Gains the ledger, loses the activation prose and the dial table.
Target: **~120 lines**, down from 487.

### Planning mode — **DECIDED (shape), open details**

Interactive by design: the lead and the user work a plan out together in a file the **user
keeps open in their own editor**. The lead prints the full absolute path once so it can be
copy-pasted, and **never tries to open it for the user**.

Plan files live at `<ProjectDir>/.claude/teamlead/plan/<Topic>.md`.

**Stages**

1. **Topic.** Lead asks what's being planned; derives the filename from the answer.
   If the file already exists → offer to **continue** it, never silently overwrite.
   ("Resume planning on X" then comes free, across sessions.)
2. **Open it.** Lead creates the early-stage (near-empty) plan and prints the absolute path.
   User opens it. Lead does not.
3. **Work it out.** Back-and-forth between user and lead, plan rewritten as answers land.
   **Opens with a scout wave** — dispatch workers to gather what's knowable from the repo
   *before* asking the user anything. Research first, questions second. Without this the lead
   asks questions it could have answered by looking, which is v1's stated rule and worth
   keeping.
4. **Implementation plan.** Lead's turn alone: workflow, stages, which agents, what runs in
   parallel. This is the reasoning the expensive model is *for*. User reviews it in the file.
5. **Go.** User gives the word; lead translates the plan into `board.md` and execution begins.

**Never assume planning is finished.** The default state of a plan is *unfinished*. The lead
does not decide the plan is done, and does not ask whether to start implementing — it keeps
planning until the user says otherwise. Explicitly banned:

- "The plan looks complete — shall I start?" — the banned question in a coat.
- "I think we've covered everything." — the implicit version.
- Treating **silence** as consent.
- Treating a **file save** as consent. The watcher makes the plan file an input channel, so
  "looks good to me" typed into `## Notes from me` is *not* a Go. Go comes from chat only.

**Two gates, one word.** If the lead may neither assume nor ask, stage 3 → stage 4 would be
unreachable, since both ways of advancing are banned. Resolution:

| From | User says | Lead does |
|---|---|---|
| Stage 3 | "Go" | Writes the **implementation plan** (stage 4) — then **stops again**. |
| Stage 4 | "Go" | Translates to `board.md` and **executes** (stage 5). |

So one word always means "advance exactly one stage." The lead structurally cannot skip its
own planning stage on the way to execution, which is the point — the lead's plan of *how* to
implement is separate work from the user's plan of *what* to build.

**The static footer.** Every planning turn ends with one fixed line, set off from the message
body so it reads as chrome rather than the lead speaking:

- Stages 1–3: `Type "Go" if you want me to plan the implementation.`
- Stage 4, once the implementation plan is actually written:
  `Type "Go" if you want me to start implementing.`

This is what makes the never-ask rule livable: a **static** line is not the lead judging that
the plan is ready, it is just the available command staying visible. The banned behaviour was
the lead forming an opinion about readiness and voicing it.

**Sameness is the load-bearing property.** The moment the wording tracks the lead's sense of
progress — *"Type Go — I think we're about there"* — it becomes the banned question again.
Byte-identical every turn, or it does not work.

Prose, not a hook: the failure mode is benign (the user types Go regardless), and fixed text
is the one thing a model cannot get subtly wrong.

**Enforceable half:** writing `board.md` while plan mode is active with no recorded Go →
`PreToolUse` deny. Execution starting early is the actual harm; the rest is judgment and stays
prose.

**The lead writes the plan file itself.** Deliberate carve-out from "never do the work
yourself" — dispatching a worker per one-line edit during a live conversation is unusable
latency. This **answers §8 item 3**: a blanket `Edit|Write` deny would break plan mode, so it
is either dropped or carved out for `.claude/teamlead/`.

**Concurrent-edit discipline.** The user has the file open; the lead writes to it between
turns. Without a rule this silently eats work.
- Lead uses **targeted edits, never full-file rewrites**, and re-reads before every write.
- The file carries a `## Notes from me` section the lead **never touches** — a safe place for
  the user to type.

**Live file watch.** *(Built and verified — see `hooks/watch-plan.sh`.)* The plan file is a
*second input channel*: the user edits it in their
editor and the lead reacts without being spoken to.

Primitive: the **`Monitor` tool with `persistent: true`** — the "one notification per
occurrence, indefinitely" case. Not Bash `run_in_background`, which fires once and exits and
would need re-arming after every save. `inotifywait` (inotify-tools) is the watcher.
**No portability fallback** — see §0.1.

Three rules, each fixing a specific failure:

1. **Watch the directory, not the file.** vim and VS Code save atomically — write temp,
   rename over target — which replaces the inode. A watch on the file silently stops working
   after the first save. `-e close_write,moved_to` on the dir, filtered by filename.
2. **Never stop the watcher to edit.** The obvious design (stop → edit → restart) opens a
   blind window: a user save landing mid-edit is clobbered *and* generates no notification,
   which is exactly the failure the watch exists to catch. Instead leave it running and
   suppress the echo **by content** — keep a `.snapshot`, emit only when the file differs
   from it, and have the lead update the snapshot after its own writes.
   That single rule also debounces for free: an autosave-per-keystroke editor firing five
   times emits once, because saves 2–5 match the snapshot. Necessary, because Monitor
   auto-stops watchers that emit too many events.
3. **Emit the diff, not "it changed."** The wake-up carries what the user actually wrote, so
   it is actionable without re-reading the file.
4. **Settle for 2s before comparing.** *(Found in testing.)* The lead writes the file and
   *then* refreshes the snapshot; those are two operations, and inotify fires in the gap.
   Without the pause the lead's own edit is reported as a user edit on every single write. The
   same pause collapses autosave bursts.

```bash
# ponytail: dir watch — editors save by rename, a file watch misses it
D="$PWD/.claude/teamlead/plan"; F="Topic.md"
inotifywait -m -q -e close_write,moved_to --format '%f' "$D" | while read -r f; do
  [ "$f" = "$F" ] || continue
  cmp -s "$D/$F" "$D/.snapshot" && continue      # unchanged: our own write, or a repeat save
  diff -u "$D/.snapshot" "$D/$F" | head -40
  cp "$D/$F" "$D/.snapshot"
done
```

**The watcher is convenience; the pre-write comparison is correctness.** Safety never depends
on a background process staying alive. The lead re-reads and compares before every write
regardless — the watch only means it finds out immediately rather than on its next turn.

**Teardown.** A persistent Monitor lives until `TaskStop` or session end. Leaving plan mode
must stop it, or it outlives the mode it belongs to.

**Plan → board handoff.** Plan is **frozen intent**; board is **live state**. Board lines link
back to a plan section. When execution diverges from the plan, that is recorded on the board
and *not* silently patched into the plan — otherwise the fact that reality departed from the
plan (usually the interesting part) is lost.

**Not one-shot.** Unlike v1, plan mode ends by handing off into persistent orchestration mode
at stage 5.

**Compaction-proof by construction:** the plan file *is* the durable state, so `restore.sh`
only needs to re-inject the active plan's path, not its content.

### Plan file structure — **DECIDED**

Fixed section order, always the same, so the user learns it once. Derived from what has
actually worked in this document: decisions accrete, questions get struck and moved to an
Answered list.

```markdown
# <Topic>

> **Stage 3** — working it out · started 2026-08-30
> Typing "Go" now → I write the implementation plan.

## Goal
One or two lines. What "done" looks like. `TBD` until stated.

## Context
Constraints, what already exists, what must not break.
Scout findings land here — this is where stage 3's research goes.

## Decisions
Accreting, numbered, never deleted. The call plus one line of why.

- **D1** Board is a live working set, not an archive — *events.log already holds history.*

## Open questions
Numbered. Answered in chat, or inline with a `> me:` line.

1. Which auth provider are we targeting?
   > me: we already run Authentik
2. TBD

### Answered
- ~~Does this need to work offline?~~ → No, always-online. → **D1**

## Notes from me
User-owned. The lead never writes here.

## Implementation plan
*(empty until stage 4)*

| Wave | ID | Task | Agent | Owns | After |
|:----:|:--:|------|-------|------|-------|
| 1 | I1 | … | `tl-sonnet-medium` | *(read-only)* | — |
| 2 | I2 | … — implements **D1** | `tl-sonnet-high` | `src/x/` | I1 |
| 2 | I3 | … — implements **D5** | `tl-sonnet-medium` | `src/y/` | I1 |
```

Why each choice:

- **Header answers "what happens if I type Go right now."** The file is reopened across many
  turns and sessions; which of the two gates (stage table above) you are at is otherwise only
  recoverable by scrolling chat.
- **Decisions and Open questions both accrete, separately.** The decision list is the
  compressed output of all the back-and-forth — it is what makes the file worth re-reading.
  Struck questions point at the decision they produced, so *why* something was settled
  survives, not just that it was.
- **Inline `> me:` answers.** Where the file watch earns its keep: the user answers in their
  editor, saves, and the diff wakes the lead with the answer already in context. The lead
  promotes it to a Decision and strikes the question. No retyping between channels.
- **`TBD`** is the missing-marker (kept from v1). Greppable — "what is still unanswered" is
  one command.
- **Step IDs `I1`/`I2`** are the board's link target: board task lines carry
  `plan: <Topic>.md I2`. Frozen intent stays connected to live state without duplication.

**The implementation plan is a table, and parallelism is a column.** Same wave = runs
together. No prose annotations like *"parallel with I2"* — a dependency list plus a prose
note is two sources of truth that can disagree.

`Owns` is the load-bearing column and the one an earlier draft was missing: it is the write
scope handed verbatim to the worker, and **without it "parallel" is an assertion rather than
a proof**. Two parallel steps both writing `api/routes/` is the "one writer per file"
violation that the whole design rests on avoiding, and it is invisible unless ownership is
declared. Read-only steps (scouts, QC) own nothing and are therefore always safe to fan out.

**Four checks, all mechanical graph operations over the table — no judgment:**

1. Every `After` target sits in a **lower-numbered wave**. Catches a dependency scheduled
   alongside the thing it needs.
2. No two rows in the same wave have **overlapping `Owns`**. The parallel-safety proof.
3. Every row has an agent tier — no blanks.
4. Every decision `D*` appears in at least one `Task`, or is explicitly recorded as needing no
   code. Catches "agreed it, then forgot it."

### Plan file consistency — `hooks/plan-lint.sh`

A plan file does not go wrong at the moment it is written; it goes wrong **later**, when a
decision moves and an earlier section is not revised. It still reads as authoritative. Nothing
surfaces the contradiction unless someone happens to look.

*(This is not hypothetical — it happened to this very document: the board format in §2 was
settled, §5 later changed the linking scheme, and the two disagreed silently until a manual
re-read caught it.)*

So the checks are **not a stage-4 ritual**. They are a linter that runs on every write.

**Checks** — pure text operations over one file, no judgment:

1. The six sections are present, in the fixed order.
2. Every `After` target exists and sits in a **lower-numbered wave**.
3. No two rows in one wave have **overlapping `Owns`** — the parallel-safety proof.
4. Every row carries an agent tier from the known `tl-*` set; no blanks.
5. Every `D*` defined in Decisions appears in at least one `Task`.
6. No `> me:` line under an **unstruck** question — an inline user answer never promoted to a
   Decision.
7. No `TBD` anywhere while the header says Stage 4.
8. **Staleness** — below.

**Check 8, the staleness stamp.** The implementation plan records the decisions it was built
from:

```markdown
## Implementation plan
*Built from D1–D5 · decisions:a3f9*
```

`a3f9` hashes the Decisions section. The linter recomputes it. Planning is not linear — the
user *will* return to stage 3 and settle something new — and when they do the hash stops
matching and the file says so: *"the implementation plan predates D6; revise or re-stamp."*
Without it, a stage-4 plan keeps looking authoritative while the ground under it has moved.

**Three trigger points, one script:**

| When | How | Effect |
|---|---|---|
| Lead writes the plan | `PostToolUse` on the plan dir | Failures injected as context; lead fixes next turn |
| **User** saves in their editor | Watcher emits lint output beside the diff | Catches hand-edits too |
| Lead writes `board.md` | `PreToolUse` **deny** | Execution cannot start from an inconsistent plan |

Only the last blocks. Mid-edit inconsistency is normal and should not be fought; **starting
implementation from a self-contradicting plan is the actual harm.** This also extends the
existing no-Go deny on `board.md` — two conditions on the same gate.

**Implementation plan lives in the same file, at the bottom** — one file to open, the header
says where you are, stage 4 steps can reference decisions by ID (`I2 implements D4`), and
being last means it never pushes the collaborative sections down.

**OPEN:** topic→filename slugging rules.

### Brainstorm — **DECIDED: keep v1's design, adapt to decisions already made**

v1's brainstorm is the strongest part of the old skill and its **shape does not change**.
Preserved as-is: A agents × I iterations plus one final verify round; overlapping lenses
(never silos, 2+ agents on the highest-stakes areas); the Normal / Extended / 2x mode choice
and the worker-model pick at Setup; the printed stage plan; the lead synthesising round
summaries itself; the always-on final `tl-opus-high` verify; the "gaps? resolve or proceed"
question; the superdoc-aware save at the end; and the rule that brainstorm questions reach the
user as **free text, never `AskUserQuestion`** — they are open-ended by nature.

Four adaptations, each one following from a decision made elsewhere in this document. Nothing
else moves.

**1. The file is written from round 1** *(follows from: state lives on disk, §0/§2).*

v1 holds every round in context and only *offers to save* after the verify round. A 5-agent ×
3-round brainstorm is long, compaction hits it regularly, and round 1's summary can be gone
before it is ever written down. So the run keeps a live file at
`.claude/teamlead/brainstorm/<topic-slug>.md`, and each round summary lands in it the moment
that round closes.

The **final save keeps v1's behaviour**, minus the doc-root detection (see **Superdoc**): the
target is always `superdoc/brainstorm/<topic-slug>.md`, still asking before creating the
folder. The live file is working state; the saved file is the artifact. v1's behaviour, made
compaction-proof.

**2. Questions may also be answered in the file** *(follows from: the file watch, §5).*

The chat flow is unchanged — distilled questions still go out as a plain numbered list in free
text, and free-text answers still work exactly as before. **Additionally**, because the live
file is being watched, the same `> me:` idiom works inline under each question. Twelve
questions is a wall to answer in one message; this lets the user answer three now and the rest
later. Additive, not a replacement.

**3. One gate: no summary while dispatches are outstanding** *(follows from: `events.log`, §2/§3).*

Brainstorm is the most fan-out-heavy mode and dispatch is backgrounded, so the lead is
re-invoked when the **first** agent lands. Nothing in v1 stops it distilling questions and
writing the round summary while three agents are still out — and those three are then silently
lost. This is the reported "loses returned work" failure in its most likely habitat.

Gate: **a round summary written while that round still has outstanding dispatches → block
once.** A pure count from `events.log` (N dispatches vs N returns), no judgment.

**4. "Offer to execute" now means the board** *(follows from: `board.md`, §2).*

v1 ends by offering to *"route the improvements through normal teamlead dispatch"*, which was
hand-waved. It now means what it says: the plan translates into `board.md` and runs through
the existing pipeline.

**The board is not used during the rounds.** Brainstorm's stage plan is fully determined by
(agents, iterations, mode) — a rendering of three numbers, not a plan — so it stays exactly
what it was in v1: a printed preview before the tokens are spent.

### Superdoc — **DECIDED: fixed home at `superdoc/` (repo root)**

Superdoc always lives at **`superdoc/`** in the repo root. It is the agent's second brain;
`docs/` stays entirely user-facing. **No configurable location, no `docs/` alternative, no
detection** — v1's recommended default simply stops being a question.

*(Considered and rejected: `.claude/teamlead/superdoc/`, to co-locate it with the other agent
state. Two problems killed it — see "Why not `.claude/`" below.)*

**This deletes the largest source of complexity in v1's superdoc.** v1 threads `<DOCROOT>`
through everything: a detection step, a "which folder — `superdoc/` or `docs/`?" question, the
`<!-- superdoc:start -->` marker hunt in `CLAUDE.md`, substitution in every dispatch brief, and
a 522-line playbook writing `<DOCROOT>/` throughout. All of it exists *only* because the
location was configurable. Fixing the path does not trim that machinery, it removes it.

*(Answers §8 item 1: port the playbook's substance as-is, delete the doc-root machinery. A
trim by consequence rather than a rewrite — the cheap version of that question's "trim while
porting" option.)*

Two loose ends close by consequence:

- Brainstorm's final save keeps v1's behaviour but loses the detection: the target is always
  `superdoc/brainstorm/<topic-slug>.md`.
- v1's "delete any standalone `~/.claude/skills/superdoc/`" check goes away with the plugin.

```
superdoc/
├── architecture/overview.md
├── features/*.md
├── meta/TERMINOLOGY.md
├── ui/STYLING-GUIDE.md
└── claude-instructions/
```

**Why not `.claude/`:**

1. **`.claude/` is gitignored in many repos.** Superdoc landing there would be ignored, and
   the agent's accumulated knowledge would die at the next clone — *silently*, since
   everything keeps working locally. Fatal to the point of the feature, and the failure mode
   is invisible until someone else clones.
2. **Humans would lose the "why".** v1's feature pages carry inline `Why:` notes and the
   architecture overview is genuinely readable by a person. Buried under `.claude/`, nobody
   browsing the repo finds them.

At the root, superdoc is committed by default and stays discoverable. The `docs/` vs
`superdoc/` split still does the intended work: `docs/` is what users read, `superdoc/` is what
agents read — and a human can drop into it when they want the rationale.

**Implication — the natural Phase 8.** "Second brain" is a larger idea than v1 implements: v1
generates docs at setup and audits on request, and "self-maintaining" is really just an
instruction in `CLAUDE.md` asking future agents to be tidy. With the ledger in place the two
are one system at different timescales — `events.log` and `board.md` are **episodic** memory,
superdoc is **semantic** memory. That makes a real gate possible: *a task merged, it touched a
documented capability, and no superdoc page changed → block once.* That is what would make
"self-maintaining" mechanical rather than aspirational. Not scheduled; noted as the reason
this move is more than filing.

## 6. Layout

```
claude-teamlead-v2/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json          # installs straight from this repo
├── skills/
│   ├── teamlead/SKILL.md         # mode, ledger, sizing, routing  (~120 lines)
│   ├── teamlead-plan/SKILL.md
│   ├── teamlead-brainstorm/SKILL.md
│   └── teamlead-superdoc/        # SKILL.md + playbook + assets
├── agents/tl-{sonnet,opus}-{low,medium,high}.md
├── hooks/
│   ├── hooks.json
│   ├── state.sh                  # flag file — single source of truth
│   ├── resolve.sh                # settings → resolved worker names
│   ├── record.sh                 # SubagentStart/Stop → events.log
│   ├── gate.sh                   # Stop: decompose + reconcile + worktrees
│   ├── restore.sh                # SessionStart: re-inject open board
│   ├── plan-lint.sh              # plan file consistency — 8 checks
│   └── mode.sh                   # UserPromptSubmit: flag, stop-word, re-assert
└── docs/{enforcement.md, plan.md}
```

### Per-project state — `.claude/teamlead/`

Organizing principle: **everything the user would open sits at the top level; everything only
hooks touch lives in `.state/`.** This folder gets browsed in an editor, so machine state
should be out of the way.

```
.claude/teamlead/
├── settings.md                 # effort / opus / prompting  (migrated from .claude/teamlead.md)
├── board.md                    # live working set
├── plan/
│   └── <topic-slug>.md         # user opens these
├── brainstorm/
│   └── <topic-slug>.md         # live during a run; final copy → superdoc/brainstorm/
└── .state/                     # hook-owned, never hand-edited
    ├── events.log
    ├── active                  # mode flag — presence = teamlead on for this project
    ├── active-plan             # path of the plan currently watched
    ├── go                      # recorded Go tokens (gates board.md writes)
    └── snap/<topic-slug>.md    # watcher snapshots
```

**`events.log` sits in `.state/`.** Its whole value is being the one record the model cannot
touch (§2). Placing it beside `board.md` invites hand-editing; grouping it with machine state
makes that visually obvious.

**Nothing lives in the home folder. Ever.** This corrects `enforcement.md` §5c, which put the
mode flag at a global `~/.claude/.teamlead-active`. Every piece of teamlead state — settings,
mode flag, board, plans, events — is **project-scoped**, under `${CLAUDE_PROJECT_DIR}/.claude/
teamlead/`. A global flag would activate teamlead in an unrelated project the moment a second
session opened, and there is no teamlead state that is genuinely user-global.

**The mode flag is per-project, and it persists across sessions.** `.state/active` exists →
teamlead is on for this project, today and next week. This is not merely correct scoping, it
is the better behaviour: a per-session flag would mean re-running `/teamlead` at the start of
every session, where a per-project flag means the project *remembers* it is a teamlead project
and is activated once, ever. `stop teamlead` removes the file, symmetrically, and it stays off
until re-activated.

It also gives `restore.sh` real work: open the project, teamlead is already active and the
open board is already re-injected — no activation step at all.

Hooks read `${CLAUDE_PROJECT_DIR}/.claude/teamlead/.state/active`; absent → `exit 0`, which is
the same zero-cost no-op as before.

**Snapshots are per-file.** A single shared `.snapshot` collides as soon as a second plan
exists, and it fails *silently* — the watcher diffs against the wrong file and emits garbage.

**Git.** Commit `settings.md`, `plan/`, `brainstorm/` — durable project knowledge. Ignore
`.state/` and `board.md`: both churn every turn and produce noisy diffs for no benefit.
*(Answers §8 item 2.)*

**Migration.** If `.claude/teamlead.md` exists and `.claude/teamlead/settings.md` does not,
move it. One line, runs once.

**Consequence, intended:** two sessions in the same project share one mode flag and one
`board.md`. That follows from project-scoping and is wanted — the board's whole purpose is to
survive `/clear`, compaction, and session restarts, which per-session state cannot do.

`install.sh` / `install.ps1` are deleted — `claude plugin marketplace add` replaces both.
Known cost: skills namespace, so it's `/teamlead:teamlead`.

---

## 6.5 Phase 0 results — verified on this machine, 2026-08-31

Run against Claude Code 2.1.251 with a logging hook on every event plus a real
subagent dispatch. **Five findings changed the design.**

| # | Question | Answer |
|---|---|---|
| 1 | Does `PreToolUse` carry `agent_id` for subagent tool calls? | **Yes** — `agent_id` *and* `agent_type` (e.g. `tl-sonnet-low`). Lead/worker discrimination works. |
| 2 | What does `SubagentStop` carry? | `agent_id`, `agent_type`, `stop_hook_active`, and **`last_assistant_message`** — the worker's own summary. Better than assumed: the ledger can record *what came back*, not just that something did. |
| 3 | Can `SubagentStart` identify the task? | **No.** It has `agent_id`/`agent_type` but no prompt or description. |
| 4 | Do harness-internal agents fire `SubagentStop`? | **Yes**, with an **empty `agent_type`**. |
| 5 | Does skill-body `` !`…` `` shell always run? | **No** — see below. |

**Finding 3 → dispatches are recorded at `PreToolUse(Agent)`, not `SubagentStart`.**
That event carries `tool_input.subagent_type`, `.description` and `.prompt`, so it is
the only place the task is knowable.

**Finding 4 → every ledger write filters on `agent_type` matching `^tl-`.** Without
it, internal agents post phantom `return` lines, dispatch/return counts drift, and
every reconcile check misfires. This would have looked like a mysterious model
failure rather than a hook bug.

**Finding 5 is the big one.** Skill-body shell substitution runs **only when the
skill is invoked as an explicit namespaced slash command** (`/teamlead:teamlead`).
When the model auto-loads the skill by description match — the normal path — the
body is injected verbatim with no shell execution. Verified both ways in a fresh
project: slash invocation created the flag file, description match did not.

Also: **`CLAUDE_PLUGIN_ROOT`, `CLAUDE_SKILL_DIR` and `CLAUDE_PROJECT_DIR` are all
unset inside skill-body shell**; only `$PWD` is set, correctly, to the session cwd.
So a skill body cannot even locate its own plugin's scripts.

Together these retire §4's "activation state → injected, not procedured" as
originally written. Depending on `!` for an invariant is v1's mistake in new
clothing — an invariant that holds only when the model takes one particular path.

**So activation, state injection and routing resolution all moved into hooks**
(`mode.sh` on `UserPromptSubmit`, `restore.sh` on `SessionStart`, both calling
`state.sh` → `resolve.sh`). Hooks always run, always have `CLAUDE_PLUGIN_ROOT`, and
work identically for slash and description-matched invocation. The skill body now
*describes* the state it was handed rather than fetching it.

### Worker fence — added 2026-09-16

**Default: a worker writes only inside its own worktree.** Two layers:

1. Every `tl-*` brief now opens its Boundaries with it, explicitly covering shell and scripts,
   not just file tools.
2. `hooks/worktree-fence.sh` — `PreToolUse` on `Edit|Write|MultiEdit|NotebookEdit`, denies
   any path not under the worker's `cwd`. Identity by `agent_id` + `agent_type ^tl-`, so the
   lead is never fenced and keeps writing plan files and the board.

Three things learned building it:

- **Claude Code's `isolation: worktree` already fences the shared checkout natively** — a
  worker writing to the main repo path gets *"This agent is isolated in the worktree …"*.
  That is rung 3 of the ladder and should have been probed first. But it covers **only**
  paths mapping into the repo; a write to any unrelated absolute path goes straight through.
  Verified: the worker created `/tmp/…escape.txt` untouched. The hook closes that.
- **Agent-frontmatter `hooks:` do not fire for plugin workers on this path.** Tested with
  `${CLAUDE_PLUGIN_ROOT}` *and* with an absolute path; neither ran. Falsifies
  `enforcement.md` §1 row 5 as a usable mechanism here (it hedged about a workspace-trust
  dependency; whatever the cause, a fence that silently depends on it is no fence). Moved to
  `hooks.json`, which is proven to fire, gated on the identity fields Phase 0 confirmed.
- **Prose is a coin flip.** Asked to write outside, the worker complied in one run and
  declined in the next, with identical briefs. Ordered to attempt the call anyway, it was
  refused by the hook with the fence's own message. That's the whole thesis in one test.

`cwd` in the worker's hook input **is** the worktree path when dispatched with
`isolation: worktree` — confirmed, which the fence depends on.

### Bugs found by testing, not by reading

- **`grep -c … || echo 0` yields `"0\n0"`.** `grep -c` prints `0` *and* exits 1, so
  the fallback fires on top of real output. Every count comparison then died with
  "integer expected" — and because the gate swallowed it, the gate silently passed
  on any project whose ledger was empty. The whole gate was a no-op until this was
  found.
- **An early `[ -f "$TL_EVENTS" ] || exit 0`** in the Stop gate skipped the
  decompose and worktree checks on any project that had not dispatched yet — i.e.
  exactly the project that most needs the decompose check.
- **The watcher needs a settle delay.** The lead writes the plan, *then* refreshes
  the snapshot; inotify fires in the gap and reports the lead's own edit as a user
  edit on every write. A 2s pause closes it and collapses autosave bursts too.
- **The model invents its own board format** if handed an empty file. Observed
  directly: it wrote prose headings instead of the table, which silently breaks
  every row check. Fixed by *seeding* `board.md` with the table header at
  activation, plus a format check in the gate. Seeding is the cheap half — given a
  table, the model fills rows.
- **The lead skips the board entirely on "small" tasks**, doing the work itself and
  justifying it. Reproduced on a 4-file task. This is the reported "ignores its own
  task list" failure, one step earlier: no list was ever made. Hence the
  **Decompose gate** — 2+ changed files with an untouched board blocks once. The
  2-file threshold keeps one-line fixes from being nagged.

## 7. Build order — status

| Phase | What | Status |
|---|---|---|
| 0 | Verify hook payloads before designing around them | ✅ done — §6.5 |
| 1 | Plugin skeleton, `plugin.json` + `marketplace.json`, installers deleted | ✅ done |
| 2 | Split the monolith into four skills | ✅ done — 487 → 143 lines core |
| 3 | The ledger: `board.md`, `events.log`, `record.sh`, `restore.sh` | ✅ done |
| 4 | The gates: outstanding, reconcile, board format, decompose, worktrees, **worker fence** | ✅ done |
| 5 | Context offloading: state injection + `resolve.sh` | ✅ done (via hooks, not `!` — §6.5) |
| 6 | Planning mode: skill, `plan-lint.sh`, `watch-plan.sh` | ✅ built, lint + watcher tested; full stage flow untested end-to-end |
| 7 | Brainstorm + superdoc skills | ✅ ported; not exercised end-to-end |
| 8 | Superdoc as semantic memory, with a doc-staleness gate | not started, by choice |

**Verified working end-to-end** in a real session (`--plugin-dir`, print mode, fresh
git project):

- activation by description match *and* by slash command, flag persisting across sessions
- `SessionStart` restore — a brand-new session knew the mode was on, named the correct
  resolved workhorse for `effort: low`, knew Opus was banned, and knew to use worktrees,
  with no invocation at all
- dispatch and return both recorded, with the worker's own summary
- Stop gate blocking a live session on an unmerged worktree — the model investigated and
  surfaced it instead of ending silently, and refused to discard work that was not its own
- decompose gate forcing a board on a 4-file task after it had skipped one
- board format check catching an invented format

**Not yet exercised:** the plan-mode stage flow with a real user in the loop, a full
brainstorm run, and any superdoc run.

## 8. Open questions — running list

*(None currently block a phase — Phases 0–7 are all specified.)*

1. Topic→filename slugging rules for plan files. (§5)
2. Does the effort dial need all 6 levels, or is `xmedium` vs `xlow` ceremony? (§4)

**Answered**

- ~~Lead edit ban~~ — **dropped (§3).** Not a reported pain, and it breaks planning mode.
- ~~Planning mode shape~~ — **decided (§5).**
- ~~Watcher portability~~ — **moot (§0.1).** Linux only; no fallback.
- ~~Board lifetime~~ — **decided (§2).** Live working set; done capped; open items only are
  re-injected.
- ~~Impl plan file location~~ — **decided (§5).** Same file, last section.
- ~~Plan file structure~~ — **decided (§5).** Fixed template, six sections.
- ~~`.claude/teamlead/` in git?~~ — **decided (§6).** Commit `settings.md`/`plan/`/
  `brainstorm/`; ignore `.state/` and `board.md`.
- ~~Superdoc: port as-is or trim?~~ — **decided (§5).** Fixed home at `superdoc/` (repo root);
  the doc-root machinery is deleted rather than trimmed.
- ~~Brainstorm: ledger vs stage plan~~ — **decided (§5).** Neither. v1's design is kept
  wholesale; stage plan stays a cost preview, board unused during rounds, `events.log` gates
  outstanding dispatches.

---

## 9. Real-install findings — 2026-09-16

Everything before this was tested with `--plugin-dir`. Installing the plugin properly
(`claude plugin marketplace add ./` + `install`) surfaced three failures that path cannot show.

**1. `plugin.json` must not declare `hooks`.** `hooks/hooks.json` is loaded automatically;
declaring it as well is a duplicate and the plugin **fails to load entirely**
(`Duplicate hooks file detected`). `--plugin-dir` tolerates it.

**2. Plugin agents are namespaced.** `subagent_type` and `agent_type` arrive as
`teamlead:tl-sonnet-low`, not `tl-sonnet-low`. Every filter tested bare `tl-*`, so on a real
install **the ledger recorded nothing and the worker fence never fired at all** — both
silently dead, no error anywhere. Earlier testing hid this because the `tl-*` agents were
still installed user-level from v1, where they are unnamespaced. All filters now accept
`tl-*|*:tl-*`.

**3. Routing was never re-injected after first-run setup.** Settings are written *after*
activation, so the activation state block said `settings: MISSING` and the lead had no
resolved worker names for the rest of the session. Observed live: it announced
"Escalate tl-opus-low" where `medium` resolves to `tl-opus-medium`. `mode.sh` now re-emits
the resolved routing whenever `settings.md` is newer than `.state/routing-shown` — once per
change, not per turn.

### Also fixed in this pass

- `${CLAUDE_PLUGIN_ROOT}` is **unset in the lead's Bash tool** (it is set in hooks). The plan
  and superdoc skills invoked `plan-lint.sh`, `watch-plan.sh` and the superdoc playbook
  through it, so all three were unreachable — plan mode could not have worked. Hooks now pin
  the path to `.state/plugin-root`, and the skills read it from there.
- Reconcile matched `| running` anywhere on a row, so a task whose text began with "running"
  tripped the gate on a merged row. It now reads the State column by field position.
- Superdoc's gitignore check lived in a `` ```! `` block, which only runs on an explicit
  namespaced slash invocation — the check the skill itself calls "silent and fatal" was
  itself silently skipped. Now an ordinary Bash step.
- `.state/active-plan` was read by `state.sh` but never written by anything; plan mode writes
  it at stage 2.
- `state.sh` labelled every worktree "leftover", including ones with live workers.
- `plan-lint` check 5 required each decision individually bolded, so `**D1 D2 D3**` failed;
  and the row regex `I[0-9]+` made a suffixed ID like `I4b` invisible to every check. The
  shipped example plan failed its own linter — it now passes.
- Worker fence carves out the session scratchpad (`/tmp/claude-*/`), nothing else.
- Concise output style: six rules in the core skill plus a per-turn reminder from `mode.sh`.
- Vision: all image work routes to `tl-opus-medium` automatically, exempt from the Opus
  policy and the effort dial, capped below high effort.

### Environment note

`@playwright/mcp` defaults to a **headed** browser; there was no "show the window" config to
remove. `--headless` is now explicit in `~/.config/mcp/mcp.json` and in every cached
`claude-plugins-official/playwright/*/.mcp.json`. The plugin-cache copies are overwritten on
plugin update, so that part needs redoing if playwright updates.


## 10. Board integrity — 2026-09-16

The ledger's split (§2) said `board.md` is model-owned and `events.log` is hook-owned, and
that the gap between them catches lost work. What went unnoticed is that **only the
hook-owned half was ever validated**. Plan files got `plan-lint.sh` with eight checks; the
board — the artefact the model actually writes, and therefore the only one that can be
wrong — got a single grep for its header.

Demonstrated: a board with a duplicate id, two in-flight rows owning the same path, a ticked
row still marked `running`, and a row with no agent passed the gate cleanly.

`hooks/board-lint.sh` now runs on every Stop:

1. Table format (moved out of `gate.sh`).
2. Duplicate task ids.
3. Unknown or missing State.
4. `✓` and State must agree — a ticked row claiming `running`, or a `merged` row left
   unticked, means the board is lying about what is finished.
5. An unfinished row with no agent assigned.
6. **No two unfinished rows may own overlapping paths**, parent/child included — `src/`
   overlaps `src/router/`. Finished rows may share freely; read-only rows never collide.

Check 6 is the point. "Two rows in flight must never share an `Owns` path" was enforced for
*plans* and not for *execution*, which is backwards — planning is where the rule is stated,
execution is where the collision happens.

## 11. Storage — **DECIDED: per-project JSON, revisit later**

A central SQLite in a shared directory (projects table, issues, a cross-project HTML
dashboard) was considered and **deferred**. `.state/board.json` stays the truth.

Why not now:

- It reverses §6's invariant (*nothing in the home folder*), which exists for a good reason
  and should only be undone deliberately.
- Per-project JSON travels with the repo. A central store would mean a fresh clone has no
  board — weak for a tool whose thesis is that state survives.
- **Project identity is the hard part**, not the schema. Path-based keys break on rename or
  move, and break *immediately* on our own worker worktrees, since `.claude/worktrees/agent-x`
  reads as a different project. Any future version needs a UUID at
  `.state/project-id`, with worktrees resolved back to the main checkout first, and path
  stored only as a display hint.

Why it stays viable:

- **The MCP boundary makes storage a swap.** The agent calls `board_add`; where that lands is
  invisible to it. Changing stores touches `scripts/board.py` and nothing else — no skill
  edits, no agent changes.
- If it happens, split by **lifetime**, not location: long-lived user-managed *issues* in a
  central DB (the GitHub-issues layer, writable from a dashboard), in-flight *tasks* in
  per-project JSON (the sprint board, already capped and deferring history to `events.log`).
  Pulling an issue into a session copies it onto the local board and writes the outcome back.
- A cheaper intermediate step: keep JSON authoritative and write-through to a central SQLite
  purely as a **derived index** for cross-project queries, rebuildable by scanning project
  dirs. No data loss if it is lost, and no sync bug that matters.


## 12. Plan mode — first real run, 2026-09-16

Exercised stages 1–3 against the produce-site test project. The mechanism works: the file was
created at `.claude/teamlead/plan/<slug>.md`, its absolute path printed, and
`.state/active-plan` written (both of the §6.5 fixes confirmed live).

The scout wave earned its place. It found that the nav is duplicated byte-for-byte across all
5 pages, that links are root-absolute, that the working tree has uncommitted edits the plan
must build on rather than the last commit — and, unprompted, **that open board task #1 already
owns those same 5 files**, so it sequenced the nav change to run after that task merges.
Cross-subsystem reasoning about the `Owns` rule was not something the skill asked for.

**Two linter false positives, both of which fired on every stage-3 plan:**

1. **Check 5 ran with no implementation plan.** Before stage 4 the table is legitimately empty,
   so every decision was reported as "decided but no implementation step references it". A
   plan was therefore failing lint from the moment it was created. Now gated on the table
   existing.
2. **An empty `> me:` placeholder counted as an un-promoted answer.** The lead writes those as
   an invitation for the user to type into — good UX it invented on its own — and lint read
   each one as an unanswered promotion. Only a `> me:` with actual text after it is flagged
   now.

Both are the cry-wolf failure again, and the third instance of it in this project: a check
that fires when nothing is wrong trains the model to ignore it. Worth treating as a standing
review question for any new check — *when does this fire on a correct state?*


## 13. Interactive editor mode — verified live, 2026-09-16

The last unverified path. Earlier runs were `claude -p`, where the watcher process existed
but its Monitor died with the one-shot session, so the *notification* half was never
exercised.

Run in an interactive session: the lead armed the watcher itself (`ToolSearch("select:Monitor")`
→ `Monitor(watch-plan.sh …, timeout_ms: 1800000)`), and an atomic `mv`-style save — what vim
and VS Code actually do — woke it mid-conversation. It then **promoted the note into two new
decisions (D3, D4), struck the question that note answered, and revised its own recommendation
in light of D4**. The whole second-input-channel loop, end to end.

Two corrections it surfaced:

- **`persistent: true` does not exist** on this Monitor. The plan skill said to pass it; the
  lead correctly used `timeout_ms` instead. Skill now says to use the maximum timeout and
  re-arm, and warns that Monitor is a deferred tool needing `ToolSearch` first — which the
  lead figured out on its own but should not have to.
- **The MCP server is long-lived and holds the code it started with.** Editing
  `scripts/board.py` mid-session leaves the server rendering with the old function while the
  CLI `check` uses the new one, which surfaces as a spurious `board.md has drifted` from the
  Stop gate. A dev-loop artifact, not a product bug — but restart the session after editing
  `board.py`, or expect one confusing drift report.


## 14. Brainstorm — first real run, 2026-09-16

3 agents × 1 round + Opus verify, on the produce-site project. Everything v1 specified held:
the Setup picker offered all three modes with correct agent counts (2x correctly reported 6
agents for 3 lenses), the stage plan printed as a cost preview before any spend, lenses were
assigned across Design/UX · Performance/Reliability · Cost/Simplicity, and the heads-up line
matched the documented format exactly.

**The one adaptation added for brainstorm (§5, "no summary while dispatches are outstanding")
fired on its first real opportunity.** The lead reached the end of its turn with all three
thinkers still out, and the Stop gate blocked:

    - 3 dispatched worker(s) have not returned yet. Wait for them, or say why you are
      proceeding without them.

The lead then said plainly: *"the round summary won't be written until every one has
returned."* It fired **three times** across the round — at 3, 2 and 1 outstanding, once per
turn as each thinker landed — and the lead held every time, naming which lens it was still
waiting on. The loop guard meant it never stuck; each block cost one forced second look. That is the reported "loses returned work" failure being prevented in the exact
habitat predicted for it — the most fan-out-heavy mode, where the lead is re-invoked by the
*first* agent to land and nothing else would have stopped it summarising three-thirds of the
way short.

Also confirmed live: the file is written from round 1 (header metadata, shared context block,
`## Round 1 _(pending — agents out)_`), and the lead offered inline `> me:` answering in the
brainstorm file alongside the chat list.

## 15. Extended test scenarios — 2026-09-16

Three projects run concurrently, chosen for what they might break rather than what they would
confirm.

### Superdoc (produce-site, 5-page site with real capabilities)

- **Step 1 detection ran as a real Bash step** — the §6.5 fix. As a `` ```! `` block it would
  never have executed on a description-matched load, which is how superdoc is normally
  reached, and the gitignore check it contains is the one the skill itself calls silent and
  fatal.
- Offered both FRESH tiers with correct descriptions and defaulted to full FRESH for a repo
  that has real capabilities.
- Put its own scout on the board rather than working off-book.
- The Stop gate fired, and the lead used the **documented escape**: *"Deliberately ending the
  turn with the scout still running: it's dispatched in the background per the stay-unblocked
  rule."* Confirms the gate is a forced second look, not a wall — blocks once, accepts a
  stated reason, proceeds.

### Scenario A — greenfield (`/tmp/greenfield`, empty repo)

Nothing before this started from zero; produce-site already had five pages. Exercises
superdoc GROUND-SETUP, decomposition with no code to reason from, and the decompose gate on
files that are all `??` rather than `M`.

Early result worth keeping: the plan-mode scout, finding an empty repo, did not stall. It
recorded *"Repo is empty … Nothing to scout in-repo"* and then scouted the **machine**
instead — Python 3.14.7, Rust 1.90, Node 24.21, Go — turning "no context" into the context
that actually mattered for a greenfield choice.

### Scenario B — adversarial (`/tmp/adversarial`)

A pricing module with two tests that contradict each other: `apply_discount(100, 10)` is
asserted to equal both 90 and 85. The task says make them pass without editing the tests,
which is impossible. A second task deliberately wants the same file.

Targets the paths every successful run has skipped: the retry ladder, what a worker does when
its task cannot be done, whether the lead notices rather than accepting a false success, and
the `owns` collision refusal under real pressure instead of a synthetic one.

### Scenario B result — the lead refused an impossible task rather than faking it

The strongest result of the three, and not the one the scenario was designed to produce.

Given "make the tests pass without editing them" against a suite asserting
`apply_discount(100,10)` equals both 90 and 85, the lead **read the tests before dispatching
anything** and wrote the contradiction onto the board as the task title itself:

    #1 blocked  Make tests/test_pricing.py pass by editing src/ only — BLOCKED: tests assert
                apply_discount(100,10)==90 AND ==85; contradictory by design, no honest
                implementation satisfies both        agent: lead   owns: []

Then it partitioned: the second, genuinely doable task (`round_currency`) was dispatched,
completed and merged, while the impossible one stayed `blocked` with the lead. No worker was
sent on an errand it could not complete, and nothing was reported as done that was not.

**What this leaves untested:** the retry ladder (worker fails → one correction → escalate).
The lead never let a worker fail, so the ladder has still never fired. Triggering it would
need a task that *looks* achievable and only fails on execution — a harder fixture to build,
since the lead now demonstrably reads before it dispatches.


### Superdoc result — complete and correct

Full FRESH scout-then-fan on the 5-page produce site produced 8 files:

    superdoc/architecture/overview.md
    superdoc/claude-instructions/{documentation,documentation-version-policy}.md
    superdoc/features/{produce-catalog,seasonal-guide,recipes}.md
    superdoc/meta/TERMINOLOGY.md
    superdoc/ui/STYLING-GUIDE.md

Four workers wrote them in parallel with **non-overlapping `owns`** (one folder each, plus
`CLAUDE.md` for the wiring worker), and QC was queued `blocked-by 6,7,8,9`. Each branch
fast-forwarded into master separately.

`CLAUDE.md` is wired exactly as the playbook specifies: guarded `superdoc:start`/`superdoc:end`
markers, `@`-force-loading **only** TERMINOLOGY and `claude-instructions/*`, with everything
else a plain on-demand link and the `@`-budget rule stated inline ("force-load a file only if
its absence would let the agent do the wrong thing on *any* task").

The docs themselves are usable rather than ceremonial — the overview is dated per the version
policy, links to siblings instead of duplicating them, and is honest about the shape of what
it documents ("no single entry point the way a coded app has one").

One false alarm worth recording: an intermediate `find` showed `features/` missing while the
board already said W3 merged, which looked like a task closed without its output. It was a
mid-merge read — all 8 files were in `HEAD`. The board was right. Worth remembering that
checking the working tree during a fast-forward can manufacture a phantom discrepancy.


### Scenario A result — the retry ladder fired, and exposed a ledger hole

Declared untested one message earlier, then fired on its own. QC on `unitconv.py` found a
genuine edge case — `-0.00001 mm km` printing `-0 km` — and the lead sent **one correction to
the same worker**, which is the ladder's first rung exactly as written.

It did that by **resuming** the worker (`SendMessage to: a20af64…`), and that exposed a real
bug in the ledger: `record.sh` only recorded `PreToolUse(Agent)`, so a resumed worker fired
nothing. `outstanding` read 0 while a worker was genuinely running — and since resumption is
*how the retry ladder works*, the ledger under-counted precisely when tracking matters most.

The lead diagnosed it itself, in its own words: *"the gate's worker count doesn't track
resumed agents."*

Fixed: `record.sh` records a `resume` line on `SendMessage` to an agent id already in our own
ledger (ignoring messages to anything else), and `gate.sh` counts a resume as outstanding
again until that worker's `SubagentStop`.

**How this surfaced is the point.** No test caught it. The gate reported a discrepancy it
could not explain, the lead reasoned about *why* the gate was wrong, and said so plainly
instead of dismissing it. A gate that is honest about its own state made its own blind spot
findable.

Also confirmed in the same run: the reconcile and worktree checks fired together on a real,
unconstructed discrepancy — ledger `outstanding: 0`, board still `running`, worker branch
holding an unmerged commit. Those are the two originally reported failures ("worker returns,
result evaporates" and "work never merged back") occurring at once, and both were caught.


## 16. Hardening pass — 2026-09-16

Six improvements, driven by what the live runs actually showed rather than by a checklist.

**1. Gate fatigue (the important one).** Across the produce-site session the lead answered
block after block with "deliberately proceeding" / "deliberately skipping" — every instance
correctly reasoned, which is exactly the problem. The gate was firing on states that are
normal mid-flight: a background worker still running, a worktree holding work QC had not
verified yet.

Fixed by making the worktree check **liveness-aware**: a worktree is only flagged once its
worker has actually finished. `.claude/worktrees/agent-<id>` maps to a ledger id, so "is this
worker still out?" is answerable exactly.

This was the fourth cry-wolf bug in the project (phantom outstanding worker, stale board
counter, two plan-lint false positives). The rule is now written at the top of `gate.sh`:
**a check that fires on a correct state is worse than no check** — every condition must be
false during normal work.

**2. `merged` is verified against git.** The board validated itself but never asked git
anything, so a task marked merged whose branch still had unmerged commits — the reported
"work never merged back" — was undetectable. `check_git` now runs `rev-list --count HEAD..<branch>`
for every merged task carrying a branch.

**3. Liveness replaces the clock.** Outstanding workers are paired by agent id
(`SubagentStart`/`resume` against `SubagentStop`) instead of counting dispatches against
returns, which drifted in both directions. A worker is tracked however long it runs — the
user reports real runs reaching ~1.5h, so the abandoned-worker age-out sits at 4h and only
catches ids that never stopped at all. A short pending window covers the gap between dispatch
and `SubagentStart`, since a dispatch carries no id.

**4. `board.py status`** — open tasks, workers out, and any check failures in one command.

**5. `events.log` rotation** — the gate reads it every Stop and it only ever grew. Tail stays
live at 2000 lines, the rest rolls into `events.archive.log`.

**6. Malformed ledger lines are ignored** — a corrupt timestamp sorts unpredictably against a
real one and skewed every recency comparison.

### Found while testing the above

**Runtime state must be gitignored, and teamlead now guarantees it.** A worker running
`git add -A` captured `board.json` onto its branch; checking back to main then deleted it and
the board silently vanished. Activation now appends `.claude/teamlead/.state/` and
`.claude/teamlead/board.md` to the project `.gitignore` (idempotently). This was not
hypothetical — it happened during this pass, to me, and looked exactly like data loss.
