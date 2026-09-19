# superdoc playbook — worker knowledge base

`superdoc: v2`

This file is the **only** place the superdoc contract version lives. Everything that
detects FRESH vs HEALTH-CHECK, or offers a version upgrade, compares against the `vN`
on this line — see Part 6 for exactly where that number gets stamped into the target
repo.

You are a dispatched worker building, auditing, or repairing a project's
self-maintaining docs system. Your cwd is the **target repo**, not this skill's
directory — every path below that starts with `/home/mo/.claude/skills/teamlead/` is
this skill's own file and must be referenced by that absolute path (it will not
resolve relative to your cwd). Every path that starts with `superdoc/` or `CLAUDE.md` is
relative to the target repo root, i.e. your cwd.

**`superdoc/` — the doc-root folder for this run.** The dispatching brief tells you the
value; it is **`superdoc/` by default (the recommended choice)**, or **`docs/`** if the
user picked that instead. Wherever this playbook writes `superdoc/`, substitute the
folder you were given — every path, skeleton, and `CLAUDE.md` `@`-ref. The folder name
is the *only* thing that varies; the structure inside it, the `superdoc:` marker, and
every rule below are identical for both. (The two `.../ForzaTelemetryV3/docs/...`
example paths are the reference repo's real folder — leave those as `docs/`.)

This file is doc-writing knowledge only — how to shape, write, and verify the
`superdoc/` tree. It does not restate orchestration rules; those live in the
dispatching agent's own doctrine.

## Part 0 — Do you even need `superdoc/`?

Check before building anything: if the whole project fits in one good `CLAUDE.md` —
a handful of project-overview bullets is genuinely enough for an agent to orient —
**stop here**. Write those bullets into `CLAUDE.md` and don't scaffold `superdoc/`. A thin
`superdoc/` with one paragraph per page is worse than no `superdoc/` at all — it invites trust
nobody's going to keep earning.

Re-check this on AUDIT too: if `superdoc/` turns out to be scaffolding a project that never
grew into it, say so in the report and propose collapsing it back into `CLAUDE.md`.

### Greenfield / empty project — GROUND-SETUP mode

If the dispatching brief put you in **GROUND-SETUP** (the repo is empty or near-empty — no
source, no real capabilities yet), the calculus above is **inverted**: you *do* lay the
skeleton now, precisely so the documentation discipline is force-loaded and live *before*
the first feature lands. The goal here is forward-looking — not to document code that
exists, but to make sure code written from here on gets documented as it lands.

Build **only the ground structure** — never invent capability pages for code that doesn't
exist yet:

- `superdoc/architecture/overview.md` — the hub, as a **stub**: project name + one-line
  what-it-is + a "this grows as the project does" note, plus the skeleton's section
  headings left empty for later. It's the start-here page; the module map and data flow
  fill in as real code appears.
- `superdoc/meta/TERMINOLOGY.md` — created **with the standing rule** (the
  "ask before acting on an undefined term" text) and an **empty Terms list**. This is the
  one time the file is seeded before real terms exist: it's part of the force-loaded
  `@`-set, so it must exist for its `@`-ref to resolve, and terms accrue from session one.
- `superdoc/claude-instructions/documentation.md` and `documentation-version-policy.md` —
  copied verbatim (Part 7), exactly as in any run.
- A thin `CLAUDE.md` — project-name stub, the guarded `superdoc:start`/`superdoc:end` block
  (Part 5), and the minimal `@`-set.

Do **not** create `features/`/`commands/`/`endpoints/` folders, a `ui/STYLING-GUIDE.md`, or
a `superdoc/README.md` ToC yet — there's nothing to put in them. They get created the
moment the first real capability is built, per `documentation.md`'s "update after you
change" rule. The Part 8 gate still applies in full: every `@`-ref must resolve, so the
files you reference from `CLAUDE.md` have to exist.

## Part 1 — Detect project shape

Read the manifest/entry points before writing anything: package manifest
(`Cargo.toml`, `package.json`, `pyproject.toml`, `go.mod`, …), the top-level source
layout, and whichever of `main`/`index`/`lib`/`cmd` exists. Decide two things from
this: **does it have a UI** (a rendered window, page, or TUI — decides whether
`superdoc/ui/STYLING-GUIDE.md` gets created at all), and **which shape row below** it is
(decides the capability-page noun, the data-flow spine, and the symbol convention used
throughout).

| Shape | capability-page noun | data-flow spine | symbol convention |
| --- | --- | --- | --- |
| app (has UI) | `features/` | input → parse → state → render | `file:symbol` |
| CLI | `commands/` | argv → exit code | `file:symbol` |
| library / SDK | `modules/` or `api/` (public surface) | public call → internal layers | `file:symbol` |
| web API / service | `endpoints/` | request lifecycle | `METHOD /path`, `file:symbol` |
| data science | `pipelines/` | source → transform → artifact | `nb:cell`, `file:symbol` |
| infra / IaC | `stacks/` | plan → apply → resource graph | resource address |
| monorepo | per-package overview | root overview maps packages, each package has its own spine | `packages/<name>/overview.md` |

No single entry point (library, infra, monorepo)? That's first-class, not a gap —
note it in `overview.md` and swap "data flow" for "call → internal layers" or
"plan → resource graph" per row above. Multi-entry (CLI with subcommands, monorepo)
gets one "big picture" per entry instead of a single hub paragraph.

The rest of this playbook (folder taxonomy, skeletons, the `Why:` rule, the `@`
convention) is shape-agnostic — apply it directly, don't re-derive it per shape.

## Part 2 — Folder taxonomy

Create only the folders the project actually needs (YAGNI — a folder with one thin
page is worse than no folder). This is the full taxonomy, mirrored from
ForzaTelemetryV3's `docs/`:

| Path | Required? | Holds |
| --- | --- | --- |
| `superdoc/architecture/overview.md` | Always (the floor) | The hub: big picture, module map, "where to look for X". First page anyone reads. |
| `superdoc/architecture/*.md` | Once `overview.md` would get too long for one topic | Deep dives it links out to instead of duplicating (networking, state, etc.). |
| `superdoc/meta/TERMINOLOGY.md` | Once real project vocabulary exists | Glossary + the "ask before acting on an undefined term" rule. Never created empty. |
| `superdoc/ui/STYLING-GUIDE.md` | Only if the project has a UI | Layout/control rules with runnable snippets and explicit "do NOT" bans. |
| `superdoc/<capability>/*.md` | One per **real** capability (YAGNI) | The noun from Part 1's shape row — `features/`, `commands/`, `endpoints/`, … One page per capability, not one page per file. |
| `superdoc/<capability>/<topic>-design.md` | Only for big decisions | Dated design-spec doc: goal, non-goals, rationale, `Status:` marker. |
| `superdoc/claude-instructions/documentation.md` | Always | Verbatim-installed discipline file (Part 7). |
| `superdoc/claude-instructions/documentation-version-policy.md` | Always | Verbatim-installed version-policy variant (Part 7). |
| `superdoc/README.md` | Only once `superdoc/` outgrows the overview (~5+ pages) or it's a monorepo | Table-of-contents, one section per subfolder. Below that threshold, `CLAUDE.md`'s reference list plus `overview.md`'s module map already are the index. |

A page earns its place with a non-obvious *why* or a multi-file "where do I even
look" answer; otherwise a module-map row in `overview.md` already covers it. Don't
create a capability folder for something with no real, working capability yet.

## Part 3 — Page skeletons

Reproduce these skeletons exactly (headings + what goes under each); fill with the
project's real content, don't invent sections.

### `superdoc/architecture/overview.md`

```markdown
# Architecture Overview

One-paragraph orientation to this file's role: the first doc to read, links out to
sibling docs rather than duplicating them.

## Big picture

One paragraph: what the thing is, its runtime shape, the one struct/module everything
hangs off (if there is one).

## Process model

Threading / request lifecycle / pipeline stages — only if non-obvious. Skip this
heading entirely if it's single-threaded and boring; don't pad it.

## Data flow

Real symbol names tracing the Part 1 spine for this shape. A small ASCII sketch earns
its keep here (see the worked example below). Inline `*Why:*` notes next to any
non-obvious routing decision (e.g. why a boundary crosses a channel instead of shared
state).

## Module map

Table: `path` → role, one line each. Module→role by default; reserve exact
`file:symbol` for genuinely load-bearing entry points (the hub module, the data-flow
spine) — not every row, or a rename breaks the table for no reason.

## Where to look for X

Task-oriented cheat-sheet: "touch A, register in B, wire C." One bullet per common
task, each ending at a real `file:symbol`.
```

Worked data-flow sketch, for the shape:

```
input source
      │  unit of work, cadence
      ▼
entry.rs:receive               [boundary]
      │  parse/transform
      ▼
core.rs:State::update          [owns state]
      │  fold in, fire listeners
      ▼
output.rs:render / respond
```

*Why:* lead with a human-readable paragraph before the sketch — the symbol references
are for navigation once you already know the shape of the story, not the whole story
themselves.

### `superdoc/meta/TERMINOLOGY.md`

```markdown
# Terminology

Project-specific vocabulary. When the user uses a term defined here, use the same
meaning.

**If the user uses a non-standard term that is not defined here, ask what they mean by
it before acting on it.** Once its meaning is clear, add it to this file. Keep this
file up to date automatically: whenever the user introduces or clarifies a term, add or
amend the entry here.

## Terms

- **Term** — definition. Link to the doc that shows it in use if useful.
```

Never create this file empty just to have it exist — it earns its place the first time
a real project-specific term needs defining. **The one exception is GROUND-SETUP** (Part
0's greenfield section): there you *do* create it with the standing rule above and an
empty Terms list, because it's part of the force-loaded `@`-set and its `@`-ref must
resolve from session one.

### `superdoc/ui/STYLING-GUIDE.md` (only if the project has a UI)

```markdown
# Styling Guide

What this covers and where the reusable helpers live (name the theme/style module).
State the top-level rule once (e.g. "reference colours by role token, never hard-code
a literal at the call site").

## <Layout unit, e.g. Cards / Panels / Screens>

Rule, then a runnable snippet in the project's real language:

    <code>

Explicit **do NOT** bans, stated as commands, each with the one-line reason:
"Do NOT hand-roll X — use `helper(...)` instead, so the look stays uniform across the
app."

## <Control family, e.g. Buttons / Inputs / Forms>

Same shape: rule → runnable snippet → do-NOT ban if there's a wrong way to do it that
someone will reach for.

## <Any other layout convention worth pinning>

Spacing, alignment, or sizing rules that would otherwise drift page to page.
```

Every rule should carry a runnable snippet, not just prose — the whole point of this
page is that an agent can copy-paste the correct pattern instead of reinventing it.
Every ban should be explicit and imperative ("do NOT ...") with the one-line reason,
mirroring how a hard-won inconsistency actually got fixed.

### `superdoc/<capability>/<name>.md` (one per real capability)

```markdown
# <Capability name> — <one-line tagline>

One or two sentences: what it does and why it exists (the user-facing point of it).

## How it works

Bullet list of the real mechanics, referencing real `file:symbol`. Inline `*Why:*`
notes next to any non-obvious decision, in the same sentence or bullet — don't defer
them to a separate section.

## Using it

User-facing walkthrough: where to find it, what each control does, in the order the
user encounters them.

## Options

Table, only if there are real configurable values:

| Config key | Default | Meaning |
| --- | --- | --- |
| `key_name` | default | one line |

## Related links

Bare links (or `[[wikilinks]]` if `.obsidian/` exists at the repo root) to sibling
docs this feature touches or depends on.
```

Skip `## Options` entirely if the capability has no configuration — an empty table is
worse than no heading. One page per capability, not one page per file that touches it.

### Dated design-spec doc (`superdoc/<capability>/<topic>-design.md`)

Only for decisions big enough that the *why* won't fit as an inline note — genuine
architecture trade-offs, a path not taken and why, a decision revisited later.

```markdown
# <Topic> — Design Spec

**Date:** <YYYY-MM-DD>
**Status:** <Proposed | Implemented | Superseded — if Superseded, say by what>
**Feature:** one-line summary of what this decided

---

## Goal & motivation

What problem this solves and why it's worth solving.

## Non-goals

What was deliberately left out, and why — as important as the goals.

## Key decisions & rationale

The trade-offs actually weighed, the alternative considered and rejected, and why.
This is the part a code comment can never hold.
```

The `Status:` marker is load-bearing: AUDIT checks it, and a `Superseded` doc should
say what superseded it and link there rather than being deleted — it's still the
record of why the old approach was tried.

### `superdoc/README.md` (only past the threshold in Part 2)

```markdown
# <Project> — Documentation

One line: what the project is. Point to `architecture/overview.md` as the start-here
page.

## architecture/ — how the code fits together

- [Overview](architecture/overview.md) — one-line summary. **Start here.**
- ...

## <capability>/ — what the project does

- [Name](<capability>/name.md) — one-line summary.

## claude-instructions/ — mandatory rules for agents

- [Working with the Docs](claude-instructions/documentation.md) — ...

## meta/

- [Terminology](meta/TERMINOLOGY.md) — ...
```

One bullet per page, one-line summary, grouped by the same subfolders that actually
exist. Don't build this below the ~5-page threshold — a second, easily-stale index is
worse than the module map plus `CLAUDE.md`'s reference list doing the job.

## Part 4 — The `Why:` capture rule

The most valuable, least recoverable part of a doc is the reasoning behind a design
choice — code shows *what*, rarely *why this way and not the obvious alternative*.

- **Capture it at the decision point, inline**, the moment it's made or a "why?" gets
  answered — not deferred to a doc-update pass, by which point the reasoning is gone.
  Write it as a short **`*Why:*`** note in the same sentence/bullet as the thing it
  explains (see the real usage in
  `/home/mo/Documents/Programming/ForzaTelemetryV3/docs/ui/STYLING-GUIDE.md` around
  "no trailing colons on labels" for the exact style: `*Why:* the colon was applied
  inconsistently...`).
- **Promote it to a standalone dated design-spec doc** (Part 3's skeleton) only when
  the decision is big enough that an inline note can't hold it — a real architecture
  trade-off, a path considered and rejected, something worth finding again on its own.
- If the user explains why something is done a certain way, or answers a "why?" you
  asked, write it down right then. A design choice that lives only in a chat message
  is gone the moment the context window rolls; the doc is where it survives.

## Part 5 — CLAUDE.md wiring

Wrap the merged block in guarded markers so a re-run can find and replace it instead
of duplicating it. Adapt the reference-docs list to what Part 2 actually built (real
page names, the capability folder name from Part 1); the markers and structure below
stay fixed.

```markdown
<!-- superdoc:start v2 -->
## Docs: read before you touch, update after you change

Full discipline — what to read, when to update, how to record the *why* — lives in the
always-loaded `superdoc/claude-instructions/documentation.md` below; this is a pointer, not
a restatement.

Reference docs — plain links, read the one relevant to your task on demand:

- **`superdoc/architecture/overview.md`** — codebase navigation map (module map, data flow,
  "where to look for X"). **Start here to navigate the code.**
- Per-<capability> behaviour — `superdoc/<capability>/`
- Styling rules — `superdoc/ui/STYLING-GUIDE.md` (only if this project has a UI)
- `superdoc/README.md` — the docs table of contents (only once it exists, see Part 2)

## Always in context (force-loaded, mandatory)

`@` is reserved for the must-always-know set. Everything above is a plain link: an
optional, on-demand read.

- **Terminology** — @superdoc/meta/TERMINOLOGY.md — project vocabulary; use these meanings,
  ask before acting on an undefined term, and keep it current.
- **Documentation discipline** — @superdoc/claude-instructions/documentation.md — read
  before you touch, update after you change, record design rationale (the *why*).
- **Version policy** — @superdoc/claude-instructions/documentation-version-policy.md — how
  this project bumps doc/version markers.
- One `@` line per file under `superdoc/claude-instructions/` this project has — force-load
  all of them, nothing else.

Path base: `CLAUDE.md` uses repo-root-relative paths (`@superdoc/...`, `` `superdoc/...` ``);
links *inside* docs are docs-relative. Precedence: `CLAUDE.md` is authoritative for
rules, docs are the reference — reconcile to `CLAUDE.md` on conflict. `@`-budget:
force-load a file only if its absence would let the agent do the wrong thing on *any*
task.
<!-- superdoc:end -->
```

The `@`-force-load set is **exactly** `superdoc/meta/TERMINOLOGY.md` plus every file under
`superdoc/claude-instructions/` — nothing else, ever. Every other doc (`overview.md`,
every capability page, `STYLING-GUIDE.md`, `README.md`) is a plain on-demand link.

**Why the set is this small.** `@` does not suggest a file, it *pastes* it — the whole
contents enter context on every turn of every session in this project, whether or not the
task has anything to do with it. A plain link costs nothing until an agent chooses to read
it, and an agent that needs `STYLING-GUIDE.md` will find it from the overview. So each `@`
is a permanent tax levied on every future task, paid to avoid one lookup. It is worth
paying only where *not* knowing would make an agent act wrongly on work unrelated to the
document — which is true of project vocabulary and of the documentation rules themselves,
and of essentially nothing else.

The failure this prevents is quiet: nobody notices a bloated `@`-set, they notice that
sessions fill up faster and every task costs more.
Force-loading spends context budget on every session; keep the set small on purpose.

**Merge algorithm, in order:**

1. A `<!-- superdoc:start … -->` block already exists in `CLAUDE.md` → replace
   everything between the markers.
2. Else a `## Docs` section exists (pre-superdoc or hand-written) → replace that
   section.
3. Else → append the block above to the end of `CLAUDE.md`.

Never duplicate the `@` block. Preserve existing project-overview bullets and any
`@`-refs that aren't superdoc's. **No `CLAUDE.md` at all:** create one with a short
project-overview stub — project name, one-line what-it-is, stack, key conventions, a
few bullets — plus the block above. Not a competing template; the stub is scaffolding
for the human to flesh out. Keep the whole file thin, entry-map style — detail lives in
`superdoc/`, `CLAUDE.md` just points into it (see
`/home/mo/Documents/Programming/ForzaTelemetryV3/CLAUDE.md` for the shape to match:
short project overview, a "Docs" pointer section, then the `@` block, nothing more).

## Part 6 — Pin the `superdoc:` marker

The marker lives in exactly **one** place: the opening line of the guarded block
inside the target repo's `CLAUDE.md` —

```
<!-- superdoc:start v2 -->
```

The `vN` there is the installed contract version. State detection reads it directly:
`superdoc/` folder present **and** this marker found in `CLAUDE.md` → an existing
installation (HEALTH-CHECK/AUDIT territory); no `superdoc/` and no marker → FRESH; `superdoc/`
present **without** the marker → likely hand-written docs, confirm before regenerating
(the dispatcher's Step-1 guard). Version compare
for an upgrade offer is: installed `vN` on this line vs. the `superdoc: v2` on line 3
of this playbook file — older installed version → offer the upgrade, never silently
rewrite it. Do not also stamp a marker under `superdoc/` itself; the `CLAUDE.md` line is
the single source of truth for the installed version.

## Part 7 — Verbatim-install files

Two files get **copied**, not retyped, from this skill's asset directory into the
target repo. Copying preserves exact wording the discipline depends on; retyping from
memory drifts.

```bash
cp /home/mo/.claude/skills/teamlead/superdoc-assets/documentation.md \
   superdoc/claude-instructions/documentation.md

cp /home/mo/.claude/skills/teamlead/superdoc-assets/version-policy-<variant>.md \
   superdoc/claude-instructions/documentation-version-policy.md
```

Where `<variant>` is one of `date-based`, `auto-bump`, `manual` — whichever version
policy applies to this project. **cp verbatim, do not reword.** If you don't know which
variant to use, that's a decision for whoever dispatched you, not something to guess
here — surface it rather than picking one.

## Part 8 — Self-verification gate

Before you report anything — FRESH, AUDIT, or REPAIR — confirm every box below. Don't
report a doc set you haven't verified; a red box means fix it or drop the claim, then
re-check.

- [ ] Every `path:symbol` written anywhere in `superdoc/` resolves: the path exists and the
      symbol is actually in it (grep it, don't eyeball it).
- [ ] Every relative link written anywhere in `superdoc/` resolves to a file that exists.
- [ ] Every `@`-ref in `CLAUDE.md` points to a file that **exists on disk** — this is
      the single most common failure mode (a force-loaded reference that 404s breaks
      every session's context, silently). Check each one by hand.
- [ ] The `@`-set in `CLAUDE.md` is exactly `superdoc/meta/TERMINOLOGY.md` plus everything
      under `superdoc/claude-instructions/` — nothing more.
- [ ] Every capability page written has at least one inline `*Why:*` note, or
      genuinely has no non-obvious decision to record (don't force one).
- [ ] No claim in any doc contradicts the code as it currently reads (re-check the
      module map and any behavioural claim against the real source, not memory of it).
- [ ] Wikilinks used only if `.obsidian/` is present at the repo root — detect it,
      don't guess.
- [ ] The `superdoc:vN` marker in `CLAUDE.md` matches this playbook's version exactly
      (Part 6).

## Part 9 — AUDIT (report-only)

Idempotent, re-runnable over an existing `superdoc/` — same rules as FRESH, just verifying
instead of creating. **Do not write to any file in this mode.**

- Run the full Part 8 gate against the existing `superdoc/` and `CLAUDE.md`.
- Grep every referenced `path`/`symbol` and every relative link; list what doesn't
  resolve.
- List code capabilities/modules with no corresponding doc page.
- List doc claims that no longer match the code (behaviour drifted).
- Check the installed `superdoc:vN` marker (Part 6) against this playbook's version;
  flag if older.
- Flag any `@`-ref outside the Part 5 allowed set, and any `@`-ref that's broken.
- Re-check Part 0: if `superdoc/` never grew past scaffolding, say so and propose
  collapsing it back into `CLAUDE.md`.

Report every finding as a concrete, project-specific item (file + line + what's wrong),
not a generic checklist recap.

## Part 10 — REPAIR (in place, only named items)

Only touch the items explicitly named for repair — never expand scope to "fix
everything AUDIT found" on your own initiative.

- Fix the doc to match the code — **code wins**, always. Fix the doc now, in this
  change.
- Broken `@`-ref or link → either fix the path or remove the reference, whichever
  reflects reality.
- Stale claim genuinely out of scope to fix right now → leave a single greppable
  `STALE:` marker at the point of the claim instead of silently leaving it wrong.
- Re-run the full Part 8 gate after repairing before you report done.
- Keep edits to shared pages (module-map rows, `README.md` index lines) small and
  append-oriented, so they read as a clean diff against whatever else is touching
  `superdoc/` in this change.

## Code is source of truth

The code is the source of truth; `superdoc/` is a cache that lets an agent navigate it
fast. If a doc and the code disagree, trust the code — then fix the doc. This is the
one rule everything else in this playbook exists to serve.
