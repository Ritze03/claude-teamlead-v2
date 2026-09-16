# Documentation Version Policy

**Active policy: auto version bump.** Every dated changelog/doc block gets a semantic version
bump sized to that period's user-facing magnitude (patch / minor / major), kept in sync with
this project's version marker. You size the bump — judge it honestly from what actually
changed.

## How to apply it every run

- **Maintain the changelog (or equivalent dated doc) as you work.** Whenever you make a
  user-facing change, add a bullet under the right heading in **today's** dated block.
- **Group entries by date — one block per day.** Each day's work gets its own
  `## [x.y.z] – YYYY-MM-DD` block (with its own version, per the bump rule below). When adding
  a bullet:
  - If **today's** block already exists at the top, add your bullet under the right category
    inside it.
  - Otherwise, create a **new** block at the **top** (newest date first), choose its version
    per the bump rule below, and put the bullet there.
  - Do **not** change an existing block's date or version — past days keep theirs.
- **Every dated block is its own version bump — you size it.** Each block's version is a
  **new** bump relative to the block below it (the previous day), and how big the bump is
  reflects how big that day's user-facing changes were. Read the day's actual changes and
  judge the magnitude honestly — don't inflate:
  - **Patch** (`x.y.Z+1`) — a small day: a handful of fixes, polish, a minor tweak, or a small
    feature surfaced.
  - **Minor** (`x.Y+1.0`) — a substantial day: meaningful new features or a notable rework.
  - **Major** (`X+1.0.0`) — a true milestone or breaking overhaul. While the project is
    pre-1.0, hold off unless it's genuinely a 1.0-scale landmark; most days are patch or
    minor.
- **Keep the project's version marker in sync with the newest (top) block.** Find whatever
  file this project uses to declare its current version (e.g. a package manifest, a
  `VERSION` file, a build config — whichever applies here) and update it to match the newest
  block's version. Older blocks keep the version they were assigned — never re-bump a past
  day.
- **Purely internal changes with no user-facing effect get no entry and no bump.** A day of
  only refactors, tests, or internal tooling adds no new block.
