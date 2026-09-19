---
name: teamlead-brainstorm
description: Use for /teamlead brainstorm <agents> <iterations> <topic>. Runs a real multi-agent brainstorm — N independent thinkers over M rounds with overlapping lenses, questions asked back to the user between rounds, and a final Opus verify.
---

# Brainstorm mode

`A` = agents, `I` = iterations. **First number is agents, second is iterations**,
always that order. Free text is fine ("brainstorm with 5 people over 2 rounds
about X") — pull the two numbers in that order, the rest is the topic. Missing a
number → default **5 agents, 2 iterations**, and say so.

There is **always one extra final verify round** on top of `I`.

**Your role shifts:** you still don't ideate, but you DO synthesize. Distilling
the questions and writing each round's summary is *your* job. Agents think and
ask; you consolidate.

## The live file

The run writes to `<project>/.claude/teamlead/brainstorm/<topic-slug>.md` **from
round 1**, not at the end. A long brainstorm outlives its context — compaction
will hit it, and a summary that only exists in conversation is a summary you will
lose.

Each round's summary lands the moment that round closes.

## Setup (once, before round 1)

1. **Topic + context.** If the topic names a directory, every agent reads it. If
   context is unclear, ask in free text.
2. **Lenses — overlapping, never silos.** Give each agent a **primary lens** as a
   *starting angle* — Security, Performance, Extensibility, Reliability, Design/UX,
   Maintainability, Testing, Cost/Simplicity — but tell **every** agent to range
   across the whole topic and weigh in on anything, including other agents'
   concerns. Overlap is the point: several independent opinions on the same
   questions, not one owner per area. **No single agent's take may close off a
   decision.** Put 2+ agents on the highest-stakes areas deliberately.
3. **Ask mode + model in one `AskUserQuestion` call:**
   - **Normal** (recommended) — one lens per agent, ranging across the topic.
   - **Extended** — two distinct lenses per agent, paired round-robin, told to
     reconcile between them. Breadth over depth.
   - **2x** — one lens per agent but **two independently dispatched agents per
     lens** (so `2×A` this round), identical briefs, zero shared context. Depth
     *plus* a second opinion to diff against. Doubles the cost.
   - **Model:** `tl-sonnet-high` (recommended), `tl-opus-high` (max depth),
     `tl-sonnet-medium` (cheapest). The final verify stays `tl-opus-high`
     regardless.
4. **Print the stage plan** — one stage per round listing its `Model@Effort: lens`
   bullets, plus a last stage for the verify. This is a **cost preview**: it is
   fully determined by (A, I, mode), so print it once and do not put it on the
   board.

## Each round i = 1..I

1. Heads-up: `🧠 Round i/I — <N> [model] agents thinking (mode: <mode>, lenses: …).`
2. **Dispatch in parallel, background.** Each brief: *"You are one independent
   person in a brainstorm about `<topic>`, thinking through the **`<lens>`**
   lens(es). [Read `<dir>`.] [Previous summary + answers: …]. Return (a) your
   ideas/critique, (b) **0–5 questions** you'd want answered — only real ones, or
   none."* Concise, no raw logs.
3. **Wait for every agent.** You are re-invoked when the *first* one lands —
   that is not the round finishing. Writing the summary while agents are still out
   silently discards their thinking, and the Stop gate will block you for it.
4. **Distil the questions.** Drop only exact or near-duplicates; keep the rest.
   **Err toward asking too many, never too few.**
5. **Ask as a plain numbered list in free text — NEVER `AskUserQuestion`.** These
   are open-ended. The user may answer in chat, or inline in the file under each
   question with a `> me: ` line (one trailing space, left empty for them to type
into); both work, and partial answers are fine.
6. **Write the round summary** into the file, combining every agent's ideas with
   the answers. It feeds the next round.

## Final verify round (always, +1)

1. One **`tl-opus-high`** verifier gets the final summary plus every answered
   question from all rounds. Task: confirm the summary actually satisfies each
   answer and is internally consistent; list gaps or unaddressed answers.
2. Gaps → relay in **free text**, ask whether to resolve or proceed.
3. On the go-ahead, **save** to `superdoc/brainstorm/<topic-slug>.md` — ask before
   creating the folder. The file records topic, A/I, model, lenses, every round
   summary, all Q&A, and the final plan.
4. Then **offer to execute**: translate the plan into `.claude/teamlead/board.md`
   and run it through normal teamlead dispatch.

## Example — `/teamlead brainstorm 5 2 improve the superdoc skill`

```
Stage 1: Round 1 — thinking
  - Sonnet-5@High: Security lens
  - Sonnet-5@High: Performance lens
  - Sonnet-5@High: Extensibility lens
  - Sonnet-5@High: Design/UX lens
  - Sonnet-5@High: Maintainability lens
Stage 2: Round 2 — thinking (given Round 1 summary + answers)
  - (same five lenses)
Stage 3: Final verify
  - Opus-5@High: Check summary satisfies every answer
```

Round 1: 5 agents → 18 questions → distil to 12 → user answers → summary.
Round 2: 5 agents → 9 questions → distil to 3 → answers → summary.
Final: 1 Opus verifier → gaps in free text → save → offer to build.

Extended Mode runs the same 5 agents with 2 paired lenses each; 2x Mode dispatches
10 agents per round, doubling every round stage's bullets.
