# Changelog

Newest first. One line per change, commit id at the end.

Versioning: every push that changes what users get bumps `.claude-plugin/plugin.json` and adds an entry here.

## 2.10.2 — 2026-11-11

The permission allow rules are offered before an unattended run, not only after a refusal, and as a command the user runs (#22).

- Proactive offer: in the reply to the plan's second Go (before the fresh-context offer) and whenever the user signals a long unattended run, the lead offers the allow rules the planned flow needs (`git merge`, `git push`, `gh pr merge`, `worker-cleanup.sh`; local merge flow vs PR flow) once, so an overnight run does not stall on a prompt nobody answers. The rule set gains `Bash(git push *)`.
- The offer is one `!`-prefixed `jq` one-liner the user types. It creates `.claude/settings.json` if missing, otherwise keeps every other key and appends only the rules not already in `permissions.allow`. Needs `jq`.
- Fix: the reactive step 3 told the lead to write `.claude/settings.json` after a yes, which the auto-mode classifier refuses as self-modification. The lead now gives the same one-liner (only the lines the refusal needs) and never writes settings. "yes, merge" in the next message still works.
- Hedged on purpose: whether settings changes apply mid-session is unverified, so the text says that if the rules do not take effect right away, the user restarts the session (the fresh-context `/clear` does it).
- `docs/permissions.md` carries the one-liner and the updated rule table.

## 2.10.1 — 2026-11-10

A board row dispatched to a project-level custom agent (a type that does not start with `tl-`) is now tracked like any worker (#21).

- Before: `record.sh` and `worktree-fence.sh` returned early for every agent type other than `tl-*`, so a background dispatch of e.g. `.claude/agents/my-worker.md` with `board: N` left the row `queued`, wrote no dispatch/start event, never became `returned` (the Stop gate never prompted the lead) and `board.py status` said 0 workers working. Now the `board: N` line is the opt-in: a dispatch whose brief carries it is linked (`running`), logged (dispatch, start, return), given the stale-base note, held/gated and fenced exactly like a `tl-*` worker, whatever its type (plain or `plugin:name`). `tl-*` workers behave as before, with or without the line; a non-`tl-*` dispatch without the line (Explore, general-purpose, claude-code-guide, web-fetch) is untouched: no log, no fence, no note.
- How: SubagentStart/SubagentStop and the file-tool hooks see no brief, so PreToolUse(Agent) leaves a short-lived `.state/tracked-pending` entry (type + time, 120 s) for a board-line dispatch, SubagentStart claims it, and PostToolUse pairs the exact agent id with the brief (whichever of the two fires first). The ids live in `.state/tracked-workers` (capped); one helper, `tl_worker_tracked` in `hooks/lib.sh`, replaces the four `case "$at" in tl-*|*:tl-*` filters in `record.sh` and the one in `worktree-fence.sh`. The second-Go plan-row refusal (GH#18) applies to any agent type naming a plan row. Known limit: two parallel dispatches of the same non-`tl-*` type, one with and one without a board line, can swap tracking until PostToolUse pairs the ids.
- test: custom and namespaced custom type end to end (row running, dispatch and start logged, status counts 1, returned on stop), either order of PostToolUse and SubagentStart, no board line untouched, Explore/internal agents untouched, an expired pending entry ignored, the fence on a tracked and an untracked id, the plan-row refusal. The old "non-tl-* does nothing on PostToolUse" test now uses a brief without a board line.

## 2.10.0 — 2026-11-10

Agents can suppress a leak finding that is a false positive (a version number read as an IP, a public handle), and the test suite can no longer touch a real project's board.

- superdoc leak allow list: `<doc root>/meta/leak-allow.txt`, committed with the docs (so every entry is public). One value per line with a mandatory reason (`10.4.2.1  # version string of libfoo, not an IP`); blank lines and full-line `#` comments are ignored. `lint.sh` suppresses a finding only when the exact value its detector flagged equals an entry, case-sensitive: the email address, the IP or `IP/N`, the home-folder or username name, the host-path name. `Ritze` silences `/home/Ritze/x` and never `Ritze03`, `xRitze` or `Ritze.bak` (no substring, prefix or pattern match; whole-token matching is the "surrounded by spaces" rule, and also covers `/home/Ritze/`). An entry without a `# reason` is not honoured and lint warns (`leak-allow entry has no # reason (not honoured)`, the value is never printed). The working-tree file is read in every mode (whole tree, `--files`, `--staged`, `--range`, `--push`, hence the commit hooks, the Bash guard and the Stop check); a missing file allows nothing extra. The allow file's own reasoned values are not findings.
- The lint error output now ends with a one-line how-to (add the exact value with a reason to `<doc>/meta/leak-allow.txt`, never a real personal value), and the host-path / public-IP hint mentions it. The superdoc SKILL.md ("Suppressing a false positive"), the playbook audit bullet and `docs/enforcement.md` carry the rule: a real email, private username, private IP or host is removed from the doc, never allow-listed; when unsure, report to the lead, who asks the user.
- test: exact IP, `Ritze` vs `Ritze03` / `xRitze` / `Ritze.bak`, exact email vs another address at the same domain, exact host-path name, no reason / empty reason not honoured plus warning, missing file, no value printed, and the same file honoured by `--files`, `--staged` and `--range`.
- test.sh can no longer write a real project's board or events.log. It picks its temp root outside any git work tree (falling back to `$HOME/tmp`, or refusing to run), and clears inherited CLAUDE_PROJECT_DIR / CLAUDE_AGENT_ID / TL_HOOK. A regression test replays the 2026-11-09 worker-worktree TMPDIR leak. (0eecedc)

## 2.9.1 — 2026-11-09

A fresh superdoc install no longer starts with an orphan hub (#20).

- superdoc: the Part 5 `CLAUDE.md` block in the playbook listed the reference docs as code spans (`` `superdoc/architecture/overview.md` ``), which `map.py` blanks, so `map.py --check` reported `ORPHAN    superdoc/architecture/overview.md  (no inbound links)` right after a greenfield install. The block now writes the hub, the capability folder, `STYLING-GUIDE.md` and `README.md` as real markdown links (the `@` force-load lines are unchanged). The marker stays `v4`: only the template text changed, no installed file needs a migration step. Projects installed earlier keep their code-span lines until the block is next replaced (any `/superdoc` re-wire) or edited by hand.
- test: a fixture whose `CLAUDE.md` is the Part 5 block, extracted from the playbook, runs `map.py --check` with no orphan and exit 0.

## 2.9.0 — 2026-11-08

A script maps the superdoc link graph, so a rename, move or delete starts from a list instead of a grep, and dangling links and orphan pages are caught mechanically (#19).

- `skills/teamlead-superdoc/map.py` (Python 3, stdlib only), exposed as `/teamlead superdoc map`: reads the doc tree plus `CLAUDE.md` and prints the structure per folder (each page with its links out and in), then one finding per line: `DANGLING  path:line -> target#anchor  (file missing|anchor missing)` (anchors matched against the target's headings with GitHub-style slugs, duplicate headings `-1`, `-2`, and explicit `<a name>` / `id=` anchors), `ORPHAN    path  (no inbound links)`, and a last `OK|FAIL  N pages, M links, D dangling, O orphan` line. Links in code fences and code spans and `http(s)`/`mailto` links are ignored. A `README.md` index link, a `CLAUDE.md` link or an `@<doc>/page.md` force-load line counts as inbound; `CLAUDE.md` and the doc-root or repo-root `README.md` are never orphans.
- Flags: `--check` (findings and summary only: what hooks and agents run), `--links-to PAGE` and `--links-from PAGE` (`path:line -> target`, for the list a rename starts from), `--doc DIR`. Exit 1 only on a dangling link (orphans are warnings), exit 2 on a usage error, exit 0 with a one-line note when the project has no superdoc. The doc root comes from `lint.sh --print-doc-root` (one copy of that logic); works from any subdirectory or linked worktree.
- The rule: after any edit under the doc root or to `CLAUDE.md`, run `map.py --check` and fix every `DANGLING` before handing back or committing. In the superdoc SKILL.md (new "link graph" section, and the Stop-check list), the playbook (audit bullet and checklist item) and the worker-brief self-check in `skills/teamlead/SKILL.md`; the lead can open the map first to navigate instead of reading the hub page and grepping.
- Stop gate (`gate.sh` check 8, no new hook): when a doc `.md` or `CLAUDE.md` is among the files a merge changed, `map.py --check` runs too (same `timeout 4`, same once-only state) and the `DANGLING` lines that start in or point at a changed file are shown, capped at 40. A page deleted or renamed by the merge therefore shows the links in untouched files that now dangle; old debt elsewhere is not re-reported.
- test: fixture tree (valid link, missing file, missing anchor, duplicate-heading slug, punctuation slug, explicit anchor, code fence and span, external URL, orphan, README and `@`-ref inbound, encoded spaces), `--links-to` / `--links-from`, exit codes, subdirectory and linked worktree, and the gate showing dangling links once, for a deleted page, and capped.

## 2.8.0 — 2026-11-08

A kept worktree stays kept, the lead may do small read-only checks itself, and the second Go's fresh-context offer is enforced (#16, #17, #18).

- A hold survives new commits and edits (#16): `board.py hold` used to lapse as soon as the worktree got a commit or edit, so a deliberately kept build that a worker extends between tests was flagged again after each commit and the lead had to re-hold it. Now a hold ends only when the row is re-dispatched or merged (state or worker changes, as before) or the worktree is removed. `hold --until-change` opts back into the old behaviour (stored as `until_change` on the hold). When a default-held worktree has new work since the hold, the Stop gate shows one line once per hold (a `systemMessage`, or appended to the block when the turn is blocked for another reason; never a block by itself) and records it with the new `board.py held-noted <row>` (hook-callable, like `worker-start`). `board.py status` and `held` show `new work since the hold`, `until-change`, and `changed` / `note_due`. The gate's left-behind-work message and the SKILL.md, README and `docs/enforcement.md` text describe the new lapse rules.
- Small read-only checks inline (#17): `skills/teamlead/SKILL.md` lets the lead do a small read-only check itself (about 3-5 tool calls, relying on context it already holds, such as verifying a worker's result). Writes, builds, heavy commands and wide reads still go to a worker; the red flag is reworded to cover only delegated read-only work.
- The second Go's fresh-context offer is enforced (#18): after a Go at stage 4, `mode.sh` sets `.state/plan-offer-pending`. `record.sh` refuses `tl-*` dispatches whose `board: N` row has a plan step, and `board-fence.sh` refuses `board_add` of `plan:` rows, until the user's prompt is exactly `here` or `/teamlead plan continue`. The deny reason carries the exact offer text for the fresh-context choice.
- test: hold tests cover the default (a hold survives a commit and an edit, one note once, with and without another finding), the `--until-change` lapse, and release on merge and re-dispatch.

## 2.7.0 — 2026-11-07

superdoc stops relying on the agent to remember the rules between audits: a script decides what a script can decide, and a leak is blocked before it is committed or pushed (#14, #15). Staleness a script cannot judge stays with the periodic audit.

- `skills/teamlead-superdoc/lint.sh` (#14, #15): one script for what can be decided reliably, over the doc tree plus `CLAUDE.md`, text files only. Errors: an absolute home path (Linux, macOS, Windows, WSL), an email address, a private IP (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10). Warnings: a public IP, a host path, a line-number reference (`file.ext:123`), a dangling `@`-ref, a force-loaded file over 8 KB or a force-load total over 20 KB, a glossary entry over ~300 characters, a page missing from its folder's `README.md`. Exit 1 only when there is an error. Modes: whole tree, `--files`, `--staged`, `--range A..B`, `--push`, `--force-load`. `--staged`, `--range` and `--push` read only lines that were added, and `--range` and `--push` check each commit, so a leak added and removed in a later commit still counts.
- lint allowlist and `superdoc-lint: allow`: one block at the top of the script lists what is never a finding (placeholder names such as `user` and `<name>`, `example.*` and other placeholder email domains, `noreply` addresses, `git@host:` remotes, loopback, documentation ranges, textbook and public-resolver IPs, `10.0.1.0/24`-style network blocks, `/opt/homebrew`, file extensions that look like a TLD). A line containing `superdoc-lint: allow` is skipped, for a true false positive only (an example that is not a real value), never for a real value; the output says so.
- lint output never repeats a value: only `path:line: error|warn: <kind>`, in every mode, so reports and hook messages cannot leak what they flag.
- Step 1 and Part 9 of superdoc call `lint.sh` (the `--force-load` mode and the whole-tree audit) instead of carrying their own shell: one copy of the logic. A project with no doc root or no superdoc marker gets silence and exit 0, so the hooks can call it in every repo.
- Merge-time Stop check in `gate.sh` (#14): after a merge, the doc files it touched are linted once and the findings shown to the lead (state in `.state/superdoc-lint-head`; the first run, rewritten history and a merge with no doc change print nothing). Warnings come from a pre-filtered `lint.sh --files` call, errors from `lint.sh --range last..HEAD`, so an error means a line this merge added and old debt on a neighbouring line is not re-reported. Each call runs under `timeout 4` (a timeout leaves the state and retries at the next Stop), output is capped at 40 lines, wired projects only.
- Leak blocking (#15), layer one: native `pre-commit`, `pre-merge-commit` and `pre-push` stubs, installed at SessionStart in projects whose `CLAUDE.md` carries `superdoc:start`. They run `lint.sh` and refuse a commit, merge commit or push that adds a leak, in a terminal too. A stub is never written over a hook that is not ours, and nothing is installed when `core.hooksPath` is set; the lead is told in one line when either happens. Installation needs teamlead active in the project; stubs already there keep working after teamlead stops.
- Leak blocking (#15), layer two: `hooks/superdoc-guard.sh` (PreToolUse, Bash), a best-effort check on an agent's `git commit`, `git push` and `git merge`, for what the stubs miss: `--no-verify`, fast-forward merges (git runs no hook for those) and projects without stubs. It reads shell text, so an unusual command can slip past; it exits at once unless the command mentions git and commit, push or merge, and needs no active teamlead.
- What cannot be enforced (SKILL.md, "What enforces the rules between audits"): `git commit --no-verify` from a terminal, a clone that has never had a session, a project where the stubs could not be installed when a human pushes from a terminal, and edits in a web editor. Warnings and staleness are not blocked at all; the audit covers them.
- SessionStart audit reminder (#14): when the last recorded audit is more than 50 non-merge commits old, the session start says so and tells the lead to run the audit itself, not to ask the user. State is the commit of the last audit in `.claude/teamlead/.state/superdoc-audit`, written by the superdoc skill; no state or a commit that is no longer an ancestor starts counting silently. Needs teamlead active.
- superdoc tiers: `tl-sonnet-medium` writes and fixes, `tl-sonnet-high` does QC (it reads the diff against the code and re-runs `lint.sh`); there is no Opus QC. Opus is used only after a Sonnet failure, as a retry with the ceiling `tl-opus-medium`.
- Stale worker worktrees: Claude Code's default `worktree.baseRef: "fresh"` branches a worker's worktree from `origin/HEAD`, so commits the lead has not pushed were missing and workers started on old code. `record.sh` now hands the worker the lead's commit at SubagentStart (with the fast-forward command) whenever the lead's checkout is ahead of `origin/HEAD`; a worker that already has its own commits skips it. Confirmed working in a live run. Setting `{"worktree":{"baseRef":"head"}}` in `.claude/settings.local.json` is an optional alternative that makes Claude Code branch from the lead's HEAD itself; documented in the README.
- test: the QC3 stop/forget race test asserted a lock order it never controlled (both racers started at once, the winner decided by interpreter start-up jitter), so it failed now and then. The racers now signal when they hold the board lock and the second starts only after that, and the unordered race asserts only the invariant. `board.py` was correct; only the test changed.

## 2.6.1 — 2026-11-07

The health check repairs what it finds since 2.6.0, so a wrong check now causes wrong edits. These fixes land before the first push of the v4 contract (v4 is unreleased, so the contract stays v4 and the v3 → v4 re-install of `documentation.md` delivers the new lines).

- superdoc Step 1 / Part 9, false dangling `@`-ref (#11): a `` `@superdoc/...` `` inside backticks (prose, not a force-load) was reported as a missing force-loaded file. The `@`-ref pattern is now one variable (`REF`) used by both the dangling-ref loop and the force-load size loop, and a match cannot follow a backtick; a real ref at line start, after a space or in parentheses is still found. Still uses `$DOC`, still safe with no `CLAUDE.md`.
- superdoc Part 9, multi-line glossary entries (#12): the entry-length check read one line at a time, so a hard-wrapped entry was judged by its first line and the worst entry in a real file (3,114 characters) was missed. It now sums each entry's lines up to the next entry or heading and reports the start line with the summed length (the last entry of the file is flushed too). The command is still one line in the playbook; `test.sh` runs that exact text against wrapped, short, heading-terminated and end-of-file fixtures.
- superdoc force-load budget, glossary judged by entry length (#13): `meta/TERMINOLOGY.md` is exempt from the 8 KB per-file flag (a project can always satisfy "entries under ~300 characters", not a file size); entries over ~300 characters are the flag, with a count and the first ten listed in the Step 1 output. The verbatim installs (`documentation.md`, `documentation-version-policy.md`) are listed in the size report, marked as such, but left out of the 20 KB total. A total over budget with every glossary entry short is a `note:`, not a `⚠`; Part 9 says what to do about it: agents ask themselves, not the user, whether every term has to be known on every task, and move terms only one feature uses to that feature's page (a repair they make themselves, Part 10). A term is never deleted to meet a number, and the glossary is never split into a core and a linked list, because the "ask before acting on an undefined term" rule needs the force-loaded list to be complete. A healthy tree now counts around 10 KB (was "around 15 KB", which included the verbatim installs). Step 3 and Part 8 say the same.
- `assets/documentation.md` (#14, the cheap part): two lines in "Update after you change": reference code by symbol (`file:symbol`), not line number, and, folded into the existing rename bullet rather than a new line, grep the docs for the old name in the same commit when you rename, move or remove something. The lint script, `gate.sh` integration and session reminder from #14 are not part of this release.
- superdoc privacy (#15): local details have a home. Playbook Part 4a and the "Write docs anonymized" section of `documentation.md` name `.claude/local/` as the one untracked place for things like how to reach a test machine; real values go there, the page refers to them generically, secrets go nowhere in the repo. It is git-ignored by a `.gitignore` line (committed, so every clone is covered; skipped when `git check-ignore -q .claude/local/x` already says it is ignored). The directory is per checkout, so the repair row's `owns` carries the main checkout's absolute `.claude/local/` path (the worker fence's existing absolute-`owns` grant) and reports never carry the values.
- superdoc repair no longer loses useful local detail (#15): Part 10's privacy bullet now moves a real value that future agents need to `.claude/local/` first, then puts the placeholder on the page (move-before-replace, like any trim); a secret is removed and never copied anywhere. The leak step adds to "in git history and whether it was pushed": whether the repo is public (`gh repo view --json visibility`, or the remote) and that any exposed credential must be rotated first, because a history rewrite does not undo exposure. Rewriting history and force-pushing stay the user's call (Part 10 and SKILL.md Step 4).
- superdoc Step 4 (#15): a privacy-repair worker's brief carries the rule text itself, not a pointer to Part 4a (a worker once admitted it had not read it), and the QC after repair re-runs the Part 9 privacy scans (path/email/IP/token regex and identity values) on the result instead of trusting the worker's report.

## 2.6.0 — 2026-11-07

- superdoc (contract v3 → v4): docs are written anonymized, like a filed bug report, and the rule now reaches everyday doc edits. A superdoc file named a real hostname because the privacy rule lived only in the skill and playbook, which agents see during a `/superdoc` run; the file every agent has force-loaded, `assets/documentation.md`, had none. It now carries a short "Write docs anonymized" section (no hostnames or machine names, no client/server names of the user's own machines or network, usernames, real names, emails, IPs, MAC addresses or serials, absolute host paths, private project names, secrets; placeholders such as `<client>`, `<server>`, `<host>`, `$HOME`; applies when copying from logs, command output or chat; "client"/"server" as software concepts are fine). Playbook Part 4a, the SKILL.md brief line and the Part 8 box name the same terms.
- superdoc AUDIT privacy scan: keeps the path/email/IP/token regex and adds a second pass that greps the doc tree and the `CLAUDE.md` docs block for the real identity values of the machine running the audit (`hostname`, `$USER`, `git config user.name`, `git config user.email`; case-insensitive, fixed strings, empty values skipped, output is `file:line` only so it never repeats the leak), plus a judgement pass for names that look like machines or hosts (example output, log excerpts, `ssh`/`scp` lines, mount paths, `user@host` prompts). Findings are reported without quoting the value.
- superdoc upgrade v3 → v4 (automatic, Step 1b): re-installs `claude-instructions/documentation.md` verbatim from the assets; nothing else in the project changes.
- superdoc is for agents, not the user: `documentation.md`, SKILL.md and the playbook intro say the docs are written for and owned by agents; they clean up, restructure, trim, split, move and delete on their own judgement and never ask the user what is right for the docs. Only three things go to the user: rewriting git history over an already committed leak, hand-written `superdoc/` with no marker, and facts only the user knows (what a project term means, why a design was chosen).
- superdoc HEALTH-CHECK is now audit-then-fix: the audit phase stays read-only, then the lead dispatches the repairs in the same run, with no offer and no question (force-load bloat, oversized TERMINOLOGY entries, stale claims, broken links and `@`-refs, missing pages, privacy leaks, oversized or multi-topic pages), and tells the user in a short summary what was fixed, privacy leaks first. Step 4 is no longer "only on explicit ask" (a report-only audit only when the user literally asks for one); Part 10's named items are the audit's findings. A leaked value is replaced with a placeholder automatically; the file's git history is not touched: the lead says when the value was already committed and whether it was pushed. Move-before-trim is unchanged.
- superdoc questions turned into decisions: Step 2 picks GROUND-SETUP or full FRESH from the repo itself (borderline: GROUND-SETUP), page tier when unsure is Opus, the version-policy variant is picked from the project's history and defaults to `manual` (said in the report), a scaffolding-only `superdoc/` is collapsed back into `CLAUDE.md` by the repair phase instead of proposed.
- superdoc one page per capability: every feature, backend or subsystem gets its own page (Part 2 rule, Part 3 skeleton, `documentation.md` update list), so pages stay small and agents read only the one they need. The AUDIT lists pages over about 12 KB (`find ... -size +12288c`) and pages mixing several capabilities (judgement; a big page on one genuinely single topic may stay); Part 8 gets the matching box; REPAIR splits them verbatim, fixes every link and `@`-ref, updates the README index and the overview's module map, and confirms nothing was lost before cutting the original. A TERMINOLOGY entry whose detail has no page yet gets its own new page.

## 2.5.0 — 2026-11-07

- superdoc: contract upgrades apply automatically. Any `/superdoc` run on an existing install whose `<!-- superdoc:start vN -->` marker is older than the playbook's version (line 3) now upgrades first, with no offer and no question; before, the skill only offered the upgrade and waited, so projects stayed stale ("It won't be applied unless you ask"). The newest contract is assumed to be the best available.
- New SKILL.md Step 1b between detection and the health check: the lead compares the installed marker with playbook line 3, dispatches one writing worker in a worktree like any other doc write, which applies each version's step in order (v2 → v3, then later ones as they are added) and re-stamps the marker; the lead then tells the user in one line what was upgraded (never silent). The health check runs afterwards on the upgraded tree, so its findings reflect the new version. Marker equal or newer: nothing to do.
- Unchanged: an upgrade applies only what changed in those versions (no rebuild from skeletons, entries are not rewritten). The audit stays report-only ("Do not write to any file in this mode" still holds; the upgrade is a separate step before it), and Step 4's "never auto-fix" now says it covers audit findings, not upgrades. Cleanup of oversized force-loaded content stays a REPAIR the user asks for. `superdoc/` without a marker is still treated as hand-written docs (confirm before regenerating). An older marker at audit time now means the upgrade failed and is still reported. The contract itself stays v3.
- SKILL.md Step 1 snippet prints `superdoc marker: vN` (or `none`, also with no `CLAUDE.md`) so the lead can compare versions. Playbook Part 6 and Part 9 reworded to match.

## 2.4.0 — 2026-11-07

- superdoc (contract v2 → v3): `meta/TERMINOLOGY.md` entries are pointers, not documentation. The skeleton's standing text now says an entry is what the term is plus where to read more (one or two sentences, ~200 characters); details live on the linked page, and amending trims instead of appending. The file is force-loaded (in context all session, resent with every request, copied into every worker), and a real project had grown to 51 KB with single entries up to 3 KB.
- superdoc gate and AUDIT: new Part 8 checkbox and a Part 9 awk command that lists entries over ~300 characters (line + length) and flags a file missing the rule. REPAIR: trimming an entry moves the detail to the linked page first and confirms the page holds it; nothing that exists only in the entry is deleted.
- superdoc force-load budget: the HEALTH-CHECK now covers every force-loaded file (`CLAUDE.md` plus each `@`-ref target), not only TERMINOLOGY. SKILL.md Step 1 prints each file's size and the total and warns on a file over 8 KB or a total over 20 KB (correct with a dangling ref or no `CLAUDE.md`); Part 9 adds the same check plus a judgement pass for content not needed on every task, naming the page it should move to. The verbatim `claude-instructions/` installs count toward the total but are never flagged for trimming. Part 8 gains the matching box, and Part 10's move-before-trim rule covers any force-loaded file. Cleanup is offered to the user and runs as REPAIR on the named items, never automatically.
- superdoc wording: `@` files load once at session start (and after `/clear` or compaction), stay in context and go out with every request, and every worker that loads `CLAUDE.md` carries its own copy. Replaces the loose "pasted into every turn" claims in the playbook and SKILL.md.
- superdoc upgrade (marker v2 → v3, offered in HEALTH-CHECK): adds the rule text to an existing `TERMINOLOGY.md` and reports oversized entries; it does not rewrite entries unasked.

## 2.3.1 — 2026-11-03

- workers: scratch files, test output, logs and temp builds go in `.tl-scratch/` inside the worker's own worktree, never in the session scratchpad under `/tmp` and never through a symlink out of the worktree (all six `agents/tl-*.md`, explicitly overriding Claude Code's generic "use the scratchpad" instruction; `TMPDIR` goes to `.tl-scratch/tmp`). A worker touching the lead's scratchpad is outside its allowed directories, so every access prompted the user and blocked the background worker. `/tmp` is RAM, too.
- record.sh (SubagentStart): appends `.tl-scratch/` once to `<git common dir>/info/exclude`, which covers the main checkout and every linked worktree; idempotent, silent on failure (`tl_ensure_scratch_exclude` in `lib.sh`).
- teamlead skill: the lead never points a worker at files in its own scratchpad; shared tooling is copied into the project (committed, or untracked and git-excluded) or built by the worker in `.tl-scratch/`, and the brief says outputs go to `.tl-scratch/`.
- docs: `docs/permissions.md` and the README troubleshooting explain the symlink/scratchpad prompt. The worktree fence's session-scratchpad write exception is unchanged (file tools only; the prompts came from Bash and Read, which the fence cannot see).

## 2.3.0 — 2026-11-01

- worktree-fence: a write that matches an absolute (or `~`) entry of the worker's own row's `owns` outside its worktree now also answers Claude Code's permission prompt with a `permissionDecision: "allow"` ("teamlead: path is in board row N's owns"), which a background worker could never answer itself. Per the hooks docs deny/ask rules still apply. In-worktree, scratchpad and project-root passes stay silent, and a relative `owns` entry never opens the main checkout.
- workers + teamlead: scope requests. A `tl-*` worker that needs a path its `owns` doesn't cover sends the lead a `SCOPE REQUEST: <path>` / `why:` / `row:` block (`SendMessage` to `main`, or the top of its hand-back when blocked) instead of working around it. The lead checks it, reads the docs, checks overlap, `board_update`s `owns` and replies `granted`/`denied`; outside the project it asks the user first, and it tells the user before dispatching a row that owns outside paths. The fence's refusal message and the agents' boundary line now point at that flow instead of "stop and report". `record.sh` flags a `SCOPE REQUEST` hand-back to the lead through the same one-shot note as the 🐞 marker.

## 2.2.4 — 2026-11-01

- plan: the "/clear, then /teamlead plan continue" offer is printed only in the reply to the second Go, once the header is Stage 5 — never at the end of stage 4 while asking for the Go (a /clear there lost the unrecorded Go and `plan continue` refused). The Stop gate blocks the offer at stage 4; `plan continue` at stage 4 without a Go says "No Go recorded ... say Go to start building".
- plan + teamlead: reading the project docs is now a requirement, not a hint. Plan stage 3 scouting covers the docs for the areas the plan touches; the stage-4 context audit has the lead read the relevant pages before writing `## Done when` and the wave table. The teamlead reads the relevant doc pages itself before any dispatch whose worker will touch something, names them in the brief and passes on the constraints (a scout covers the docs only when the lead can't tell which matter, and the writing dispatch waits for it). The help text says the `/clear` offer comes after the Go.

## 2.2.3 — 2026-11-01

- plan: the after-`/clear` doc re-read covers `superdoc/`, `docs/` and the folder CLAUDE.md's `superdoc:start` block points at; the lead's pre-dispatch doc check names that folder too.

## 2.2.2 — 2026-11-01

- superdoc: the Step 1 detection snippet takes a `DOC=` variable instead of hard-coding `superdoc/`, so a user-chosen doc folder is detected correctly.
- brainstorm: saves to `<doc root>/brainstorm/` (default `superdoc/`, or the folder the CLAUDE.md `superdoc:start` block `@`-refs) instead of always `superdoc/brainstorm/`.

## 2.2.1 — 2026-11-01

- superdoc: the doc folder defaults to `superdoc/`, but an explicit plain-text user request for another folder wins and is passed to every worker brief; removed the contradictory "always, no alternative" and "docs/ only" wording.
- superdoc: new privacy rule (playbook Part 4a). Pages are committed and often public, so repo-relative paths only and no usernames, emails, hostnames, absolute host paths, secrets or local setup; the verify gate and audit mode grep for leaks.

## 2.2.0 — 2026-11-01

- Stop gate never tells the lead to remove the main checkout (GH#10). #76905a7
- Stage-6 gate checks the plan's current phase and scope, not just "board all merged" (GH#6). #0f2b6a3
- The phase cycle 5→6→7→5 is stated in the skill and help; the gate, `next:` and the statusline name the current phase (GH#8). `board.py` check_plan is phase-aware via a shared `plan_progress()`. #d1dcdd6 #4daf958
- `board.py hold/release/held` marks a deliberately kept worktree; the gate names the row and prints a runnable hold command. Holds lapse on any state or worktree change (GH#4, GH#9). Check 3 ignores hand-made worktrees with no row; check 7 suggests `blocked` plus a note. #66b8c5f #1f96ce2
- Worker fence: Edit/Write/MultiEdit/NotebookEdit honour absolute paths in the row's `owns`; Bash writes are deliberately not fenced, now stated (GH#7). #7babf8a
- superdoc: workers fetch assets with Read/Write from a literal plugin root given in the brief, avoiding Claude Code's worktree guard on paths containing "Git" (GH#5). #db74482
- Auto mode: merge/cleanup guidance, a general rule "permission refusal: stop, tell the user, offer the allow rule", and a new `docs/permissions.md` (GH#3). #602cec8
- `board.py` CLI refuses a blank or valueless `--project` (it used to write to the real board) and refuses writes from agent worktrees; hooks pass `TL_HOOK=1`. #1bd140e

## 2.1.0 — 2026-10-28

First version bump since 2.0.0. Claude Code caches installs by version, so earlier changes may not have reached you; update the plugin (`claude plugin update teamlead@teamlead`, then restart) to get everything below. The session-start line now reads `[teamlead v2.1.0] Active for this project. ...`.

- Board fence: only `plan:` rows wait for plan stage 5; scouts, read-only rows and unrelated `owns:` work are allowed before it (GH#1). #e591db8 #c143868
- superdoc playbook: no hardcoded machine paths (GH#2). #13e7595
- Plugin bugs a worker finds are offered to you as an anonymized GitHub issue (nothing is sent as Claude Code feedback); workers flag them with a `🐞 PLUGIN BUG` line, relayed to you in a single-cell table, and `record.sh` reminds the lead. #4f3cd64 #6446610 #0c16538
- Planning: a `## Handoff` section in the plan, and the lead recommends `/clear` between phases; `restore.sh` points at the handoff after clear, compact or resume. #e42ae65
- Planning: the first Go audits context against the plan file; 6 to 7 happens on its own when there is nothing to test, 7 to 5 is explicit, phases by default; the watcher keeps running through stage 7; the plan file always ends with one empty line. #1e9b664 #ea2b4a6 #9561129 #e043aac
- Every dispatch, scouts and QC included, gets a board row first; relevant `docs/` and `superdoc/` pages go into every worker brief. #85460c0 #73af0c8
- Statusline prints a cached segment and refreshes in a detached single-flight child, so it no longer gets cancelled on slow disks. #d20afcf

- `worker-cleanup.sh` lifts a stale Claude Code agent lock (`claude agent agent-<id> (pid P start S)`: pid dead or reused, or the ledger no longer lists the agent as working) before removing the worktree; a live agent's lock or any foreign lock still refuses.
- When a `tl-*` worker really returns, `record.sh` stops the background Bash tasks it launched and left open (found via the task's `.output` file; ones the worker finished, TaskStop'd or named in its report are kept) and logs a `reap` event; a `pause` event now lists the worker's `open=` task ids. Covers read-only workers with no worktree; Monitors are not covered.
- Finished workers leave nothing behind: workers stop their own monitors/background shells before returning, and the lead closes each one out with `worker-cleanup.sh` (kills leftovers in its worktree, removes worktree and branch), including rows stuck `running` on a paused worker.
- Planning: a `## Research request` section (`Initial research [y/n]: `) above the brainstorm one — an opt-in pass where one worker searches the web for libraries, API gotchas, pitfalls and prior art; findings land in `## Context` with sources.
- Plans are never archived automatically; the agent says it is done and runs `plan-archive.sh` only on request.
- Gentle nudge for agents, planning scouts and the lead to use quick web searches when something is complicated or unfamiliar; never required.

## 2026-09-22

- Hardened board.py against races: render outside the lock, stop `remove`'s cascade from escaping a refusal, fix find-then-mutate in worker-stop/worker-start/forget. #10337fd
- Added worker lifecycle to board.py (`worker-start` / `worker-stop`); `forget` now requeues orphaned rows. #f7bf838
- Wired the worker lifecycle to hooks — PostToolUse(Agent), SubagentStart/Stop and SendMessage-resume. #3daafd2
- Regression test for crash-safety of atomic writes. #bb80be8

## 2026-09-21

- board.py now locks and writes atomically, tracks a worker field, and guards bad updates. #54abfb5
- Closed the remaining lock gap on the MCP `board_add` write path. #2f697ef
- Squash-merge detection, board file integrity check, and auto-unblock. #7bf4143
- Transitive `blocked_by`, blocker-unmerged gate, behind-main and leftover-worktree checks. #02ba0ce
- `remove` op, worker refusal on CLI writes, `forget` filters. #6b0a9cd
- Empty `blocked_by` is treated as vacuously satisfied instead of blocking forever. #bd63779
- plan-lint enforces stable open-question numbers. #e494fbf
- Session start renders the board before state and forgets stale workers. #34cbedc
- Ignore `__pycache__` and the whole `.claude/teamlead` dir; untracked a stale `.pyc`. #62437e0
- Docs: board id in dispatch briefs, rebase gate row, `remove` / `forget` / plan-stage gate. #800d085 #72a6a2d
- Test fixtures for all of the above. #1e511a0 #53b04cd

## 2026-09-20

- Plan-aware Stop hook, re-checking the plan stage at Stop so bypassed writes are caught. #2db8792 #594752b
- Plan header stage machine is enforced. #fa1527a
- Board checks that every plan-step id has a matching task. #c02e1ae
- Slash-only activation/deactivation; the Go is recorded. #fe1955a
- Plan watcher never double-starts. #3775737
- Statusline: per-stage plan emoji, case-insensitive header parse. #72a84a9
- plan-lint phase-B rules: Owns-prefix overlap, brainstorm request, blank-line and evidence checks. #eb76ed1
- `plan-archive --abandon` now forgets the board rows too. #2097032
- Docs: enforcement.md rebuilt, plan.md reconciled. #0bfc248

## 2026-09-19

- Opt-in statusline segment, then planning mode, colour, and a watch indicator. #09b453b #bb3ffc8 #8949d09
- Added the statusline installer. #f5dd1a2
- Plan flow reshaped: create-and-show before the scout, everything folds into Decisions, archive once done. #fcbb0ad #5167caa #5e48abb
- Plan mode runs through Agent-Testing and User-Testing. #f44e954
- Questions to the user always carry a recommendation. #8dadfa7
- Renamed `out` to `working`. #63f80e2
- superdoc verifies that @-refs resolve, and says why. #ee66232 #d815293
- Cancelled workers are closed out; start-line token parsing fixed. #19a9cf4

## 2026-09-16

- teamlead v2: plugin rewrite with a durable ledger. #a6674b5
- Board JSON is the truth, markdown is rendered, tools do the writing. #ff0f52e
- Only the lead writes to the board. #4292772
- Hardening: liveness-aware gate, git-verified merges, status, rotation. #9730220
- Abandoned dispatches age out instead of blocking the gate. #647e438
- board-lint validates the model-written half of the ledger. #27134e8
- A worktree resolves back to the main checkout. #5aa7cee
- The ledger tracks resumed workers. #3bd3f04
- Concise output for the user; briefs and worker returns stay dense. #3c312b2 #e289e5e
- Added `/teamlead help` and expanded the README. #eb7b0bb
