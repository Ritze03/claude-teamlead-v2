# superdoc playbook — worker knowledge base

`superdoc: v4`

This file is the **only** place the superdoc contract version lives. Everything that
detects FRESH vs HEALTH-CHECK, or decides on a version upgrade, compares against the `vN`
on this line — see Part 6 for exactly where that number gets stamped into the target
repo.

**The docs are written for agents and owned by agents; the user never has to read or touch
them.** Clean up, restructure, trim, split, move and delete on your own judgement, derived
from this playbook, and never ask the user what is right for the docs or whether they would
like a change. Only three things go to the user: rewriting git history over an already
committed leak (never automatic), hand-written `superdoc/` with no marker (confirm before
regenerating, Part 6), and facts only the user knows (what a project term means, why a
design was chosen). If a dispatching brief or a step below seems to ask for anything else,
decide it yourself, state the default you took, and move on.

You are a dispatched worker building, auditing, or repairing a project's
self-maintaining docs system. Your cwd is the **target repo**, not this skill's
directory — this skill's own files (`assets/`) live under
`<plugin-root>/skills/teamlead-superdoc/`, where `<plugin-root>` is the literal absolute path
your brief gave you. They will not resolve relative to your cwd. Do not look the root up
yourself with `cat .claude/teamlead/.state/plugin-root`: you run in a worktree and that
file is in the main checkout, so it is missing there. If the brief gave no plugin root,
stop and ask the lead. Every path that starts with `superdoc/` or `CLAUDE.md` is
relative to the target repo root, i.e. your cwd.

**`superdoc/` — the doc-root folder for this run.** The dispatching brief names it. The
default is `superdoc/`; if the brief names another folder (the user asked for one),
substitute it wherever this playbook writes `superdoc/` — every path, skeleton, and
`CLAUDE.md` `@`-ref. The structure inside it, the `superdoc:` marker, and every rule
below are unchanged.

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
grew into it, say so in the report; the repair phase then collapses it back into `CLAUDE.md`
(moving every fact first, Part 10), without asking.

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
a mature reference project's `docs/`:

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

**One page per capability, each in its own file.** Every feature, backend, subsystem or
other distinct capability gets its own page, so pages stay small and single-topic: agents
read only the page they need, which costs less than one big page. A new capability is a new
page, never a section tacked onto another page; a page that has grown to cover several is
split (Part 10 does it automatically after the audit flags it).

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

**Keep every entry short: what the term is, and where to read more.** One or two
sentences, about 200 characters. Details, behaviour, option names, history and rationale
belong on the linked doc page. If that page doesn't exist and there is more to say, write
the page; don't grow the entry. When you amend an entry, trim it to this form instead of
appending. This file stays in context for the whole session.

## Terms

- **Term** — what it is, in one line. See `superdoc/features/term.md`.
```

*Why:* this file is force-loaded: it occupies context for the whole session, goes out
with every request, and every worker that loads `CLAUDE.md` carries its own copy, while a
linked page costs nothing until an agent needs it. The rule sits inside the file's own
standing text because that is the one place every agent adding a term is guaranteed to
see it. A plain term with nothing more to read needs no link.

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
worse than no heading. One page per capability, not one page per file that touches it,
and one capability per page: a second feature, backend or subsystem gets its own page,
not a section on this one.

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
  explains (exact style: `*Why:* the colon was applied
  inconsistently...`).
- **Promote it to a standalone dated design-spec doc** (Part 3's skeleton) only when
  the decision is big enough that an inline note can't hold it — a real architecture
  trade-off, a path considered and rejected, something worth finding again on its own.
- If the user explains why something is done a certain way, or answers a "why?" you
  asked, write it down right then. A design choice that lives only in a chat message
  is gone the moment the context window rolls; the doc is where it survives.

### Part 4a — Privacy: nothing personal or system-specific

Superdoc files are committed and often public. Treat every page as published, and write
them anonymized, like a filed bug report.

- **Repo-relative paths only.** Never an absolute host path (`/home/<user>/...`,
  `/Users/...`, `C:\Users\...`).
- **Never write:** usernames, real names, emails, hostnames or machine names, the names of
  the user's own client/server machines or network (hosts, shares, VPNs, domains), IPs,
  MAC addresses, serial numbers and other device identifiers, the author's machine or
  OS specifics, local tool setup, secrets, tokens, API keys, `.env` values, or names of
  private projects unrelated to this repo. "Client" and "server" as software concepts are
  fine; the identity of a real machine is not.
- **Setup instructions are generic.** Say "your plugin root", `$HOME`, `<your-token>`,
  not the author's actual values.
- If a source you are reading contains such a value, describe it generically; do not copy it.
  Logs, command output (prompts, `ssh`/`scp` lines, mount paths, `uname`, `ip a`) and text the
  user pasted in chat are the usual source: write `<client>`, `<server>`, `<host>`, not the name.
- **Local details have a home: `.claude/local/`.** Agents do need things like how to reach a
  test machine, and if the docs are the only place to put it, it ends up there. The real
  values go in a file under `.claude/local/` (untracked); the page says generically that
  they exist and where (`see .claude/local/<topic>.md`), never the values. Secrets (tokens,
  passwords, keys) go nowhere in the repo, not even there. Untracked means git ignores it:
  add `.claude/local/` to the repo's `.gitignore` (committed, so every clone is covered;
  `.git/info/exclude` would protect only this one clone) unless `git check-ignore -q
  .claude/local/x` already says it is ignored, for example when `.claude/` is ignored whole.
  The directory is per checkout. A worker in a git worktree writing `.claude/local/` inside
  that worktree loses it with the worktree, so the lead puts the **main checkout's absolute**
  `.claude/local/` path in the repair row's `owns` (the worker fence allows an absolute
  `owns` entry; it is how any out-of-worktree write is granted) and the worker writes the
  real values there. Reports never carry the values: they name file, line and kind only.

## Part 5 — CLAUDE.md wiring

Wrap the merged block in guarded markers so a re-run can find and replace it instead
of duplicating it. Adapt the reference-docs list to what Part 2 actually built (real
page names, the capability folder name from Part 1); the markers and structure below
stay fixed.

```markdown
<!-- superdoc:start v4 -->
## Docs: read before you touch, update after you change

Full discipline — what to read, when to update, how to record the *why* — lives in the
always-loaded `superdoc/claude-instructions/documentation.md` below; this is a pointer, not
a restatement.

Reference docs — plain links, read the one relevant to your task on demand:

- **[superdoc/architecture/overview.md](superdoc/architecture/overview.md)** — codebase
  navigation map (module map, data flow, "where to look for X"). **Start here to navigate
  the code.**
- Per-<capability> behaviour — [superdoc/<capability>/](superdoc/<capability>/)
- Styling rules — [superdoc/ui/STYLING-GUIDE.md](superdoc/ui/STYLING-GUIDE.md) (only if this
  project has a UI)
- [superdoc/README.md](superdoc/README.md) — the docs table of contents (only once it
  exists, see Part 2)

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

Path base: `CLAUDE.md` uses repo-root-relative paths (`@superdoc/...` and the link targets
above, written as real markdown links, never code spans: `map.py` ignores code spans, so a hub
named only in one gets no inbound link and is reported ORPHAN); links *inside* docs are
docs-relative. Precedence: `CLAUDE.md` is authoritative for
rules, docs are the reference — reconcile to `CLAUDE.md` on conflict. `@`-budget:
force-load a file only if its absence would let the agent do the wrong thing on *any*
task.
<!-- superdoc:end -->
```

The `@`-force-load set is **exactly** `superdoc/meta/TERMINOLOGY.md` plus every file under
`superdoc/claude-instructions/` — nothing else, ever. Every other doc (`overview.md`,
every capability page, `STYLING-GUIDE.md`, `README.md`) is a plain on-demand link.

**Why the set is this small.** `@` does not suggest a file, it *pastes* it — the whole
contents load at session start (and again after `/clear` or compaction), then sit in
context for the whole session and go out with every request (mostly at the cached rate),
whether or not the task has anything to do with it. Every worker that loads `CLAUDE.md`
carries its own copy. A plain link costs nothing until an agent chooses to read
it, and an agent that needs `STYLING-GUIDE.md` will find it from the overview. So each `@`
is a permanent tax levied on every future session, paid to avoid one lookup. It is worth
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
`superdoc/`, `CLAUDE.md` just points into it (the shape to match:
short project overview, a "Docs" pointer section, then the `@` block, nothing more).

## Part 6 — Pin the `superdoc:` marker

The marker lives in exactly **one** place: the opening line of the guarded block
inside the target repo's `CLAUDE.md` —

```
<!-- superdoc:start v4 -->
```

The `vN` there is the installed contract version. State detection reads it directly:
`superdoc/` folder present **and** this marker found in `CLAUDE.md` → an existing
installation (HEALTH-CHECK/AUDIT territory); no `superdoc/` and no marker → FRESH; `superdoc/`
present **without** the marker → likely hand-written docs, confirm before regenerating
(the dispatcher's Step-1 guard). Version compare
for an upgrade is: installed `vN` on this line vs. the `superdoc: v4` on line 3
of this playbook file — older installed version → the dispatcher applies the upgrade
automatically (SKILL.md Step 1b), as the first thing of the run, before the audit; no
offer. When several versions behind, apply each version's step in order. An upgrade
re-stamps the marker and applies only what changed since the installed version, never a
regeneration; existing files are not rebuilt from the skeletons. **v2 → v3:** if the project's `meta/TERMINOLOGY.md` lacks the short-entry
rule (`grep -q 'Keep every entry short'`), insert the rule paragraph from Part 3's
skeleton into its standing text, right after the "Keep this file up to date" paragraph.
The upgrade step itself rewrites no entries; entries over ~300 characters (Part 9
command) are found by the audit and trimmed by the repair phase that follows it (Part 10). **v3 → v4:** re-install `superdoc/claude-instructions/documentation.md` verbatim from the
assets (Part 7, Read + Write tools); that adds the "Write docs anonymized" rule to the file
every agent has force-loaded. If the file is absent, create it and confirm `CLAUDE.md` has
its `@`-ref. Nothing else changes in the project: existing docs are not scrubbed by the
upgrade; the next audit reports leaks (Part 9). Do not also stamp a marker under `superdoc/` itself; the `CLAUDE.md` line is
the single source of truth for the installed version.

*Why:* the newest contract is assumed to be the best available, and an offer only leaves
projects stale. The upgrade step only applies its own version's changes; the cleanup of
what the audit then finds (oversized force-loaded content, leaks, big pages) is the repair
phase right after it, which the agents run on their own.

## Part 7 — Verbatim-install files

Two files get **copied**, not retyped, from this skill's asset directory into the
target repo. Copying preserves exact wording the discipline depends on; retyping from
memory drifts.

Use the **Read tool** on `<plugin-root>/skills/teamlead-superdoc/assets/documentation.md`,
then the **Write tool** to create `superdoc/claude-instructions/documentation.md` with
exactly that content. Same for the version policy: Read
`<plugin-root>/skills/teamlead-superdoc/assets/version-policy-<variant>.md`, Write it to
`superdoc/claude-instructions/documentation-version-policy.md`.

Do **not** use Bash `cp <plugin-root>/...`. A worktree-isolated worker's Bash is guarded:
it refuses write-capable commands (`cp`, `>`) that name a path containing `Git` (such as
`.../GitHubProjects/...`) with "names git in a form too complex to verify" (issue #5).
Putting the path in a shell variable does not help, because the literal is still in the
command. Read and Write are not guarded.

Where `<variant>` is one of `date-based`, `auto-bump`, `manual` — whichever version
policy applies to this project. **Install verbatim, do not reword.** Pick the variant
yourself from the project's history: dated changelog headings without version numbers →
`date-based`; a changelog or manifest whose versions are bumped on a schedule the project
already follows → `auto-bump`. When the history does not make it clear, default to `manual`,
the safest (the agent never invents a version number or date), and say in your report which
variant you chose and why.

## Part 8 — Self-verification gate

Before you report anything — FRESH, AUDIT, or REPAIR — confirm every box below. Don't
report a doc set you haven't verified; a red box means fix it or drop the claim, then
re-check.

- [ ] `lint.sh` run first (`bash <plugin-root>/skills/teamlead-superdoc/lint.sh`, whole tree) and
      every finding fixed: it decides what a script can (leaks, line references, dangling
      `@`-refs, force-load size, glossary entry length, pages missing from the README) and never
      prints a leaked value. The boxes below cover what it cannot.
- [ ] `map.py --check` run (`python3 <plugin-root>/skills/teamlead-superdoc/map.py --check`) with
      no `DANGLING` left, and every `ORPHAN` linked from where it belongs or deleted. Run it
      again after any edit under the doc root or to `CLAUDE.md`, and before a rename, move or
      delete use `map.py --links-to PAGE` for the list of links to fix.
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
- [ ] No personal or system information in any page: no absolute host paths, usernames,
      emails, hostnames or machine names, client/server names of the user's own machines or
      network, IPs, MAC addresses, serials, secrets (Part 4a) — grep for it and read for it.
- [ ] One page per capability: no page covers several unrelated features, backends or
      subsystems, and no page is over about 12 KB unless it is one genuinely single topic
      (Part 9 lists both).
- [ ] Force-load budget: no force-loaded file (`CLAUDE.md` plus every `@`-ref target) over
      8 KB, except `TERMINOLOGY.md` (judged by entry length, next box) and the verbatim
      installs (never trimmed); the counted total (verbatim installs left out) under
      20 KB, or, when the glossary's entries are all short, the Part 9 note answered; and
      nothing in them that isn't needed on every task (Part 9).
- [ ] `TERMINOLOGY.md` entries are pointers: none over about 300 characters, wrapped lines
      counted (an entry runs to the next entry or heading), details live on the linked
      pages (`lint.sh` lists offenders). The file has no size limit of its own.

## Part 9 — AUDIT (read-only phase)

Idempotent, re-runnable over an existing `superdoc/` — same rules as FRESH, just verifying
instead of creating. **Do not write to any file in this mode.** (The version upgrade,
Part 6, is a separate step that runs before the audit; the audit itself writes nothing.
The repair phase, Part 10, runs right after it in the same run, automatically, on what the
audit found.)

- **Start from `lint.sh` output:** `bash <plugin-root>/skills/teamlead-superdoc/lint.sh --doc <doc-root>`
  (the literal plugin root from your brief) scans the doc tree and `CLAUDE.md` and prints one
  `path:line: error|warn: <kind>` per finding, never the value. Its findings are the audit's first
  items; the bullets below are what it cannot decide. **Errors** (high-confidence leaks): absolute
  home paths, emails, private-range IPs (RFC 1918, link-local, CGNAT). **Warnings:** other
  machine-specific host paths and public IPs, `file.ext:123` line references under `architecture/`,
  dangling `@`-refs, the force-load size findings, TERMINOLOGY entries over ~300 characters, and
  pages missing from `README.md`. Loopback, documentation ranges, `example.*` addresses and
  placeholder homes (`/home/user`, `$HOME`, `<name>`) are never findings. A line carrying
  `superdoc-lint: allow` is skipped: for a true false positive only, never for a real value.
  A value that keeps tripping it (a version string read as an IP, a public handle) goes on the
  project allow list instead: one line `value  # why it is not a leak` in
  `<doc-root>/meta/leak-allow.txt` (see SKILL.md, "Suppressing a false positive").
- **Link graph:** `python3 <plugin-root>/skills/teamlead-superdoc/map.py --check` lists
  `DANGLING` links (a missing file or a `#anchor` no heading matches) and `ORPHAN` pages (nothing
  links to them). Both are audit findings; fix dangling links by retargeting or removing them,
  and give an orphan a link from its folder's `README.md` or delete it.
- Run the full Part 8 gate against the existing `superdoc/` and `CLAUDE.md`.
- Grep every referenced `path`/`symbol` and every relative link; list what doesn't
  resolve.
- List code capabilities/modules with no corresponding doc page.
- List doc claims that no longer match the code (behaviour drifted).
- Check the installed `superdoc:vN` marker (Part 6) against this playbook's version.
  The upgrade runs before the audit, so an older marker here means it failed: still
  report it.
- Flag any `@`-ref outside the Part 5 allowed set, and any `@`-ref that's broken.
- Re-check Part 0: if `superdoc/` never grew past scaffolding, report it as a
  finding; the repair phase collapses it back into `CLAUDE.md`.
- **Privacy scan (Part 4a):** the leak checks are `lint.sh` (above): every error is a finding
  (file + line + kind), not a candidate to second-guess, and its allowlist already drops
  placeholders. What it cannot decide stays a judgement scan, printing `file:line` only so its
  output carries no value: tokens and secrets,
  `grep -rnIE '(sk|ghp|xox[bp]|AKIA)[-_A-Za-z0-9]{12,}|(token|secret|api[_-]?key|password)[ :=]+\S{8,}' <doc-root> CLAUDE.md | cut -d: -f1,2`.
  Read each hit and drop false positives (example placeholders are fine); a real secret is a
  finding, and its value is never quoted anywhere.
- **Identity values of this machine** (the regex cannot see a bare hostname or a name): grep
  the same files for the real `hostname`, `$USER`, `git config user.name` and
  `git config user.email`, case-insensitive, fixed strings, empty values skipped. It prints
  `file:line` only, so its output carries no identity value:
  `for v in "$(hostname 2>/dev/null || uname -n)" "${USER:-$(id -un)}" "$(git config user.name)" "$(git config user.email)"; do [ -n "$v" ] && grep -rnIiF -e "$v" <doc-root> CLAUDE.md 2>/dev/null | cut -d: -f1,2; done`
  A short or generic value (a two-letter user, `localhost`) matches ordinary words: read
  each hit and drop those.
- **Judgement pass:** no grep knows every machine name, so read the pages for names that look
  like machines or network hosts: example output, log excerpts, `ssh`/`scp` lines, mount
  paths, `user@host` prompts, a "my laptop" or "the NAS" that names a real device. Report
  each privacy finding as file + line + the kind of leak (hostname, client/server name,
  username, ...), **never quoting the value**: the report must not repeat the leak.
- **Force-load budget:** force-loaded = `CLAUDE.md` plus every `@`-ref target in it
  (TERMINOLOGY plus everything under `claude-instructions/`). It sits in context for the
  whole session and is resent with every request, in every worker. Report each file's
  size and the counted total (`lint.sh --doc <doc-root> --force-load` prints the report, labelling each file, the same one SKILL.md Step 1 runs):
  flag any single file over 8 KB, except `TERMINOLOGY.md` (judged by entry length, next
  bullet), and a counted total over 20 KB. **Counted** means `CLAUDE.md`, `TERMINOLOGY.md`
  and project-owned files. `documentation.md` and `documentation-version-policy.md` are
  verbatim installs: list them in the size report, marked as such, but leave them out of
  the total and never flag them for trimming, since the project doesn't own their wording
  (a healthy tree counts around 10 KB). Then read each force-loaded file and flag content
  not needed on every task — reference material, feature detail, history, rationale — and
  name the linked page it should move to.
- **TERMINOLOGY.md entry length** (the specific case of the above; the file's size is not
  flagged, its entries are): `lint.sh` lists every entry over ~300 characters (the 200 in the
  skeleton is the guide; 300 is the threshold, so normal entries aren't flagged) as a finding,
  with the line it starts on and its summed length. An entry is its `- **` line plus every
  following line up to the next entry or heading, so a hard-wrapped entry counts whole (`length`
  counts bytes under some awks and newlines are not counted; treat near-threshold hits as
  approximate). Also flag the file if it lacks the short-entry rule:
  `grep -q 'Keep every entry short' <doc-root>/meta/TERMINOLOGY.md`.
- **Total over budget, every entry short** (a note, not a finding to cut): the glossary can
  be complete and still push the counted total past 20 KB. Ask yourself, not the user,
  whether every term has to be known on every task. A term only one feature uses moves to
  that feature's page, which is a repair you make yourself (Part 10). Never delete a term
  just to meet a number, and never split the file into a core list and a linked list: the
  "ask before acting on an undefined term" rule only works if the force-loaded list is
  complete.

- **Page size and scope** (one page per capability, Part 2): list every page over about
  12 KB: `find <doc-root> -type f -name '*.md' -size +12288c -exec wc -c {} \;`
  Then read for pages covering more than one feature, backend or subsystem (several
  unrelated top-level `##` sections is the tell). Report each with file, size and the
  capabilities it mixes. A big page on one genuinely single topic may stay: 12 KB is a
  prompt to look, a judgement call, not a hard limit.

Report every finding as a concrete, project-specific item (file + line + what's wrong),
not a generic checklist recap.

## Part 10 — REPAIR (in place, the audit's findings)

Runs automatically right after the audit, in the same run, with no offer and no question.
The named items are the audit's findings (privacy leaks first): fix each one, and do not
widen the scope beyond them. Decide any judgement call yourself from this playbook.

- Fix the doc to match the code — **code wins**, always. Fix the doc now, in this
  change.
- Broken `@`-ref or link → either fix the path or remove the reference, whichever
  reflects reality.
- Stale claim genuinely out of scope to fix right now → leave a single greppable
  `STALE:` marker at the point of the claim instead of silently leaving it wrong.
- **Trimming a force-loaded file** (an oversized `TERMINOLOGY.md` entry, or bloat in
  `CLAUDE.md` or a project-owned `claude-instructions/` file): move the detail to a
  linked doc page first, and never delete information that exists nowhere else. Open the
  target page and confirm it really holds the content (or add it there, or create the
  page) *before* you cut the original down to what-it-is plus the link. Never trim the
  verbatim installs. When an entry's detail has no page yet, it gets its own new page.
  For the Part 9 "total over budget, every entry short" note: move a term that only one
  feature uses to that feature's page (leave a plain link where it was needed), the same
  move-first way. Never delete a term just to meet a number, and never split the glossary
  into a core list and a linked list: the "ask before acting on an undefined term" rule
  needs the force-loaded list to be complete.
- **Splitting a page** (one flagged for covering several capabilities, or over about 12 KB
  with more than one topic): create one new page per capability and move the content into
  them **verbatim**. Fix every link and `@`-ref that pointed at the moved content, add the new
  pages to the `README.md` index and the overview's module map, then confirm nothing was lost
  (compare headings and facts of the original against the new pages) *before* cutting the
  original down to its own single topic.
- **Privacy leak** (a Part 9 finding): replace the value with a placeholder (`<client>`,
  `<server>`, `<host>`, `$HOME`, or a generic description), automatically. **Move before
  you replace**, like any trim: a real value that is useful to future agents (how to reach a
  test machine, a local path, a device name) first goes to `.claude/local/<topic>.md`
  (Part 4a: confirm it is git-ignored, and write it through the main checkout's absolute
  path the lead put in your row's `owns`), and only then does the page get the placeholder
  plus a generic pointer to that file. A **secret** (token, password, key, `.env` value) is
  never copied anywhere: remove it, and say in the report that one was found. Removing a
  value from the file does not remove it from git history: when the file was already
  committed, report that to the lead, and whether it was already pushed. The lead then
  tells the user the value is in history, whether the repo is public (`gh repo view --json
  visibility`, or the remote's host), and that any exposed credential must be rotated first,
  because a history rewrite does not undo exposure. Rewriting history or force-pushing is
  the user's decision, never done automatically.
- Re-run the full Part 8 gate after repairing before you report done.
- Keep edits to shared pages (module-map rows, `README.md` index lines) small and
  append-oriented, so they read as a clean diff against whatever else is touching
  `superdoc/` in this change.

## Code is source of truth

The code is the source of truth; `superdoc/` is a cache that lets an agent navigate it
fast. If a doc and the code disagree, trust the code — then fix the doc. This is the
one rule everything else in this playbook exists to serve.
