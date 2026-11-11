# Permissions under auto mode

Teamlead's flow is worker, then QC row, then the lead merges. Claude Code's **auto
permission mode** puts a classifier in front of every shell command, and the
classifier sees only the command text and the conversation, not the board. It can
therefore refuse a perfectly reviewed merge as `[Merge Without Review]`
([#3](https://github.com/Ritze03/claude-teamlead-v2/issues/3)). The plugin does not
control that classifier and its answers are not deterministic. What it does:

- the lead states the review evidence (QC row id + verdict) in the turn right before the merge;
- a brief never tells a worker to merge, push or delete a branch (a dispatch whose brief
  said "merge the PR yourself" was itself refused); workers commit and report;
- before a run you will walk away from (the reply to the plan's second Go, or when you say
  you want a long unattended run) the lead offers the rules below up front, as one command
  you run yourself, so the run does not stall on a prompt nobody answers;
- on any refusal the lead stops, tells you, and offers the same command with only the
  lines that refusal needs. The lead never writes settings itself (the classifier can refuse
  that as self-modification) and neither does a hook.

## The allow rules

They go in the project's `.claude/settings.json` (shared) or `.claude/settings.local.json`
(yours only), under `permissions.allow`:

```json
{
  "permissions": {
    "allow": [
      "Bash(git merge *)",
      "Bash(git push *)",
      "Bash(gh pr merge *)",
      "Bash(bash */scripts/worker-cleanup.sh *)"
    ]
  }
}
```

The lead hands you this as a `!` one-liner. The `!` prefix runs it as your own command, not
as a lead tool call. It needs `jq`; it creates `.claude/settings.json` if missing,
keeps every other key, and appends only the rules not already in the array. Run it from
the project root (the lead trims the array to the rules it is offering; for the local
file, change `settings.json` to `settings.local.json`):

```
!mkdir -p .claude && f=.claude/settings.json && { [ -f $f ] || echo '{}' > $f; } && jq --argjson new '["Bash(git merge *)","Bash(git push *)","Bash(gh pr merge *)","Bash(bash */scripts/worker-cleanup.sh *)"]' '(.permissions.allow // []) as $a | .permissions.allow = $a + ($new - $a)' $f > $f.tmp && mv $f.tmp $f
```

If the file exists but is not valid JSON (comments, a trailing comma), `jq` fails, the file
is left untouched and a stray `settings.json.tmp` remains to delete. If the rules do not
take effect right away, restart the session (the fresh-context `/clear` does it).

| Rule | Covers | Add it when |
|---|---|---|
| `Bash(git merge *)` | the lead merging an accepted worker branch | a local merge flow, or a `git merge` is refused |
| `Bash(git push *)` | the lead pushing | the run pushes, or a `git push` is refused |
| `Bash(gh pr merge *)` | merging a PR after QC (only if your flow uses PRs) | a PR flow, or a `gh pr merge` is refused |
| `Bash(bash */scripts/worker-cleanup.sh *)` | worker cleanup: `git worktree remove` + `git branch -d`, never `--force` | any flow that merges workers, or the cleanup call is refused |

The up-front offer lists the rules the planned flow needs; after a refusal the lead offers
only the lines that refusal needs. Everything else the plugin prescribes
(`board.py forget`/`clean`/`drop`, `gh issue create`, deleting state files) has no rule
here: if one is ever refused, the lead asks you before anything is allowed.

## Worker writes outside the worktree

A path the lead boards as an absolute entry of a worker's `owns` needs no `Edit`/`Write`
allow rule: the worker fence answers Claude Code's prompt with an allow for exactly those
paths (the hooks docs: a hook allow skips the prompt, but deny and ask rules are still
evaluated). Bash writes are not covered: a `Bash(...)` rule is still needed for those.

## A prompt that mentions the scratchpad or a symlink

A prompt like "`…/.claude/worktrees/agent-…/target/x/out.log` resolves through a symlink
to `/tmp/claude-1000/…/scratchpad/…`, which is outside the allowed working directories"
means a worker touched the lead's session scratchpad (Claude Code tells every agent to
"use the scratchpad for temporary files"). A worker's Bash or Read there, directly or
through a symlink, is outside its allowed directories, so every access prompts and a
background worker blocks until you click. Since 2.3.1 workers keep scratch files, logs and
test output in `.tl-scratch/` inside their own worktree (the plugin adds it to
`.git/info/exclude`, so it is never committed), the lead never points a worker at its own
scratchpad, and `/tmp` (RAM) is not used for large outputs. If you still see this prompt,
a brief or an older agent version sent the worker there: deny it and tell the lead.

## Syntax (Claude Code docs, "Configure permissions")

- Rules are `Tool(specifier)`; Bash rules match the command text, `*` is a wildcard.
  A trailing ` *` also matches the bare command (`Bash(ls *)` matches `ls`).
- `Bash(x:*)` is an older equivalent of `Bash(x *)`; the `:*` form is recognised only
  at the end of a pattern.
- Put the `*` after the subcommand. A `*` in the middle works for paths, as in
  `*/scripts/worker-cleanup.sh`, but Claude Code warns about a `*` before the subcommand.
- Rules are checked deny, then ask, then allow; the first match wins. A deny or ask rule
  beats any allow rule.
- A rule matches the command as written: `git -C <dir> merge` does not match
  `Bash(git merge *)`, and `a && b` needs both halves allowed.
- In auto mode, **narrow** allow rules are resolved before the classifier and stay in
  effect; broad ones that grant arbitrary execution (`Bash(*)`, wildcarded interpreters)
  are suspended. `autoMode.classifyAllShell: true` suspends all Bash allow rules.
- `autoMode` settings (environment, allow, soft_deny) are **not** read from the project's
  `.claude/settings.json`; only from `~/.claude/settings.json`, managed settings or
  `--settings`. `permissions.allow` is read from project settings.
- You can also clear a single refusal by saying so in your next message ("yes, merge it");
  or open `/permissions` → Recently denied and press `r` to retry.

Sources: https://code.claude.com/docs/en/permissions (Wildcard patterns, Compound
commands) and https://code.claude.com/docs/en/auto-mode-config (Where the classifier
reads configuration, Route all shell commands through the classifier, Review denials).

## Which lead actions can a permission layer refuse?

| Action the lead is told to run | Refusable | Recovery |
|---|---|---|
| merge a worker branch into the checked-out branch | yes | the general rule: stop, tell the user, offer `Bash(git merge *)` (or offered up front at the second Go) |
| `gh pr merge` | yes (the skill has no PR flow of its own) | same |
| `worker-cleanup.sh` (worktree remove, `branch -d`) | yes | same; the script's own refusals (dirty tree, unmerged branch) are separate, exit 1, and are fixed rather than forced |
| `git branch -D`, `git worktree remove --force` | yes | never prescribed; a refused `-d` is not escalated to `-D` |
| `git push` | yes | the general rule: stop, tell the user, offer `Bash(git push *)` |
| `gh issue create` | yes | already user-gated; a refusal falls under the general rule |
| `board.py forget` / `clean` / `drop` | possible | `drop` already asks first; a refusal falls under the general rule |
| deleting state files | possible | never prescribed by hand; scripts do it |

The single rule: **permission refusal → stop, tell the user, offer the allow rule, never
route around it.**
