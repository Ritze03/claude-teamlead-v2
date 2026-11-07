---
name: teamlead-superdoc
description: Use for /teamlead superdoc, /superdoc, or "init superdoc". Sets up, audits, or repairs a project's self-maintaining documentation system in superdoc/ — the agent-facing knowledge base, kept separate from the user-facing docs/.
---

# Superdoc mode

**Doc folder: `superdoc/` at the repo root by default. Never ask, never detect.** If the
user explicitly asks in plain text for another folder, location, or layout, that wins:
do what they asked, and put that folder in every dispatch brief as the doc root (the
playbook substitutes it everywhere). Absent such a request, every brief just says
`superdoc/`.

That is the agent's knowledge base; `docs/` stays user-facing unless the user said otherwise.

**Privacy: superdoc files are committed and often public.** Every worker brief must say:
repo-relative paths only, and no personal or system information (usernames, emails,
hostnames, absolute host paths, secrets, the author's local setup). Playbook Part 4a has
the full rule; audit mode greps for leaks.

**You orchestrate; you do not read, inventory, or write docs yourself.** Every unit
of real work goes to a worker. Stay inside the target project.

## Worker knowledge base

Workers don't inherit this skill, so every dispatched superdoc worker must read the
playbook and copy the assets from the plugin root, which you give it as a **literal
absolute path in its brief**:

```
<plugin-root>/skills/teamlead-superdoc/playbook.md
<plugin-root>/skills/teamlead-superdoc/assets/   (documentation.md, version-policy-*.md)
```

`CLAUDE_PLUGIN_ROOT` is **not** set in your shell; resolve the path once with
`cat .claude/teamlead/.state/plugin-root` and paste the real path into every brief.
Do **not** tell a worker to run `$(cat .claude/teamlead/.state/plugin-root)` itself:
workers run in a git worktree, and that state file lives in the main checkout's
`.claude/`, so in the worktree it is missing and the path collapses to `/skills/...`.

Tell workers to fetch the playbook and assets with the **Read tool** and write copies
with the **Write tool**, not Bash `cp`. Claude Code's worktree guard refuses Bash
commands that write and name a host path with `Git` in a segment (for example
`.../GitHubProjects/...`): "names git in a form too complex to verify" (issue #5).
Read and Write are not guarded.

Resolve it once with Bash and put the real path in every worker brief.

**Top of every run:** if `<doc root>/claude-instructions/documentation-version-policy.md`
exists, have it read **first** — the version policy governs the whole run.

## Step 1 — Detect state (run this yourself, no worker)

**Run this with Bash as your first action.** Do not skip it and do not delegate it:

```bash
DOC=superdoc   # change only if the user named another folder (no trailing slash)
test -d "$DOC" && echo "superdoc: present" || echo "superdoc: absent"
test -f CLAUDE.md && grep -q 'superdoc:start' CLAUDE.md && echo "CLAUDE.md: wired" || echo "CLAUDE.md: not wired"
# Installed contract version: the vN on the guarded marker, or "none" (also when CLAUDE.md is absent).
echo "superdoc marker: $(grep -om1 'superdoc:start v[0-9]*' CLAUDE.md 2>/dev/null | sed 's/.*start //' | grep . || echo none)"
git check-ignore -q "$DOC" 2>/dev/null && echo "⚠ GITIGNORED — superdoc must be committed or the knowledge dies at the next clone" || echo "git: superdoc is tracked"
# A dangling @-ref loads NOTHING and says nothing about it — the docs look wired
# while the agent silently gets none of them.
grep -oE "@$DOC/"'[^ )`]+' CLAUDE.md 2>/dev/null | sed 's/^@//' | while read -r f; do
  test -f "$f" || echo "⚠ CLAUDE.md force-loads $f — that file does not exist"
done
# Force-load budget: CLAUDE.md plus every @-ref target sits in context for the whole
# session, goes out with every request, and every worker carries its own copy.
total=0
for f in CLAUDE.md $(grep -oE "@$DOC/"'[^ )`]+' CLAUDE.md 2>/dev/null | sed 's/^@//' | sort -u); do
  test -f "$f" || continue
  b=$(wc -c < "$f"); total=$((total + b)); echo "force-loaded: $f ${b}B"
  if [ "$b" -gt 8192 ]; then echo "⚠ $f is ${b}B (over 8 KB): force-loaded files are paid for all session"; fi
done
echo "force-loaded total: ${total}B"
if [ "$total" -gt 20480 ]; then echo "⚠ force-loaded total is ${total}B (over 20 KB)"; fi
```

A `⚠` from the size check is a HEALTH-CHECK finding (Step 3), not something to fix now.

**If it reports `⚠ GITIGNORED`, fix that first.** The failure is silent: everything
works locally and the knowledge vanishes for anyone who clones. Un-ignore it before
writing a single page.

`superdoc: absent` → **FRESH**. Present → **Step 1b** (automatic upgrade check), then
**HEALTH-CHECK**, and REPAIR only if asked.

## Step 1b — Upgrade an older install (automatic, no offer, no question)

Runs on every `/superdoc` against an existing install, right after Step 1 and before the
health check. Compare the snippet's `superdoc marker: vN` with `superdoc: vM` on line 3 of
`<plugin-root>/skills/teamlead-superdoc/playbook.md` (`sed -n 3p` it yourself).

- **N ≥ M** → nothing to do; go to HEALTH-CHECK.
- **N < M** → apply the upgrade **now, as the first thing, without offering or asking**.
  Dispatch **one writing worker** (Sonnet) in a worktree like any other doc write; you do
  not implement it. The brief names playbook Part 6, the installed `vN` and the target
  `vM`. Several versions behind: the worker applies each version's step in order (v2 → v3,
  then every later one) and re-stamps the marker to `vM`. An upgrade applies only what
  changed in those versions: existing files are not rebuilt from skeletons, and entries
  are not rewritten. Then tell the user in **one line** what happened, for example
  `Upgraded the superdoc contract v2 → v3: added the short-entry rule to TERMINOLOGY.md,
  re-stamped the marker.` It is never silent. Then run HEALTH-CHECK on the upgraded tree,
  so its findings reflect the new version.
- **`superdoc/` present with marker `none`** → not an upgrade. That is likely hand-written
  docs: confirm with the user before regenerating anything (playbook Part 6).

*Why:* the newest contract is assumed to be the best available, and an offer only leaves
projects stale. The upgrade is a separate step before the audit, so the audit itself stays
report-only.

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
and dated design-spec docs for big decisions — all under the doc root. Wire a thin
`CLAUDE.md` via the guarded markers, `@`-force-loading only TERMINOLOGY and
`claude-instructions/*`.

**Hold that line at QC.** `@` pastes a file's whole contents into context at session
start, where it stays and goes out with every request, in every worker that loads
`CLAUDE.md` too, so each one is a permanent tax on all future work. Anything
else — `overview.md`, capability pages, the styling guide — is a plain link an agent
reads when it needs it. A worker that force-loads more has made every task in this
repo more expensive; send it back.

## Step 3 — HEALTH-CHECK

Dispatch workers to audit the existing tree against the playbook: missing pages,
stale content, broken structure, absent Why-notes, unwired CLAUDE.md, and any
`@`-ref in `CLAUDE.md` pointing at a file that no longer exists, and **force-load
bloat**: any force-loaded file (`CLAUDE.md` plus every `@`-ref target) over 8 KB, a total
over 20 KB, or content in them that isn't needed on every task (playbook Part 9 has the
judgement pass; the verbatim `claude-instructions/` installs count toward the total but
are never flagged for trimming). **Report findings. Do not fix.** (The audit is report-only; the Step 1b upgrade has
already run before it.) When it finds bloat,
offer the cleanup to the user; it then runs as Step 4 REPAIR on the named items, never
automatically.

**Installed marker older than the playbook's version** at this point means the Step 1b
upgrade failed: report it as a finding and say why. (For v2 → v3 the upgrade adds the
short-entry rule to an existing `meta/TERMINOLOGY.md`, and the audit reports entries over
~300 characters; entries are never rewritten by an upgrade.)

## Step 4 — REPAIR (only on explicit ask)

**Never auto-fix audit findings** (the upgrade in Step 1b is not a repair and is not
covered by this rule). Only when the user asks, dispatch workers against the named
items, in place, **per-item tier** (reading → Sonnet, ordinary writing → Sonnet,
architectural rationale → Opus; ask if unsure). Then run **QC after repair** —
`tl-sonnet-high` by default, `tl-opus-high` only for architectural repairs.

## Why superdoc sits at the root

Considered and rejected: `.claude/teamlead/superdoc/`, to sit with the other agent
state. Two problems killed it. `.claude/` is gitignored in many repos, so the
knowledge would die at the next clone — silently. And feature pages carry inline
**Why:** notes that a human occasionally wants; buried under `.claude/` nobody
browsing the repo finds them. At the root it is committed by default and stays
discoverable, while `docs/` vs `superdoc/` still does the intended work. (That is why it
is the default; a user who asks for a different folder still gets it.)

**Do not also copy it into `.claude/`.** Agents do not find superdoc by location —
they find it because `CLAUDE.md` force-loads the mandatory set, and that works from
the repo root and every worktree below it. A second copy under `.claude/` would
reintroduce the gitignore risk this placement exists to avoid, and leave two copies
to drift apart when being current is the entire value.
