# Documentation Version Policy

**Active policy: manual.** Version numbers and dates on docs/changelog blocks are set by the
human, not the agent. The agent never bumps a version or stamps a date on its own initiative.

## How to apply it every run

- **Record changes as you work**, same as under any other policy — add a bullet describing
  the user-facing change to the relevant doc or changelog.
- **Do not invent a version number.** Do not write `[x.y.z]`, bump any version marker in the
  repo, or guess at semver magnitude.
- **Do not stamp a date on your own.** Do not assume "today" belongs in a new dated block
  without being told to start one.
- **Ask the human** which version number and/or date to use before finalizing a new dated
  block. If they've already told you in this session, use what they said; otherwise, ask
  before creating the block rather than guessing.
- If a bullet needs to be added to an **existing** block (same unreleased/unfinished period the
  human hasn't versioned yet), add it there without creating a new header — only open a new
  block when the human indicates a new version/date should start.
