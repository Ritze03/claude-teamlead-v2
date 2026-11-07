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
repo-relative paths only, and write anonymized, like a filed bug report: no personal or
system information (usernames, real names, emails, hostnames or machine names, the names
of the user's own client/server machines or network, IPs, MAC addresses, serials, absolute
host paths, secrets, the author's local setup). Logs and pasted output are the usual source:
describe them generically. Playbook Part 4a has the full rule; audit mode greps for leaks.

**Superdoc is for agents, not the user.** The user never has to read or touch it, so agents
clean it up, restructure, trim, move and delete in it on their own judgement, derived from
the plugin's instructions (this skill and the playbook), and never ask the user what is
right for the docs or whether they would like a change. Only three things go to the user:
(1) rewriting git history or force-pushing over a leak that is already committed (destructive,
never automatic: tell the user the value is in history and whether it was pushed);
(2) `superdoc/` present with no marker, which is hand-written docs someone else owns
(confirm before regenerating, Step 1b); (3) facts only the user knows: what a project term
means (the TERMINOLOGY "ask before acting on an undefined term" rule) and why a design was
chosen. Everything else about the docs is the agents' call.

**You orchestrate; you do not read, inventory, or write docs yourself.** Every unit
of real work goes to a worker. Stay inside the target project.

**Tiers (stated here once; every step below follows it).** Reading and scouting are Sonnet.
Writing and fixing superdoc entries is `tl-sonnet-medium`, the overview and rationale pages
included. QC is `tl-sonnet-high`: it reads the diff against the code and re-runs `lint.sh`.
There is no Opus QC. Opus is only an escalation after a Sonnet worker has actually failed
(retry ladder), with the ceiling `tl-opus-medium`; it is never a first choice for a page
because of what the page is about.

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
# Force-load size report, dangling @-refs and glossary entry length: one script, never a copy
# here (its logic lives in lint.sh only). It prints the `force-loaded:` lines, the `⚠`
# findings and the `note:` below.
bash "$(cat .claude/teamlead/.state/plugin-root)/skills/teamlead-superdoc/lint.sh" --doc "$DOC" --force-load
```

`lint.sh` is also the leak and drift scanner (`lint.sh --doc "$DOC"` for the whole tree; the playbook,
Part 9, lists its checks). A `⚠` from the size check is a HEALTH-CHECK finding (Step 3), not something to fix now.
A `note:` (total over 20 KB while every glossary entry is short) is not a `⚠`: the
repair is the judgement pass in playbook Part 9, never a cut to meet a number.

**If it reports `⚠ GITIGNORED`, fix that first.** The failure is silent: everything
works locally and the knowledge vanishes for anyone who clones. Un-ignore it before
writing a single page.

`superdoc: absent` → **FRESH**. Present → **Step 1b** (automatic upgrade check), then
**HEALTH-CHECK** (audit, then repair, Steps 3 and 4).

## Step 1b — Upgrade an older install (automatic, no offer, no question)

Runs on every `/superdoc` against an existing install, right after Step 1 and before the
health check. Compare the snippet's `superdoc marker: vN` with `superdoc: vM` on line 3 of
`<plugin-root>/skills/teamlead-superdoc/playbook.md` (`sed -n 3p` it yourself).

- **N ≥ M** → nothing to do; go to HEALTH-CHECK.
- **N < M** → apply the upgrade **now, as the first thing, without offering or asking**.
  Dispatch **one writing worker** (`tl-sonnet-medium`) in a worktree like any other doc write; you do
  not implement it. The brief names playbook Part 6, the installed `vN` and the target
  `vM`. Several versions behind: the worker applies each version's step in order (v2 → v3,
  then every later one) and re-stamps the marker to `vM`. An upgrade applies only what
  changed in those versions: existing files are not rebuilt from skeletons, and entries
  are not rewritten by the upgrade step itself (the repair phase after the audit trims
  them, Step 4). Then tell the user in **one line** what happened, for example
  `Upgraded the superdoc contract v3 → v4: re-installed documentation.md (adds the
  anonymize rule), re-stamped the marker.` (Several steps: one line naming what each did.) It is never silent. Then run HEALTH-CHECK on the upgraded tree,
  so its findings reflect the new version.
- **`superdoc/` present with marker `none`** → not an upgrade. That is likely hand-written
  docs someone else owns: confirm with the user before regenerating anything (playbook
  Part 6). This is one of the three things that go to the user.

*Why:* the newest contract is assumed to be the best available, and an offer only leaves
projects stale. The upgrade is a separate step before the audit, so the audit phase itself
stays read-only.

## Step 2 — FRESH setup

Decide the path yourself from the repo, never by asking: an empty or near-empty repo (no
source, no real capabilities) takes 2a, anything with real code takes 2b. If it is borderline,
take 2a (it only lays a skeleton, and docs accrete from there).

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
writes never collide. Inside a folder every feature, backend or subsystem gets its own
page, so a folder holds one page per capability (small single-topic pages; agents read
only the one they need). A worker never folds a second capability into another's page.

Workers emit: `architecture/overview.md` hub, `meta/TERMINOLOGY.md`,
`ui/STYLING-GUIDE.md` if there's UI, one `features/*.md` per real capability with inline
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

Dispatch workers to audit the existing tree against the playbook, **starting from `lint.sh`
output** (the brief carries the literal `<plugin-root>/skills/teamlead-superdoc/lint.sh` path;
its findings are the audit's first items and it never prints a leaked value): missing pages,
stale content, broken structure, absent Why-notes, unwired CLAUDE.md, and any
`@`-ref in `CLAUDE.md` pointing at a file that no longer exists, and **force-load
bloat**: any force-loaded file (`CLAUDE.md` plus every `@`-ref target) over 8 KB, a total
over 20 KB, or content in them that isn't needed on every task (playbook Part 9 has the
judgement pass). Two accounting rules: `meta/TERMINOLOGY.md` is judged by entry length
(entries over ~300 characters are the finding), not by the 8 KB file flag; and the verbatim
`claude-instructions/` installs are listed but left out of the 20 KB total and never
flagged for trimming. A total over budget with every glossary entry short is a note, not a
`⚠`. The audit phase is read-only: its workers write nothing
(the Step 1b upgrade has already run before it) and report findings, privacy leaks first.
**Then, in the same run, go straight to Step 4: dispatch the repairs for the findings. No
offer, no question.** That covers force-load bloat and oversized TERMINOLOGY entries, stale
claims, broken links and `@`-refs, missing pages, and privacy leaks. When it is done, tell
the user in a short summary what was fixed, **privacy leaks first**; if a leaked value was
already committed, say it is in git history and whether it was pushed (that is the user's
call, Step 4).

*Why:* the user said "agents should know that the superdoc is for THEM, so they are free to
clean it up and such, without asking the user what is right and wrong to do. They should
derive that from the instructions of the plugin and their own judgement. Not the users
liking, since the user should never have to touch it." An audit that stops at a report just
hands the user chores about files they never read.

**Installed marker older than the playbook's version** at this point means the Step 1b
upgrade failed: report it as a finding and say why. (For v2 → v3 the upgrade adds the
short-entry rule to an existing `meta/TERMINOLOGY.md`, and the audit reports entries over
~300 characters; the upgrade step does not rewrite entries, the repair phase trims them.
For v3 → v4 it re-installs `claude-instructions/documentation.md`; existing docs are not
scrubbed by the upgrade, the audit finds leaks and the repair phase fixes them.)

## Step 4 — REPAIR (automatic, after the audit)

Runs right after Step 3's audit, in the same run, without offering or asking. The named
items are the audit's findings. Dispatch workers against them, in place, at the tiers above
(`tl-sonnet-medium` writers), then run **QC after repair** (`tl-sonnet-high`). When the repair
and its QC are done, record the audit (below). Only if the user literally asks for a report
only (an audit with no changes) do you stop after Step 3, and record the audit there.

**Record the audit** at the end of Step 4 (Step 3 for a report-only audit), from the main
checkout: `git rev-parse HEAD > .claude/teamlead/.state/superdoc-audit`. SessionStart counts
commits from that one and reminds you when it is more than 50 non-merge commits old; no record
means the count starts at the next session.

A leaked value is replaced with a placeholder automatically, after anything useful in it
has moved to `.claude/local/` (untracked; playbook Parts 4a and 10). A secret is removed,
never copied anywhere. Real values written there go to the **main checkout's absolute**
`.claude/local/` path, so put that path in the repair row's `owns` (a worker's own worktree
copy would vanish with it). **Never rewrite git history or force-push**: when a leaked
value was already committed, repairing the file does not remove it from history, so tell
the user that, whether it was pushed, whether the repo is public (`gh repo view --json
visibility`, or the remote), and that any exposed credential must be rotated first, because
a history rewrite does not undo exposure; the decision stays with them. Trimming never
loses information (playbook Part 10: move to the linked page first).

**Do not trust "read Part 4a".** A privacy-repair worker was once told to read it and
admitted it had not; its edits passed only because the lead grepped them. So the brief for
a privacy repair **carries the rule text itself** (the Privacy paragraph above plus the
`.claude/local/` rule), not a pointer to it, and the **QC after repair re-runs the Part 9
privacy scans on the result** (`lint.sh`, the token scan and the identity-values pass)
instead of trusting the worker's report.

## What enforces the rules between audits

All of it acts only in a project whose `CLAUDE.md` carries `superdoc:start`; an unmarked
`superdoc/` is someone else's hand-written docs and is never blocked.

- **Native git hooks** (`pre-commit`, `pre-merge-commit`, `pre-push`), installed at session
  start into the repo's common hooks folder. They run `lint.sh` and refuse a commit, merge
  commit or push that adds a leak (absolute home path, email, private IP). This covers
  terminal commits and pushes too. A leak added in one commit and removed in a later one
  still blocks the push, because the push check reads each commit, not the net diff.
- **Bash guard** (`hooks/superdoc-guard.sh`): the same check on an agent's `git commit`,
  `git push` and `git merge`, for what the native hooks miss: `--no-verify`, projects where
  they could not be installed, and fast-forward merges (git runs no hook for those). Best
  effort: it reads shell text, so an unusual command can slip past it.
- **Stop check** (`gate.sh`): after a merge, the doc files it touched are linted once and the
  findings shown to you. Warnings are yours to fix or leave; errors mean a leak got past the
  commit hooks: repair it now and do not push.
- **Audit reminder** at session start when the last recorded audit is over 50 commits old.

What this cannot cover: `git commit --no-verify` outside Claude (a terminal), a clone that has
never had a session (no hooks installed yet), a project where the hooks could not be installed
(`core.hooksPath` set, or a foreign hook of the same name) when a human pushes from a terminal,
and edits made in a web editor. Warnings and staleness are not blocked at all: the audit is the
cover for them.

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
