> Archived 2026-09-20 — superseded by ../enforcement.md. Kept as the design research it was.

# Workflow Enforcement Reference

What the Claude Code harness can *mechanically* enforce, and how to use it to build
teamlead-v2 as a suite rather than a prompt.

Researched 2026-08-30 against `code.claude.com/docs/en/{plugins,plugins-reference,hooks,skills}`
and verified against the plugins installed locally (`ponytail@4.7.0`, `claude-plugins-official`).

---

## 0. The thesis

teamlead-v1 is a 487-line `SKILL.md` that tries to enforce behaviour with prose:

> "**You never do the actual work yourself.**"
> "**The banner is not the end of activation, it's step 1 of 2.** Do not let 'nothing to
> dispatch yet' become an excuse to defer this…"

The git log is a record of that fight (`make the activation check mandatory, not
deferrable`). Prose is *persuasion*; the model complies most of the time. Hooks are
*mechanism*; the model cannot not-comply. Every rule currently defended by an escalating
paragraph is a candidate for deletion, replaced by a hook.

Rule of thumb: **prose for judgment, hooks for invariants.** If breaking the rule should be
impossible rather than discouraged, it belongs in a hook.

---

## 1. Where enforcement code can live

Five distinct places, in ascending order of scope:

| # | Location | Lifetime | Notes |
|---|---|---|---|
| 1 | `~/.claude/settings.json` `hooks` | Always on, every session | Global. Also the only place a main `statusLine` can be set. |
| 2 | `<project>/.claude/settings.json` | Every session in that repo | Project-scoped; `settings.local.json` for gitignored. |
| 3 | Plugin `hooks/hooks.json` | Whenever plugin is enabled | Distributable. `${CLAUDE_PLUGIN_ROOT}` available. |
| 4 | **`SKILL.md` frontmatter `hooks:`** | **Registered on skill invoke, kept for the rest of the session** | The key primitive for a mode. `once: true` removes after first success. |
| 5 | **Agent `.md` frontmatter `hooks:`** | **Only while that subagent runs**, removed on finish | `Stop` is auto-converted to `SubagentStop`. |

Same JSON/YAML shape in all five. All hook events are supported in 4 and 5.

Caveat on 5: frontmatter hooks in a *project* subagent only run after the workspace-trust
dialog is accepted for that folder.

### Non-hook injection: the skill body itself

`SKILL.md` bodies run shell before the content reaches the model:

```markdown
## Repo state
- Worktrees: !`git worktree list`
- Settings:  !`cat .claude/teamlead.md 2>/dev/null || echo missing`

```!
git rev-parse --is-inside-work-tree 2>/dev/null && echo "git: yes" || echo "git: no"
```
```

Inline `` !`cmd` `` is only recognised at line start or after whitespace. Fenced ```` ```! ````
for multi-line. Substitution runs **once** over the original file — output is not re-scanned.
Killable by `"disableSkillShellExecution": true` in settings (managed-settings lever).

This alone deletes teamlead-v1's entire "On activation — mandatory, runs before anything
else" section: the git/worktree/settings data is in context *before the model's first token*,
so there is nothing to defer.

---

## 2. Hook events, grouped by enforcement power

32 events. Grouped by what they let you *do*, not when they fire.

### 2a. Inject text into the model's context

Via JSON `additionalContext`, or plain stdout on the ⚡ events.

| Event | ⚡ | Enforcement use |
|---|---|---|
| `SessionStart` (matchers: `startup`,`resume`,`clear`,`compact`,`fork`) | ⚡ | Restore mode after `/clear` or a compaction. This is how PONYTAIL survives. |
| `UserPromptSubmit` | ⚡ | Per-turn re-assertion. The anti-drift lever for long sessions. |
| `UserPromptExpansion` (matcher = skill name) | ⚡ | Fires when a slash command expands. Pre-load state for exactly one command. |
| `PostModelSwitch` | ⚡ | Re-assert rules after a model change. |
| `PreToolUse` | | Warn/annotate before an action runs. |
| `PostToolUse`, `PostToolUseFailure` | | Feed results or errors back as context. |
| `PostToolBatch` | | After a whole parallel batch resolves. |
| `Stop`, `SubagentStop` | | Inject, then optionally refuse to stop. |

### 2b. Block

Exit 2 blocks. Message comes from JSON reason, else stderr.

| Event | What exit 2 does |
|---|---|
| `PreToolUse` | Blocks the tool call. |
| `UserPromptSubmit` | Rejects and **erases** the prompt. |
| `UserPromptExpansion` | Blocks the command expansion. |
| `Stop` | **Refuses to end the turn** — Claude keeps going. |
| `SubagentStop` | Refuses to let a worker finish. |
| `PostToolBatch` | Stops the agentic loop before the next model call. |
| `TaskCreated` | Rolls back task creation. |
| `TaskCompleted` | Refuses to mark a task done. |
| `PreModelSwitch` | Blocks the model switch. (Timeout also blocks.) |
| `ConfigChange` | Blocks a settings change (except `policy_settings`). |
| `WorktreeCreate` | Aborts worktree creation — *any* non-zero code, not just 2. |

`PermissionRequest` and `PermissionDenied` ignore exit 2 — use their JSON fields instead.

### 2c. Rewrite in flight

| Field | Events | Power |
|---|---|---|
| `updatedPrompt` | `UserPromptSubmit`, `UserPromptExpansion` | Rewrite what the user or the command actually said. |
| `updatedInput` | `PreToolUse` | Rewrite tool arguments. **Includes the `Agent` tool** — you can force `subagent_type`, `model`, or `isolation`. |
| `hookSpecificOutput.permissionDecision` | `PreToolUse` | `allow` / `deny` / `noDecision` + `permissionDecisionReason`. |
| `hookSpecificOutput.decision` | `PermissionRequest` | `allow` / `deny` / `noDecision`. |
| `hookSpecificOutput.retry: true` | `PermissionDenied` | Tell Claude to retry a denied call. |
| `hookSpecificOutput.continue: true` | `Stop`, `SubagentStop`, `PostToolBatch` | Keep going, JSON equivalent of exit 2. |
| `hookSpecificOutput.suppressOutput: true` | `Stop`, `SubagentStop` | Hide the message from the user. |

### 2d. Observe only (no block, no inject)

`SubagentStart`, `Notification`, `MessageDisplay`, `InstructionsLoaded`, `CwdChanged`,
`DirectoryAdded`, `FileChanged`, `WorktreeRemove`, `PreCompact`, `PostCompact`,
`Elicitation`, `ElicitationResult`, `StopFailure`, `SessionEnd`, `Setup`.

Still useful: logging, metrics, `terminalSequence` (works on *every* event, even ones that
discard all other output — bell, window title, progress).

`SessionEnd` shares a **1.5s budget** across all its hooks (raised to 60s if any hook sets a
longer timeout). Don't put real work there.

---

## 3. Hook types

Not everything has to be a shell script.

| Type | Config | Use |
|---|---|---|
| `command` | `command`, `args`, `shell`, `async`, `asyncRewake` | The default. |
| `http` | `url`, `headers`, `allowedEnvVars` | POST the event JSON to a service. |
| `mcp_tool` | `server`, `tool`, `input` (with `${tool_input.x}` substitution) | Route a hook through an MCP server. |
| `prompt` | `prompt` (`$ARGUMENTS` = hook input JSON), `model` | **Single-turn LLM eval.** A hook that *judges* instead of greps. |
| `agent` | same | **Subagent verifier** with tool access (experimental). |

Common fields on all types: `if` (permission-rule syntax, e.g. `"Bash(git *)"` — finer than
`matcher`), `timeout`, `statusMessage`, `once` (frontmatter hooks only).

`async: true` runs in background and ignores the timeout. `asyncRewake: true` additionally
**wakes Claude** when the hook exits 2 — a background check that interrupts the session when
it finds something.

The `prompt` type matters here: "did this worker actually finish the task?" is not a grep.
A `SubagentStop` hook of type `prompt` can read `last_assistant_message` and block the worker
from reporting done if it hedged.

---

## 4. Hook I/O contract

Every hook receives JSON on stdin. Fields present on all events:

```json
{
  "session_id": "...", "prompt_id": "...", "transcript_path": "...", "cwd": "...",
  "permission_mode": "default|plan|acceptEdits|auto|dontAsk|bypassPermissions",
  "effort": { "level": "low|medium|high|xhigh|max" },
  "hook_event_name": "PreToolUse",
  "agent_id": "subagent-123",     // present for subagents only
  "agent_type": "tl-sonnet-high"  // subagent or --agent
}
```

**`agent_id` is the load-bearing field for teamlead.** It is how a hook distinguishes the
lead from a worker. (Verify with a logging hook before relying on it — see §9.)

Exit codes:
- **0** — stdout starting `{` and ending `}` is parsed as JSON output; otherwise it goes to the
  debug log, *except* on the ⚡ events where plain stdout is injected as context.
- **2** — blocking error on the events in §2b.
- **other** — non-blocking error; the transcript shows `<hook> hook error` with the first
  stderr line. Valid JSON is still honoured.
- JSON `permissionDecision: "allow"` **cannot** override an exit 2.

Variables available in hook commands: `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`
(persistent across plugin updates — `~/.claude/plugins/data/{id}/`), `${CLAUDE_PROJECT_DIR}`.
In skill bodies and `allowed-tools`, additionally `${CLAUDE_SKILL_DIR}`, `${CLAUDE_SESSION_ID}`,
`${CLAUDE_EFFORT}`.

---

## 5. Can hooks be added and removed dynamically?

Yes — but not through an API a running hook can call. There are six mechanisms, at three
different granularities. This matters because a *mode* (teamlead on/off) is exactly the
question "can this set of hooks come and go mid-session?"

### 5a. The six mechanisms

| # | Mechanism | Granularity | Add | Remove | Needs a restart? |
|---|---|---|---|---|---|
| 1 | **Settings file watcher** | Individual hook | ✅ | ✅ | No |
| 2 | **Skill frontmatter `hooks:`** | Hook set | ✅ on invoke | ❌ (except #3) | No |
| 3 | **`once: true`** | Individual hook | — | ✅ self, after first success | No |
| 4 | **Agent frontmatter `hooks:`** | Hook set | ✅ on spawn | ✅ automatic on finish | No |
| 5 | **`/plugin enable\|disable` + `/reload-plugins`** | Whole plugin | ✅ | ✅ | No, but costs cache |
| 6 | **`ConfigChange` hook, exit 2** | Veto | — | blocks a removal | No |

**1. The file watcher is the real "dynamic" primitive.**

> "Direct edits to hooks in settings files are normally picked up automatically by the file
> watcher."

So writing JSON into `~/.claude/settings.json`, `<project>/.claude/settings.json`, or
`settings.local.json` mid-session installs or removes a hook live. Claude itself can do this
with the `update-config` skill; so can one of your own hooks. Note the hedge in "normally" —
treat it as reliable but not contractual, and verify with `/hooks`.

`/hooks` is a **read-only** browser: it shows every event, matcher counts, and full handler
details, but you cannot add, edit, or remove from it. Editing the JSON is the only path.

**2. Skill frontmatter is add-only, and that's the whole point.**

> "Claude Code registers them when you or Claude invoke the skill and keeps running them for
> the rest of the session, on turns after the skill's own turn as well."

Invoking `/teamlead` *is* a dynamic hook installation. There is no matching uninstall.

**3. `once: true` is the only self-removal.**

> "Setting `once: true` causes Claude Code to remove the hook after its first successful run.
> A run that fails, blocks with exit code 2, or times out leaves the hook in place."

The failure semantics are useful in themselves: a `once` hook that exits 2 stays armed and
keeps blocking until it succeeds. That's a one-shot gate with automatic retry, e.g. "the first
`Stop` after activation must find a settings file, or the turn doesn't end."

**4. Agent frontmatter is the only true add-and-remove.**

> "Claude Code runs them only while that subagent is running and removes them when it
> finishes. Claude Code converts a `Stop` hook here to `SubagentStop`."

Scoped, self-cleaning, no state to manage. Constrain a worker by shipping its constraints in
the worker's own file.

**5. Plugin toggling works mid-session but is not free.** As of v2.1.221 an install can
report `Plugin is now active.` and take effect immediately; otherwise `/reload-plugins`
applies enable/disable/install changes and reloads plugins, skills, agents, hooks, plugin MCP
servers, and plugin LSP servers. If the reload would invalidate the prompt cache it warns and
skips until rerun with `--force`. Newly loaded components announce themselves in appended
content, and an MCP-providing plugin forces a full re-read of the conversation. Granularity is
the **whole plugin** — you cannot toggle one hook this way.

**6. A hook can defend itself.** `ConfigChange` fires on config edits with matchers
`user_settings`, `project_settings`, `local_settings`, `policy_settings`, `skills`, and exit 2
**blocks the change** — for every source except `policy_settings`. So a plugin can refuse to
let its own enforcement be edited away mid-session.

Use this deliberately and sparingly. A hook that cannot be turned off is a hook that will
eventually be in your way, and `disableAllHooks` plus a restart defeats it anyway. It's a
guardrail against the model casually rewriting settings, not a lock against the user.

### 5b. What is genuinely not possible

- **No programmatic hook registry.** A running hook cannot call an API to add or drop another
  hook by name. Its only lever is writing settings JSON (#1) and letting the watcher notice.
- **No unregister for skill hooks.** Once `/teamlead` registers them they live until the
  session ends, `once: true` retires them, or the plugin is disabled and reloaded.
- **No per-hook enable/disable at plugin level.** `/plugin disable` is all-or-nothing.
- **No conditional registration in the manifest.** `hooks.json` is static; there is no "only
  register this hook when X". You express the condition *inside* the hook, by exiting 0 early.

### 5c. What this means for teamlead-v2

The registration/deregistration asymmetry decides the design:

**Register hooks statically. Gate them at runtime with a flag file.**

Every teamlead hook starts with the same two lines:

```bash
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.teamlead-active" ] || exit 0
```

`/teamlead` writes the flag, `stop teamlead` removes it. The hooks are always registered and
almost always a no-op — an `exit 0` on a missing file costs microseconds and, crucially,
**zero tokens and zero prompt-cache invalidation**.

The alternatives are worse:

| Approach | Why not |
|---|---|
| `/plugin enable teamlead` on activation | Invalidates the prompt cache, needs `/reload-plugins`, whole-plugin granularity, and the user must not have it enabled already |
| Write hooks into `settings.local.json` on activation, delete on stop | Works (file watcher), but mutates the user's repo, races with the watcher, and leaves debris if the session dies |
| Skill frontmatter hooks alone | Registers fine, but "stop teamlead" cannot unregister them — you end up needing the flag file anyway |

So: skill frontmatter `hooks:` for the hooks that only make sense once teamlead has been
invoked, plugin `hooks/hooks.json` for the always-on minimum (statusline state), and the flag
file as the single source of truth both consult.

Two places where the dynamic mechanisms genuinely earn their keep:

- **Per-worker gates** (#4): each `tl-*.md` carries its own `Stop` hook. Added on spawn,
  removed on finish, no flag to check, no cleanup.
- **One-shot activation gates** (#3): a `once: true` hook that must succeed before the first
  turn ends — and stays armed if it exits 2 — enforces "the activation check is mandatory"
  without any prose at all.

---

## 6. What is NOT possible

Worth writing down so the design doesn't chase it.

- **No new built-in tools.** Adding tools = MCP server. Hooks only intercept existing ones.
- **No system-prompt editing.** You inject context; you don't rewrite the base prompt. The
  closest lever is a plugin `settings.json` with `"agent": "<name>"`, which swaps the *main
  thread* for one of the plugin's agents (its system prompt, tools, model).
- **No forcing a tool call.** You can block, allow, rewrite args, and refuse to stop. You
  cannot make the model call `Agent`. You can only make every alternative fail — which in
  practice is enough (deny `Edit` → the only way forward is delegation).
- **A plugin cannot install a main `statusLine`.** Plugin `settings.json` supports only
  `agent` and `subagentStatusLine`. Ponytail works around this by shipping the script and
  documenting a manual `~/.claude/settings.json` entry — with a version-pinned path that
  silently breaks on update. Don't copy that; ship an unpinned one-liner.
- **Hooks can be turned off** (`disableAllHooks`), and skill shell injection can be disabled
  (`disableSkillShellExecution`). Guard the first with a `ConfigChange` hook if it matters.
- **Frontmatter hooks can't unregister themselves** except via `once: true`. A mode that
  turns off needs a flag file the hooks consult. See §5 for the full add/remove picture.
- **`SubagentStart` can't block or modify.** To constrain worker spawn, hook `PreToolUse` on
  the `Agent` tool and use `updatedInput`.

---

## 7. Applied to teamlead-v2

### The architecture

```
SKILL.md (/teamlead)
  frontmatter hooks:  ── registered on invoke, live for the whole session
  body !`…` blocks:   ── activation state already in context, nothing to defer
      │
      ├─ writes .teamlead-active flag  (mode state + statusline source)
      │
      ├─ PreToolUse   Edit|Write   → deny unless agent_id present   (lead never edits)
      ├─ PreToolUse   Agent        → updatedInput: force isolation/worker type
      ├─ UserPromptSubmit          → re-assert role; catch "stop teamlead"
      ├─ SubagentStop              → capture branch state, gate on quality
      └─ Stop                      → exit 2 if worktrees hold unmerged work

agents/tl-*.md
  frontmatter hooks:  ── scoped to that worker only, auto-removed on finish
      └─ Stop (→ SubagentStop)     → run the repo's test command before "done"
```

No global `settings.json` edits. Everything ships in the plugin.

### Enforcement goals → mechanism

| # | Invariant currently defended by prose | Mechanism |
|---|---|---|
| 1 | "You never do the actual work yourself" | `PreToolUse` on `Edit\|Write\|NotebookEdit`, deny when `agent_id` is absent |
| 2 | "The activation check is mandatory, not deferrable" | Skill body `` !`…` `` — data is in context before turn 1 |
| 3 | "Stay in teamlead mode until 'stop teamlead'" | Skill-frontmatter hooks (session-lifetime) + flag file |
| 4 | Mode survives `/clear` and compaction | `SessionStart` matcher `compact\|clear\|resume` re-reads the flag |
| 5 | Mode is visible | Flag file + `statusLine` reading it (documented, not auto-installed) |
| 6 | "Worktree isolation is the default for every editing agent" | `PreToolUse` on `Agent`, `updatedInput` sets `isolation: "worktree"` |
| 7 | "Never remove a worktree with work in it silently" | `PreToolUse` on `Bash` with `if: "Bash(git worktree remove *)"` → deny unless clean |
| 8 | Don't end the session with unintegrated branches | `Stop` exit 2 listing the unmerged worktrees |
| 9 | Worker must actually verify before reporting done | Per-agent frontmatter `Stop` hook running the test command |
| 10 | Right model/effort per task | `PreToolUse` on `Agent` — inspect/rewrite `subagent_type`; `PreModelSwitch` to veto |
| 11 | Drift back to doing-it-myself on turn 40 | `UserPromptSubmit` `additionalContext` one-liner |

### The three that earn their place first

**`hooks/no-lead-edits.sh`** — the whole thesis in nine lines:

```bash
#!/usr/bin/env bash
in=$(cat)
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.teamlead-active" ] || exit 0
# workers carry agent_id; the lead does not
[ -n "$(jq -r '.agent_id // empty' <<<"$in")" ] && exit 0
jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
  permissionDecisionReason:"Teamlead does not edit files. Dispatch a tl-* worker."}}'
```

**`hooks/worktree-guard.sh`** — `Stop`, exit 2 with the list when branches are unmerged:

```bash
#!/usr/bin/env bash
in=$(cat)
[ "$(jq -r '.stop_hook_active // false' <<<"$in")" = "true" ] && exit 0  # don't loop
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.teamlead-active" ] || exit 0
dirty=$(git worktree list --porcelain | awk '/^worktree /{print $2}' | tail -n +2 |
  while read -r w; do [ -n "$(git -C "$w" status --porcelain)" ] && echo "$w"; done)
[ -z "$dirty" ] && exit 0
echo "Unintegrated worker worktrees remain:\n$dirty\nIntegrate or discard before finishing." >&2
exit 2
```

`stop_hook_active` is the infinite-loop guard: once a `Stop` hook has blocked, later ones see
`true` and must bail.

**`hooks/mode-tracker.sh`** — `UserPromptSubmit`. Watches for `stop teamlead`, rewrites the
flag, and while active emits one line of `additionalContext` re-asserting the role.

### Repo layout

```
claude-teamlead-v2/
├── .claude-plugin/
│   ├── plugin.json          # name: teamlead, hooks: ./hooks/hooks.json
│   └── marketplace.json     # so it installs from this repo directly
├── skills/
│   ├── teamlead/SKILL.md            # frontmatter hooks + !`…` activation block
│   ├── teamlead-optimized/SKILL.md
│   └── teamlead-tmux/SKILL.md
├── agents/tl-{sonnet,opus}-{low,medium,high}.md   # + per-agent Stop hooks
├── hooks/
│   ├── hooks.json           # always-on subset (statusline state, ConfigChange guard)
│   ├── no-lead-edits.sh
│   ├── worktree-guard.sh
│   ├── mode-tracker.sh
│   └── statusline.sh
└── docs/enforcement.md      # this file
```

`install.sh` / `install.ps1` disappear — `claude plugin marketplace add <user>/claude-teamlead-v2`
replaces both. Note plugin skills are namespaced: `/teamlead:teamlead`.

### Build order

1. `plugin.json` + move v1's `skills/` and `agents/` in. Verify with
   `claude --plugin-dir . ` and `claude plugin validate .`.
2. Add the `` !`…` `` activation block to `SKILL.md`; **delete** the "mandatory, runs before
   anything else" prose section. Measure the line count drop.
3. `no-lead-edits.sh` via skill frontmatter `hooks:`. This is the proof-of-concept — if
   `agent_id` discrimination works, the rest follows.
4. `mode-tracker.sh` + flag file + statusline.
5. `worktree-guard.sh` on `Stop`.
6. Per-agent `Stop` hooks in `tl-*.md`.
7. Only then consider `prompt`-type hooks for quality gates.

Each step should let you delete prose from `SKILL.md`. If it doesn't, the hook isn't
enforcing anything the model was going to skip anyway — drop it.

---

## 8. Prose that should stay prose

Not everything wants a hook. Keep in `SKILL.md`:

- How to split a task into parallel units.
- Which model/effort tier fits which kind of work (the `tl-*` selection rubric).
- How to merge and reconcile worker results.
- When to ask the user vs. decide.

These are judgment. A hook that tried to enforce them would be a worse decision-maker than
the model, and would fire on cases its author never imagined.

---

## 9. To verify before building

Marked honestly — these come from docs, not from a test on this machine:

1. **Does `PreToolUse` input actually carry `agent_id` for subagent tool calls?** The common-
   fields table says yes ("subagent only"). Confirm with a hook that dumps stdin to a file,
   then run one worker. Everything in §7 depends on this.
2. **Do skill-frontmatter hooks fire for tool calls made by subagents the skill spawned**, or
   only for the main thread? Determines whether #1 is even needed.
3. **Can `updatedInput` on the `Agent` tool set `isolation`?** Docs confirm `updatedInput`
   exists for `PreToolUse`; the `Agent` tool's schema acceptance is untested.
4. **Ordering of multiple `Stop` hooks** and whether `stop_hook_active` is per-hook or
   per-turn.
5. **How reliable is the settings file watcher?** The docs hedge with "normally picked up".
   Only matters if v2 ever writes hooks at runtime — the flag-file design in §5c avoids
   depending on it.
6. Whether `jq` should be a hard dependency or replaced with node (ponytail ships node
   scripts with a `command -v node || exit 0` guard — a good portability pattern to copy).
