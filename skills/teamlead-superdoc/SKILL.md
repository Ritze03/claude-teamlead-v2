---
name: teamlead-superdoc
description: Use for /teamlead superdoc, /superdoc, or "init superdoc". Sets up, audits, or repairs a project's self-maintaining documentation system in superdoc/ — the agent-facing knowledge base, kept separate from the user-facing docs/.
---

# Superdoc mode

**`superdoc/` at the repo root. Always. No alternative, no detection, no asking.**

That is the agent's knowledge base; `docs/` stays entirely user-facing. Fixing the
location is what removes the doc-root machinery v1 carried everywhere — you never
substitute a folder name, and every dispatch brief just says `superdoc/`.

**You orchestrate; you do not read, inventory, or write docs yourself.** Every unit
of real work goes to a worker. Stay inside the target project.

## Worker knowledge base

Workers don't inherit this skill, so every dispatched superdoc worker must read,
by **absolute path**:

```
$(cat .claude/teamlead/.state/plugin-root)/skills/teamlead-superdoc/playbook.md
```

Assets to copy verbatim live in `$(cat .claude/teamlead/.state/plugin-root)/skills/teamlead-superdoc/assets/`.

`CLAUDE_PLUGIN_ROOT` is **not** set in your shell; that state file holds the absolute path.
Resolve it once with Bash and put the real path in every worker brief.

**Top of every run:** if `superdoc/claude-instructions/documentation-version-policy.md`
exists, have it read **first** — the version policy governs the whole run.

## Step 1 — Detect state (run this yourself, no worker)

**Run this with Bash as your first action.** Do not skip it and do not delegate it:

```bash
test -d superdoc && echo "superdoc: present" || echo "superdoc: absent"
test -f CLAUDE.md && grep -q 'superdoc:start' CLAUDE.md && echo "CLAUDE.md: wired" || echo "CLAUDE.md: not wired"
git check-ignore -q superdoc 2>/dev/null && echo "⚠ GITIGNORED — superdoc must be committed or the knowledge dies at the next clone" || echo "git: superdoc is tracked"
# A dangling @-ref loads NOTHING and says nothing about it — the docs look wired
# while the agent silently gets none of them.
grep -oE '@superdoc/[^ )`]+' CLAUDE.md 2>/dev/null | sed 's/^@//' | while read -r f; do
  test -f "$f" || echo "⚠ CLAUDE.md force-loads $f — that file does not exist"
done
```

**If it reports `⚠ GITIGNORED`, fix that first.** The failure is silent: everything
works locally and the knowledge vanishes for anyone who clones. Un-ignore it before
writing a single page.

`superdoc: absent` → **FRESH**. Present → **HEALTH-CHECK**, and REPAIR only if asked.

## Step 2 — FRESH setup

Ask the tier, then take one of two paths.

**2a — GROUND-SETUP (empty/greenfield).** No capabilities exist yet, so **do not
scout or fan capability pages** — writing docs for code that isn't there is exactly
the anti-pattern. Dispatch **one worker** to lay the skeleton per playbook Part 0's
greenfield section: a **stub** `superdoc/architecture/overview.md` hub,
`superdoc/meta/TERMINOLOGY.md` seeded with the standing "ask before acting on an
undefined term" rule plus an empty Terms list, `superdoc/claude-instructions/documentation.md`
and the version-policy file copied verbatim, plus a thin `CLAUDE.md` (project-name
stub, guarded `superdoc:start`/`superdoc:end` markers, minimal `@`-set). **No**
`features/` or `README.md` ToC yet — those accrete as features get built. Then QC.

Tell the user plainly: the discipline is live from here, so every feature built
from now gets documented as it lands.

**2b — full FRESH (real capabilities). Scout-then-fan.** Dispatch a **Sonnet**
scout to inventory real capabilities (entry points, modules, features). When it
returns, **MAP one worker per capability folder**, each scoped to its own folder so
writes never collide.

**Tier per capability:** reading/inventory → Sonnet · ordinary doc-writing
(`features/*.md`, UI pages) → Sonnet · only `superdoc/architecture/overview.md` and
genuinely architectural rationale → Opus. The feature-page boundary is blurry —
**ask if unsure** rather than guessing.

Workers emit: `architecture/overview.md` hub, `meta/TERMINOLOGY.md`,
`ui/STYLING-GUIDE.md` if there's UI, `features/*.md` per real capability with inline
**Why:** notes, `claude-instructions/documentation.md` verbatim, `README.md` ToC,
and dated design-spec docs for big decisions — all under `superdoc/`. Wire a thin
`CLAUDE.md` via the guarded markers, `@`-force-loading only TERMINOLOGY and
`claude-instructions/*`.

**Hold that line at QC.** `@` pastes a file's whole contents into every turn of every
session in the project, so each one is a permanent tax on all future work. Anything
else — `overview.md`, capability pages, the styling guide — is a plain link an agent
reads when it needs it. A worker that force-loads more has made every task in this
repo more expensive; send it back.

## Step 3 — HEALTH-CHECK

Dispatch workers to audit the existing tree against the playbook: missing pages,
stale content, broken structure, absent Why-notes, unwired CLAUDE.md, and any
`@`-ref in `CLAUDE.md` pointing at a file that no longer exists. **Report
findings. Do not fix.**

## Step 4 — REPAIR (only on explicit ask)

**Never auto-fix.** Only when the user asks, dispatch workers against the named
items, in place, **per-item tier** (reading → Sonnet, ordinary writing → Sonnet,
architectural rationale → Opus; ask if unsure). Then run **QC after repair** —
`tl-sonnet-high` by default, `tl-opus-high` only for architectural repairs.

## Why superdoc sits at the root

Considered and rejected: `.claude/teamlead/superdoc/`, to sit with the other agent
state. Two problems killed it. `.claude/` is gitignored in many repos, so the
knowledge would die at the next clone — silently. And feature pages carry inline
**Why:** notes that a human occasionally wants; buried under `.claude/` nobody
browsing the repo finds them. At the root it is committed by default and stays
discoverable, while `docs/` vs `superdoc/` still does the intended work.

**Do not also copy it into `.claude/`.** Agents do not find superdoc by location —
they find it because `CLAUDE.md` force-loads the mandatory set, and that works from
the repo root and every worktree below it. A second copy under `.claude/` would
reintroduce the gitignore risk this placement exists to avoid, and leave two copies
to drift apart when being current is the entire value.
