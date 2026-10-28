# Release rule

Any push that changes what users get (hooks, skills, agents, scripts) must, in the same push:

- bump `version` in `.claude-plugin/plugin.json` (semver: patch for fixes, minor for features), and
- add a `CHANGELOG.md` entry for that version.

Claude Code caches installs by version (`~/.claude/plugins/cache/teamlead/teamlead/<version>`), so without a bump users never receive the change. `marketplace.json` carries no version; `plugin.json` is the single source.

How a user checks their build: `/plugin`; or `jq '.plugins["teamlead@teamlead"]' ~/.claude/plugins/installed_plugins.json` (version plus gitCommitSha); or the `[teamlead vX.Y.Z]` line printed at session start.
