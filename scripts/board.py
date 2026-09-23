#!/usr/bin/env python3
"""Teamlead board: JSON is the truth, board.md is a rendering.

The board is the one durable artefact the model writes, so it is the one that can
be wrong. Making it a generated file removes that whole class of error: the model
never writes the table, it calls a mutation and the table is re-rendered.

Two front ends over the same core:
  CLI   board.py <cmd> ...            (hooks, tests, humans)
  MCP   board.py --mcp                (the agent, as tool calls)

Commands: add, update, remove, list, status, check, render, clean, drop,
          forget, ledger, worker-start, worker-stop.

Validation happens at WRITE time, so a bad board cannot exist rather than being
detected afterwards.
"""
from __future__ import annotations
import json, os, re, sys, datetime, pathlib, shutil, subprocess, fcntl, contextlib

STATES = ("queued", "running", "returned", "merged", "blocked")


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _main_checkout(p: str) -> str:
    """A worker runs inside .claude/worktrees/agent-x, whose cwd looks like its own
    project. Its board lives in the MAIN checkout — otherwise the worker reads an
    empty board, and a write would create a phantom one that dies with the worktree.
    git-common-dir points at the main repo's .git from any linked worktree."""
    try:
        r = subprocess.run(["git", "-C", p, "rev-parse", "--git-common-dir"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            common = pathlib.Path(r.stdout.strip())
            if not common.is_absolute():
                common = pathlib.Path(p) / common
            return str(common.resolve().parent)
    except Exception:
        pass
    return p


def root(project: str | None = None) -> pathlib.Path:
    p = project or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    return pathlib.Path(_main_checkout(p)) / ".claude" / "teamlead"


def _refuse_if_worker() -> None:
    """D4/F17: a worker can reach the CLI as easily as the lead's shell. The MCP
    tools are fenced by board-fence.sh (it sees agent_id on the hook payload);
    the CLI has no such gate, so it needs the same refusal here. CLAUDE_AGENT_ID
    is set by the harness for subagents and absent from the lead's own shell."""
    if os.environ.get("CLAUDE_AGENT_ID"):
        raise ValueError("refused — board writes are the lead's; workers report, "
                         "the lead records (CLAUDE_AGENT_ID is set)")


def _write_project(project: str | None) -> str:
    """F17: a worker's throwaway temp dir is often itself a git repo, and
    _main_checkout would happily resolve that up to whatever checkout it lives
    under — which can BE the real project. Reads may fall back to cwd; writes
    must not — only an explicit --project or CLAUDE_PROJECT_DIR is trusted."""
    p = project or os.environ.get("CLAUDE_PROJECT_DIR")
    if not p:
        raise ValueError("refused — pass --project <main checkout> "
                         "(board writes never resolve from cwd)")
    return p


def _paths(project=None):
    r = root(project)
    return r / ".state" / "board.json", r / "board.md"


def load(project=None, strict=False) -> dict:
    """F2: the lenient default keeps every read path working on a damaged
    board — but a caller about to DESTROY the file has to be able to tell
    'the board is empty' from 'the board did not parse', because those two
    want opposite answers. strict=True re-raises the JSONDecodeError instead
    of quietly handing back an empty board."""
    j, _ = _paths(project)
    if j.exists():
        try:
            return json.loads(j.read_text())
        except json.JSONDecodeError:
            if strict:
                raise
    return {"next_id": 1, "tasks": []}


def _norm_owns(owns) -> list[str]:
    if owns is None:
        return []
    if isinstance(owns, str):
        owns = [o for o in owns.replace(",", "\n").split("\n")]
    return [o.strip().strip("`").rstrip("/") for o in owns if o and o.strip()]


def _overlap(a: str, b: str) -> bool:
    if a == b:
        return True
    return (a + "/").startswith(b + "/") or (b + "/").startswith(a + "/")


def _git(project, *args):
    try:
        r = subprocess.run(["git", "-C", str(project), *args],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def _git_ok(project, *args) -> bool | None:
    """Like _git, but for commands where a non-zero exit is itself the (non-error)
    answer — e.g. `diff --quiet` returns 1 to mean 'differs', not 'failed'."""
    try:
        r = subprocess.run(["git", "-C", str(project), *args],
                           capture_output=True, text=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return None


def _worktree_branches(proj) -> dict:
    """`git worktree list --porcelain` parsed once into {'refs/heads/<name>':
    <path>} — D7 needs this per check_git call, not per row."""
    out = _git(proj, "worktree", "list", "--porcelain") or ""
    branches, path = {}, None
    for line in out.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch ") and path:
            branches[line[len("branch "):]] = path
    return branches


def check_git(db: dict, project=None) -> list[str]:
    """The board validates itself; nothing asked git whether 'merged' was true.
    A task marked merged whose commits are not in HEAD is exactly the reported
    'work never merged back', and was undetectable.

    A squash merge lands the content but its branch commits are never ancestors
    of HEAD, so rev-list alone would call every squash merge 'not merged'. A task
    counts as merged when rev-list is 0 OR the owned paths no longer differ from
    the branch — a task with no owned paths (read-only) has nothing to diff, so
    it falls back to rev-list only. `diff --quiet` is also clean when the
    pathspec matches nothing on either side, so a typo'd or untouched `owns`
    would otherwise pass as merged with real unmerged commits on the branch;
    the diff shortcut only counts when the branch actually touched something
    under `owns` (its name-only diff against the merge-base is non-empty)."""
    proj = pathlib.Path(_main_checkout(project or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()))
    if _git(proj, "rev-parse", "--is-inside-work-tree") != "true":
        return []
    problems = []
    main = _git(proj, "rev-parse", "--abbrev-ref", "HEAD") or "HEAD"
    wt_by_branch = _worktree_branches(proj)
    for t in db["tasks"]:
        br = (t.get("branch") or "").strip()
        if t["state"] != "merged" or not br or br in ("-", "—"):
            continue
        if _git(proj, "rev-parse", "--verify", "--quiet", br) is None:
            continue                      # branch already deleted after merging: fine
        n = _git(proj, "rev-list", "--count", f"HEAD..{br}")
        if not n or n == "0":
            continue                      # ordinary (non-squash) merge
        owns = t.get("owns") or []
        mb = _git(proj, "merge-base", "HEAD", br) if owns else None
        touched = bool(mb) and bool(_git(proj, "diff", "--name-only", mb, br, "--", *owns))
        squashed = touched and _git_ok(proj, "diff", "--quiet", "HEAD", br, "--", *owns)
        if not squashed:
            problems.append(
                f"task {t['id']} is marked merged but branch {br} has {n} commit(s) "
                f"not in HEAD — it was not actually merged back")
    # D7: independent of the check above — a merged row can be both "not
    # actually merged back" AND still hold a worktree; both lines are useful,
    # the second tells the lead what to do once the first is fixed. Never
    # removes anything.
    for t in db["tasks"]:
        br = (t.get("branch") or "").strip()
        if t["state"] != "merged" or not br or br in ("-", "—"):
            continue
        path = wt_by_branch.get(f"refs/heads/{br}")
        if path:
            problems.append(
                f"task {t['id']} is merged but worktree {path} still exists — "
                f"`git worktree remove {path}`")
    # D6: a 'returned' branch about to be merged should not have fallen
    # behind main since the worker branched off. 'running' rows are skipped
    # on purpose — a running row falls behind every time anyone else merges,
    # and a warning the lead cannot act on trains it to ignore the gate.
    for t in db["tasks"]:
        if t["state"] != "returned":
            continue
        br = (t.get("branch") or "").strip()
        if not br or br in ("-", "—"):
            continue
        if _git(proj, "rev-parse", "--verify", "--quiet", br) is None:
            continue                      # branch already gone: nothing to warn about
        if _git_ok(proj, "merge-base", "--is-ancestor", "HEAD", br) is False:
            problems.append(
                f"task {t['id']} branch {br} is behind {main} — rebase before merging")
    return problems


_STEP_RE = re.compile(r"^\|\s*(\d+)\s*\|\s*(I\d+[a-z]?)\s*\|")
_PHASE_RE = re.compile(r"^\|\s*(?:—|-)\s*\|\s*\*\*")
_STAGE_RE = re.compile(r">\s*\*\*Stage\s+(\d+)\*\*", re.I)


def check_plan(db: dict, project=None) -> list[str]:
    """The wave table and the board can drift apart: a step gets planned but the
    lead forgets to board_add it. Below stage 5 the board is legitimately empty
    (nothing dispatched yet), so this only fires once building has started.

    The plan is built one phase (or, absent phase rows, one wave) at a time, so
    only the CURRENT group's steps are expected on the board. With phase rows,
    the current group is the phase that already has at least one step there
    (falling back to the first phase when none does). Without phase rows, the
    current group is the lowest wave that has a step on the board and isn't
    fully merged yet; if no wave qualifies (nothing boarded, or every boarded
    wave is already fully merged), it falls back to the lowest wave that has
    no step on the board and isn't fully merged — the natural "next wave" nudge.
    A fully-merged wave is never demanded.
    """
    ap = root(project) / ".state" / "active-plan"
    if not ap.exists():
        return []
    plan_path = ap.read_text().strip()
    if not plan_path:
        return []
    pf = pathlib.Path(plan_path)
    if not pf.exists():
        return []
    text = pf.read_text(errors="replace")
    m = _STAGE_RE.search(text)
    if not m or int(m.group(1)) < 5:
        return []

    has_phases = any(_PHASE_RE.match(line) for line in text.splitlines())
    on_board = {t["plan"] for t in db["tasks"] if t.get("plan")}

    if has_phases:
        groups: list[list[str]] = []
        current: list[str] | None = None
        for line in text.splitlines():
            if _PHASE_RE.match(line):
                current = []
                groups.append(current)
                continue
            sm = _STEP_RE.match(line)
            if sm:
                if current is None:
                    current = []
                    groups.append(current)
                current.append(sm.group(2))
        if not groups:
            return []
        target = next((g for g in groups if any(i in on_board for i in g)), groups[0])
        return [f"plan step {i} has no board task — copy it from the wave table "
                f"(board_add with plan: {i})" for i in target if i not in on_board]

    # No phase rows: group by wave number instead.
    waves: dict[int, list[str]] = {}
    for line in text.splitlines():
        sm = _STEP_RE.match(line)
        if sm:
            waves.setdefault(int(sm.group(1)), []).append(sm.group(2))
    if not waves:
        return []

    merged_states = {t["plan"]: t["state"] for t in db["tasks"] if t.get("plan")}

    def fully_merged(steps):
        return all(merged_states.get(i) == "merged" for i in steps)

    def has_board(steps):
        return any(i in on_board for i in steps)

    target = None
    for wave in sorted(waves):
        steps = waves[wave]
        if has_board(steps) and not fully_merged(steps):
            target = steps
            break
    if target is None:
        for wave in sorted(waves):
            steps = waves[wave]
            if not has_board(steps) and not fully_merged(steps):
                target = steps
                break
    if target is None:
        return []
    return [f"plan step {i} has no board task — copy it from the wave table "
            f"(board_add with plan: {i})" for i in target if i not in on_board]


def _chain_reaches(start: int, target: int, by_id: dict) -> bool:
    """BFS over blocked_by from `start`; True if `target` is reached. Rows of
    any state — merged included — count as links: a merged row in the middle
    of a chain still connects its neighbours. `seen` guards a blocked_by
    cycle; a dangling id that names no row is just a dead end."""
    seen, frontier = {start}, [start]
    while frontier:
        nxt = []
        for tid in frontier:
            for b in (by_id.get(tid, {}).get("blocked_by") or []):
                if b == target:
                    return True
                if b not in seen:
                    seen.add(b)
                    nxt.append(b)
        frontier = nxt
    return False


def _chain_linked(a_id: int, b_id: int, by_id: dict) -> bool:
    """D8: two unfinished rows may own overlapping paths iff one is in the
    other's blocked_by chain, transitively — blocked_by only points from a
    row to what it waits on, so the id order of the pair doesn't say which
    direction to walk; try both."""
    return _chain_reaches(a_id, b_id, by_id) or _chain_reaches(b_id, a_id, by_id)


def _validate_detailed(db: dict) -> list[tuple[frozenset, str]]:
    """Like validate(), but tags each problem with the task id(s) it involves, so a
    targeted refusal (mutate) can report only what the edit actually touched while
    check/status keep reporting everything."""
    problems, seen = [], set()
    by_id = {t["id"]: t for t in db["tasks"]}
    live = [t for t in db["tasks"] if t["state"] not in ("merged",)]
    merged_ids = {t["id"] for t in db["tasks"] if t["state"] == "merged"}
    for t in db["tasks"]:
        tid = t["id"]
        if tid in seen:
            problems.append((frozenset({tid}), f"duplicate task id {tid}"))
        seen.add(tid)
        if t["state"] not in STATES:
            problems.append((frozenset({tid}), f"task {tid} has unknown state {t['state']!r}"))
        if t["state"] in ("running", "returned") and not t.get("agent"):
            problems.append((frozenset({tid}), f"task {tid} is {t['state']} with no agent"))
        if t["state"] == "blocked" and t.get("blocked_by") and all(b in merged_ids for b in t["blocked_by"]):
            problems.append((frozenset({tid}),
                f"task {tid} is blocked but all its blockers are merged — it should be queued"))
        # D9: board_update accepts arbitrary state jumps, so gating only
        # 'running' would leave 'queued -> merged' open — and a merged row's
        # overlaps are never checked again (D8), so that gap would reopen
        # the overlap hole this same change closes. One problem per unmerged
        # blocker; a blocked_by id naming no row is ignored, not invented.
        if t["state"] in ("running", "merged"):
            for b in t.get("blocked_by") or []:
                blocker = by_id.get(b)
                if blocker and blocker["state"] != "merged":
                    problems.append((frozenset({tid, b}),
                        f"task {tid} is blocked by {b}, which is {blocker['state']}"))
    for i, a in enumerate(live):
        for b in live[i + 1:]:
            if _chain_linked(a["id"], b["id"], by_id):
                continue               # D8: linked through blocked_by — overlap is fine
            for pa in a["owns"]:
                for pb in b["owns"]:
                    if _overlap(pa, pb):
                        problems.append((frozenset({a["id"], b["id"]}),
                            f"tasks {a['id']} and {b['id']} are both unfinished and own "
                            f"overlapping paths ({pa!r} vs {pb!r}) — two writers on one path"))
    return problems


def validate(db: dict) -> list[str]:
    """Only unfinished tasks can collide. Finished work shares freely."""
    return [msg for _, msg in _validate_detailed(db)]


def render(db: dict) -> str:
    live = [t for t in db["tasks"] if t["state"] != "merged"]
    done = [t for t in db["tasks"] if t["state"] == "merged"][-10:]
    out = ["# Board", "",
           "<!-- GENERATED from .state/board.json — do not hand-edit; use the board tools -->",
           "", "| ✓ | ID | Task | Agent | Owns | State | Branch |",
           "|:-:|:--:|------|-------|------|-------|--------|"]

    def row(t, tick):
        owns = ", ".join(f"`{o}`" for o in t["owns"]) or "*(read-only)*"
        st = t["state"]
        if st == "blocked" and t.get("blocked_by"):
            st = "blocked-by " + ",".join(str(x) for x in t["blocked_by"])
        # The lead often writes the plan ref into the task text too; appending it
        # again gave "… — I1 — I1".
        task, pl = t["task"], t.get("plan")
        if pl and not task.rstrip().endswith(pl):
            task = f"{task} — {pl}"
        return (f"| {tick} | {t['id']} | {task} | "
                f"{'`'+t['agent']+'`' if t.get('agent') else ''} | {owns} | {st} | "
                f"{t.get('branch') or '—'} |")

    out += [row(t, " ") for t in live]
    if done:
        out += ["", "## Done", "",
                "| ✓ | ID | Task | Agent | Owns | State | Branch |",
                "|:-:|:--:|------|-------|------|-------|--------|"]
        out += [row(t, "x") for t in done]
        notes = [t for t in done if t.get("notes")]
        if notes:
            out += ["", "### How it was solved", ""]
            out += [f"- **{t['id']}** {t['notes']}" for t in notes]
    return "\n".join(out) + "\n"


# A real row's first cell is the ✓/blank tick, its second the bare task id — that
# shape (pipe, tick cell, pipe, digits, pipe) only occurs in data rows: the header's
# second cell is "ID" and the separator's is ":--:", neither of which is a bare int.
_ROW_RE = re.compile(r"^\|[^|\n]*\|\s*\d+\s*\|", re.MULTILINE)


def _has_task_rows(md: str) -> bool:
    return bool(_ROW_RE.search(md))


def _atomic_write(path: pathlib.Path, text: str) -> None:
    """Same-directory tmp file + os.replace: a reader never sees a half-written
    file, and a crash mid-write leaves the old file intact, never a corrupt one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp{os.getpid()}")
    tmp.write_text(text)
    os.replace(tmp, path)


def save(db: dict, project=None) -> None:
    j, m = _paths(project)
    _atomic_write(j, json.dumps(db, indent=2) + "\n")
    _atomic_write(m, render(db))


# ---- operations -------------------------------------------------------------

def op_add(db, task, agent=None, owns=None, plan=None, blocked_by=None, **_):
    t = {"id": db["next_id"], "task": task, "agent": agent,
         "owns": _norm_owns(owns), "state": "blocked" if blocked_by else "queued",
         "branch": None, "plan": plan, "blocked_by": blocked_by or [],
         "notes": None, "worker": None, "created": now(), "updated": now()}
    db["next_id"] += 1
    db["tasks"].append(t)
    return t


def _auto_unblock(db) -> None:
    """A blocked task whose blockers have all merged should be queued, not sit
    flagged until someone notices — so every update sweeps for it, whether this
    edit just merged the blocker or just set blocked_by to ids already merged.
    An empty blocked_by is NOT vacuously satisfied: 'blocked' with no blockers is
    a legitimate state (the lead can mark a task blocked before it knows why, or
    for a reason outside blocked_by) and must not be silently reverted to queued
    in the same call that set it. op_remove handles the "last blocker dropped"
    case explicitly instead of relying on this sweep."""
    merged_ids = {t["id"] for t in db["tasks"] if t["state"] == "merged"}
    for t in db["tasks"]:
        by = t.get("blocked_by") or []
        if t["state"] == "blocked" and by and all(b in merged_ids for b in by):
            t["state"] = "queued"


def op_update(db, id, **kw):
    for t in db["tasks"]:
        if t["id"] == int(id):
            for k in ("task", "agent", "state", "branch", "plan", "notes", "worker"):
                if kw.get(k) is not None:
                    t[k] = kw[k]
            if kw.get("owns") is not None:
                t["owns"] = _norm_owns(kw["owns"])
            if kw.get("blocked_by") is not None:
                t["blocked_by"] = kw["blocked_by"]
            t["updated"] = now()
            _auto_unblock(db)
            return t
    raise KeyError(f"no task with id {id}")


def _strip_blocked_by(db, gone: set[int]) -> list[int]:
    """F4: every path that deletes rows must also delete the references to
    them. A blocked_by naming a row that no longer exists is not inert: it can
    never be satisfied, because _auto_unblock requeues only when every blocker
    id is in merged_ids and a deleted id can never re-enter that set. The row
    is then stuck in 'blocked' for the life of the board with no way out but
    hand-editing board.json, and board.md renders a 'blocked-by' pointing at
    nothing. Dropping the reference is not a change to the row's meaning —
    leaving it is. Shared by op_remove (one id) and clean (the merged set).

    Returns every OTHER row this changed, so mutate()'s refusal check covers
    the cascade: an unblocked row can newly overlap in owns with something it
    was only separated from by that blocked_by chain (D8)."""
    touched = []
    for other in db["tasks"]:                    # drop the ghost from blocked_by
        by = other.get("blocked_by") or []
        if any(b in gone for b in by):
            other["blocked_by"] = [b for b in by if b not in gone]
            touched.append(other["id"])
            # removing the sole blocker requeues the dependant explicitly —
            # _auto_unblock no longer treats an empty blocked_by as satisfied
            if not other["blocked_by"] and other["state"] == "blocked":
                other["state"] = "queued"
    _auto_unblock(db)
    return touched


def op_remove(db, id, **_):
    """F17/D4: a repair op, not a workflow op — the only way today to drop a
    stray task (e.g. one a worker's CLI write left behind) is hand-editing
    board.json. Running or returned means a worker may still act on it, or
    the lead hasn't yet looked at its report, so those are refused.

    Removal can also unblock other rows (dropping the ghost id from their
    blocked_by, possibly flipping blocked->queued) — those rows can newly
    overlap in owns with something no longer separated by a blocked_by chain
    (D8). 'touched' reports every row this op changed besides the removed
    one, so mutate()'s refusal check covers the cascade, not just the id
    that was asked to be removed."""
    id = int(id)
    idx = next((i for i, t in enumerate(db["tasks"]) if t["id"] == id), None)
    if idx is None:
        raise KeyError(f"no task with id {id}")
    t = db["tasks"][idx]
    if t["state"] in ("running", "returned"):
        raise ValueError(f"refused — task {id} is {t['state']}, not removable "
                         f"(only queued/blocked/merged tasks can be removed)")
    del db["tasks"][idx]
    touched = _strip_blocked_by(db, {id})
    return {"id": id, "removed": True, "state": t["state"], "touched": touched}


@contextlib.contextmanager
def _board_lock(project=None):
    """D5: the MCP server, hook processes and the CLI all write board.json — an
    unlocked load->edit->save can silently drop a concurrent write (both load the
    same next_id, the second save wins). fcntl.flock on a dedicated lock file
    (not board.json itself, so a plain read never blocks) serialises the whole
    load->save window across processes. Reusable: I4 wraps forget()'s board
    write with this same helper."""
    lock = root(project) / ".state" / "board.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    with open(lock, "a+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def mutate(fn, project=None, **kw):
    """A refusal here only reports problems touching the id(s) this edit added or
    updated — a pre-existing problem elsewhere on the board must not block an
    unrelated write. (The explicit `check` command still reports everything.)
    A result dict's optional 'touched' list widens this beyond 'id' alone, for
    an op whose edit cascades to other rows (op_remove's blocked_by cleanup).
    If fn returns None (no matching row — the find-then-mutate ops), nothing
    is saved or validated: the board did not change."""
    with _board_lock(project):
        db = load(project)
        res = fn(db, **kw)
        if res is None:
            return None
        touched = {res["id"]} | set(res.get("touched", [])) if isinstance(res, dict) and "id" in res else set()
        problems = [msg for ids, msg in _validate_detailed(db) if not touched or ids & touched]
        if problems:
            raise ValueError("refused — the board would be invalid:\n  " + "\n  ".join(problems))
        save(db, project)
        return res


def op_worker_resume(db, agent_id, **_):
    """D12/QC3: the find (which row is this agent's returned row?) must happen
    under the same lock as the write, or a concurrent op_worker_stop/
    op_requeue_lost racing on a stale snapshot can clobber a state this one
    just set. None (no matching row) tells mutate() to save nothing."""
    row = next((t for t in db["tasks"]
                if t.get("worker") == agent_id and t["state"] == "returned"), None)
    if row is None:
        return None
    row["state"] = "running"
    row["updated"] = now()
    _auto_unblock(db)
    return row


def op_worker_stop(db, agent_id, **_):
    """D12/QC3: see op_worker_resume — find-then-set inside the lock."""
    row = next((t for t in db["tasks"]
                if t.get("worker") == agent_id and t["state"] == "running"), None)
    if row is None:
        return None
    row["state"] = "returned"
    row["updated"] = now()
    return row


def op_requeue_lost(db, agent_id, **_):
    """D2/D12/QC3,4: forget()'s requeue, moved inside the lock (see
    op_worker_resume) so it re-checks 'is this agent's row still running?'
    against the live board, not a snapshot a racing worker_stop may have
    already moved to 'returned'. Lands on 'blocked', not 'queued', when the
    row's blocked_by isn't fully merged — the same condition _auto_unblock
    uses, inverted — so a requeue never hands the lead a runnable-looking row
    that D9 would refuse anyway."""
    row = next((t for t in db["tasks"]
                if t.get("worker") == agent_id and t["state"] == "running"), None)
    if row is None:
        return None
    merged_ids = {t["id"] for t in db["tasks"] if t["state"] == "merged"}
    by = row.get("blocked_by") or []
    row["state"] = "blocked" if by and not all(b in merged_ids for b in by) else "queued"
    line = f"requeued: worker {agent_id} lost on restart"
    row["notes"] = line if not row.get("notes") else row["notes"] + "\n" + line
    row["updated"] = now()
    return row


def worker_start(agent_id, project=None, board=None, branch=None):
    """D12: PostToolUse(Agent) calls this right after a dispatch whose brief
    carried `board: N`, with --board=N — row N moves to running/worker/branch
    through mutate(op_update) so every rule applies, D9's blocked-by gate
    included. SubagentStart calls it with no --board on EVERY start, including
    a finished worker resumed via SendMessage (the retry ladder) — that path
    finds the row this agent id last had 'returned' and reopens it; no match
    (the common case: the row is already 'running' from the --board call, or
    this is a scout with no board row) is a silent no-op. Either path is a
    no-op, never creating a board, when the project has none yet."""
    j, _ = _paths(project)
    if not j.exists():
        return None
    if board is not None:
        return mutate(op_update, project=project, id=board, state="running",
                       worker=agent_id, branch=branch)
    return mutate(op_worker_resume, project=project, agent_id=agent_id)


def worker_stop(agent_id, project=None):
    """D12: SubagentStop. The row this agent was running moves to returned —
    a crashed or killed worker lands here too, which is right: nobody is on
    it and the lead has to look. No board.json, or no row of this agent in
    'running', is a no-op."""
    j, _ = _paths(project)
    if not j.exists():
        return None
    return mutate(op_worker_stop, project=project, agent_id=agent_id)


def forget(ids, project=None, before=None, not_session=None):
    """Close out workers that will never report back.

    A killed or cancelled agent fires no SubagentStop, so its start sits
    outstanding until the stale age-out — far too long when the user cancelled
    minutes ago. This writes the missing close, rather than editing history.

    D1/I7: on SessionStart, restore.sh wants to close out ids from BEFORE this
    session without touching ids the current session itself just started —
    `before` narrows by each id's latest start/resume timestamp, `not_session`
    by whether that line's session= token matches the running session. Both
    combine (AND) with each other and with `ids == ["all"]`.
    """
    lg = ledger(project)
    targets = lg["outstanding"] + lg["abandoned"] if ids in (["all"], "all") else list(ids)
    if before:
        targets = [a for a in targets if lg["started"].get(a, "") < before]
    if not_session:
        targets = [a for a in targets if lg["session"].get(a) != not_session]
    reason = "restart" if before else ("pre-session" if not_session else "cancelled by the lead")
    live = set(lg["outstanding"]) | set(lg["abandoned"])
    done = []
    f = root(project) / ".state" / "events.log"
    f.parent.mkdir(parents=True, exist_ok=True)
    with f.open("a") as fh:
        for a in targets:
            if a in live:
                fh.write(f"{now()}  cancel    id={a}  reason={reason}\n")
                done.append(a)
    # D2: a 'running' row whose worker just got cancelled here never reported
    # back, so the work must be redone — requeue it and say why. Skipped
    # entirely when there is no board (restore.sh runs forget at every
    # SessionStart; the events log can exist without a board.json).
    requeued = []
    j, _ = _paths(project)
    if done and j.exists():
        for a in done:
            row = mutate(op_requeue_lost, project=project, agent_id=a)
            if row is not None:
                requeued.append(row["id"])
    return {"forgotten": done, "still_outstanding": ledger(project)["outstanding"],
            "requeued": requeued}


def clean(project=None) -> dict:
    """D2/D7: drop every merged row and nothing else.

    No confirmation (D7): the rows it touches are finished, so nothing in
    flight is at risk, and a prompt on a routine tidy-up is one people learn
    to click through. next_id is NOT reset — ids stay unique for the life of
    the board, so a merged id is never handed out twice.

    The "How it was solved" section is rendered FROM the merged rows, so
    dropping the rows drops the section: render() already emits '## Done'
    only when there are merged rows and '### How it was solved' only when
    some of them carry notes, so no stripping logic is needed here.

    F4: the removed ids are also stripped from every surviving row's
    blocked_by, exactly as op_remove does it — a reference to a row that no
    longer exists can never be satisfied and strands the dependant for good.

    F10: the board is still validated after the cut, but only problems the cut
    INTRODUCED are reported. Validating the whole board would make clean refuse
    over a pre-existing fault it did not cause, and misattribute it in the
    bargain. The guarded case is a merged row acting as the blocked_by link
    that D8 relies on to let two open rows own the same path; note that
    _validate_detailed already rejects a merged row blocked by a non-merged
    one, so on any board `check` accepts such a chain cannot exist and this
    branch is unreachable. It is kept for the board this file defends against
    anyway: a hand-edited board.json.
    """
    with _board_lock(project):
        db = load(project)
        was = set(validate(db))
        gone = [t["id"] for t in db["tasks"] if t["state"] == "merged"]
        db["tasks"] = [t for t in db["tasks"] if t["state"] != "merged"]
        unblocked = _strip_blocked_by(db, set(gone))
        introduced = [p for p in validate(db) if p not in was]
        if introduced:
            raise ValueError("refused — cleaning would introduce board problems:\n  "
                             + "\n  ".join(introduced))
        save(db, project)
        return {"cleaned": gone, "removed": len(gone), "open": summary(db)["open"],
                "next_id": db["next_id"], "unblocked": unblocked}


def drop_report(project=None) -> dict:
    """D3/D10/D12: what `drop` is about to destroy, gathered BEFORE it acts.

    Open rows, the worker ids `status` calls working/stuck (outstanding +
    abandoned — D10: workers still being out is never a reason to refuse; a
    stuck worker is exactly when you reach for a reset), and whether a plan is
    active. The active-plan pointer is read the same way check_plan reads it.

    F2: 'unreadable' says the board file exists but did not parse, so the row
    counts below are load()'s empty-board fallback and mean nothing. The lead
    turns this report into a yes/no question for a user; it must never answer
    'nothing is at stake' when the truth is 'we cannot tell'.
    F11: 'exists' is False when there is no board at all — drop then has
    nothing to do and must create nothing.
    """
    j, _ = _paths(project)
    exists, unreadable = j.exists(), False
    try:
        db = load(project, strict=True)
    except json.JSONDecodeError:
        db, unreadable = {"next_id": 1, "tasks": []}, True
    lg = ledger(project)
    ap = root(project) / ".state" / "active-plan"
    plan = ap.read_text().strip() if ap.exists() else ""
    return {"open": len([t for t in db["tasks"] if t["state"] != "merged"]),
            "merged": len([t for t in db["tasks"] if t["state"] == "merged"]),
            "exists": exists, "unreadable": unreadable,
            "workers": sorted(set(lg["outstanding"]) | set(lg["abandoned"])),
            "agents": lg["agents"], "active_plan": plan or None}


def print_drop_report(rep) -> None:
    """F1: the one place the pre-flight block is written. `drop` and
    `drop --dry-run` both print THIS and nothing else, so the two are
    byte-identical by construction rather than by two copies staying in sync."""
    print("drop — about to empty the board:")
    if rep["unreadable"]:
        print("  ! .state/board.json could not be parsed — the counts below are "
              "NOT trustworthy; the file may still hold rows as readable text")
    print(f"  {rep['open']} open task(s) and {rep['merged']} merged task(s) will be removed")
    if rep["workers"]:
        print("  workers still out (they will be stopped; their worktrees are NOT "
              "touched): " +
              ", ".join(f"{a} ({rep['agents'].get(a, '?')})" for a in rep["workers"]))
    else:
        print("  no workers out")
    if rep["active_plan"]:
        print(f"  plan ACTIVE: {rep['active_plan']}")
        print("  ! the plan's board rows go with the board; .state/active-plan is left "
              "alone, so `check` flags every step as missing and the gate BLOCKS "
              "every turn from ending until the plan is re-boarded or archived "
              "(plan-archive.sh --abandon)")
    else:
        print("  no active plan")


def drop(project=None) -> dict:
    """D3: the troubleshooting reset — empty the board, open rows included.

    Order matters. The backup is written first (D3.1) so the safety net exists
    before anything is mutated, and a backup that fails aborts before anything
    is touched. F2: it is a BYTE COPY of board.json, not a re-serialisation of
    what load() made of it — load() swallows a JSONDecodeError and hands back
    an empty board, so re-serialising would write `{"next_id": 1, "tasks": []}`
    over the top of the one remaining copy of a damaged but salvageable file.
    The copy still lands through a tmp + os.replace so a reader never sees a
    half-written backup. Then tasks, next_id and the event ledger are reset and
    board.md is re-rendered, and the WORKTREES of the stopped workers are left
    completely alone; removing a worktree is a separate confirmation the lead
    handles in chat, never this script.

    The workers are reported, not cancel-evented: forget(["all"]) used to run
    here, but every effect of it was undone two steps later — its cancel lines
    were truncated with the ledger, its requeues were erased with the rows —
    except the id list, which drop_report already computes. Cutting it removes
    a lock re-entrancy dance (forget -> mutate -> _board_lock, which is why it
    had to run outside our lock) and a failure path where op_requeue_lost could
    raise AFTER the backup and the cancel events, leaving the drop half-done.

    F11: no board.json means there is nothing to drop and nothing is created —
    not the backup, not board.json, not board.md.

    D12: .state/active-plan is left alone. Silently clearing the pointer would
    strand the plan; the caller warns instead (see the CLI branch).
    """
    j, _m = _paths(project)
    if not j.exists():
        return {"dropped": 0, "stopped": [], "backup": None, "next_id": 1,
                "skipped": True}
    before = load(project)
    stopped = drop_report(project)["workers"]
    # 1. back up first — this is the safety net, so it lands before any mutation
    bak = j.with_name(j.name + ".dropped")
    tmp = bak.with_name(f"{bak.name}.tmp{os.getpid()}")
    shutil.copy2(j, tmp)
    os.replace(tmp, bak)
    with _board_lock(project):
        db = load(project)
        db["tasks"] = []                      # 2. empty the board
        db["next_id"] = 1                     # 3. a fresh board starts at 1
        save(db, project)                     # 5. board.md re-rendered by save()
    # 4. clear the event ledger. Written unconditionally: forget() used to
    # create events.log as a side effect and the truncate relied on that.
    _atomic_write(root(project) / ".state" / "events.log", "")
    return {"dropped": len(before["tasks"]), "stopped": stopped,
            "backup": str(bak), "next_id": 1, "skipped": False}


def summary(db):
    live = [t for t in db["tasks"] if t["state"] != "merged"]
    by = {}
    for t in live:
        by.setdefault(t["state"], []).append(t["id"])
    return {"open": len(live),
            "by_state": {k: v for k, v in sorted(by.items())},
            "tasks": live}


# ---- ledger -----------------------------------------------------------------

# Only for workers that started and never stopped at all — a killed or crashed
# agent fires no SubagentStop, so its start would otherwise sit outstanding
# forever. Live workers are tracked by id, not by clock, so this only needs to
# exceed the longest plausible real run. Observed: workers can run ~1.5h, so this
# is deliberately well clear of that.
LEDGER_STALE_MIN = 240


def _events(project=None):
    f = root(project) / ".state" / "events.log"
    if not f.exists():
        return []
    out = []
    for line in f.read_text(errors="replace").splitlines():
        parts = line.split(None, 1)
        # Only well-formed lines. A corrupt or hand-edited timestamp sorts
        # unpredictably against a real one and would skew every recency test.
        if len(parts) == 2 and re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", parts[0]):
            out.append((parts[0], parts[1]))
    return out


def ledger(project=None) -> dict:
    """Which workers are actually still out, by id — not by counting.

    Counting dispatches against returns breaks two ways: a resumed worker fires no
    dispatch, and a killed worker fires no return, so the count drifts permanently.
    Pairing start/resume against return by agent id is exact. The age-out only
    catches ids that never stopped at all.
    """
    live, seen, started, session = {}, {}, {}, {}
    disp = starts = 0
    recent = (datetime.datetime.now(datetime.timezone.utc)
              - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    for ts, rest in _events(project):
        # A dispatch carries no agent id — the id only exists once SubagentStart
        # fires. That leaves a short window where a worker is real but unpairable,
        # so recent unmatched dispatches count as pending.
        if ts >= recent:
            if rest.startswith("dispatch"):
                disp += 1
            elif rest.startswith("start"):
                starts += 1
    for ts, rest in _events(project):
        tok = dict(p.split("=", 1) for p in re.split(r"\s{2,}", rest.strip()) if "=" in p)
        aid = tok.get("id")
        if not aid:
            continue
        if rest.startswith(("start", "resume")):
            live[aid] = ts
            seen[aid] = tok.get("agent", seen.get(aid, "?"))
            started[aid] = ts                     # I7: latest start/resume, for forget --before
            session[aid] = tok.get("session")      # I7: its session=, for forget --not-session
        elif rest.startswith(("return", "cancel")):
            live.pop(aid, None)
            seen[aid] = tok.get("agent", seen.get(aid, "?"))
    cutoff = (datetime.datetime.now(datetime.timezone.utc)
              - datetime.timedelta(minutes=LEDGER_STALE_MIN)).strftime("%Y-%m-%dT%H:%M:%SZ")
    outstanding = {a: t for a, t in live.items() if t >= cutoff}
    abandoned = {a: t for a, t in live.items() if t < cutoff}
    pending = max(0, disp - starts)
    return {"outstanding": sorted(outstanding), "pending": pending,
            "abandoned": sorted(abandoned), "known": sorted(seen), "agents": seen,
            "started": started, "session": session}


# ---- MCP (stdio JSON-RPC, no dependencies) ----------------------------------

TOOLS = [
    {"name": "board_list",
     "description": "Read the teamlead task board: every unfinished task with its state, "
                    "agent, owned paths and branch. Call this before deciding what to do next.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "board_add",
     "description": "Add one or more tasks to the board. This is how a request gets decomposed "
                    "— call it before dispatching any worker. Refused if two unfinished tasks "
                    "would own overlapping paths.",
     "inputSchema": {"type": "object", "required": ["tasks"], "properties": {"tasks": {
         "type": "array", "items": {"type": "object", "required": ["task"], "properties": {
             "task": {"type": "string", "description": "What done looks like, one line."},
             "agent": {"type": "string", "description": "Worker type, e.g. tl-sonnet-high."},
             "owns": {"type": "array", "items": {"type": "string"},
                      "description": "Write scope. Omit for read-only tasks."},
             "plan": {"type": "string", "description": "Plan step id this implements, e.g. I2."},
             "blocked_by": {"type": "array", "items": {"type": "integer"}}}}}}}},
    {"name": "board_update",
     "description": "Update a task: state (queued/running/returned/merged/blocked), branch, "
                    "agent, owns, or notes. Set notes when merging to record HOW it was solved.",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {
         "id": {"type": "integer"},
         "state": {"type": "string", "enum": list(STATES)},
         "agent": {"type": "string"}, "branch": {"type": "string"},
         "owns": {"type": "array", "items": {"type": "string"}},
         "notes": {"type": "string", "description": "How it was solved. Recorded permanently."},
         "task": {"type": "string"},
         "worker": {"type": "string", "description": "Worker agent_id, set by worker-start."},
         "blocked_by": {"type": "array", "items": {"type": "integer"}}}}},
]


def _rpc(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _call(name, args):
    if name == "board_list":
        return summary(load())
    if name == "board_add":
        _refuse_if_worker()                       # belt-and-braces: board-fence.sh already fences this
        proj = _write_project(None)
        with _board_lock(proj):                    # D5: this is the lead's primary write path too
            added = []
            db = load(proj)
            for spec in args.get("tasks", []):
                added.append(op_add(db, **spec))
            problems = validate(db)
            if problems:
                raise ValueError("refused — the board would be invalid:\n  " + "\n  ".join(problems))
            save(db, proj)
        return {"added": added, "open": summary(db)["open"]}
    if name == "board_update":
        _refuse_if_worker()                       # belt-and-braces: board-fence.sh already fences this
        proj = _write_project(None)
        t = mutate(op_update, project=proj, **args)
        return {"updated": t}
    raise KeyError(f"unknown tool {name}")


def serve():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        m, rid = req.get("method"), req.get("id")
        try:
            if m == "initialize":
                res = {"protocolVersion": "2024-11-05",
                       "capabilities": {"tools": {}},
                       "serverInfo": {"name": "teamlead-board", "version": "1.0.0"}}
            elif m == "tools/list":
                res = {"tools": TOOLS}
            elif m == "tools/call":
                p = req.get("params", {})
                out = _call(p.get("name"), p.get("arguments") or {})
                res = {"content": [{"type": "text", "text": json.dumps(out, indent=2)}]}
            elif m in ("notifications/initialized", "notifications/cancelled"):
                continue
            else:
                if rid is None:
                    continue
                _rpc({"jsonrpc": "2.0", "id": rid,
                      "error": {"code": -32601, "message": f"method not found: {m}"}})
                continue
            if rid is not None:
                _rpc({"jsonrpc": "2.0", "id": rid, "result": res})
        except Exception as e:                      # surface refusals to the agent
            if rid is not None:
                _rpc({"jsonrpc": "2.0", "id": rid,
                      "result": {"content": [{"type": "text", "text": f"ERROR: {e}"}],
                                 "isError": True}})


# ---- CLI --------------------------------------------------------------------

def main(argv):
    if "--mcp" in argv:
        return serve()
    if not argv:
        print(__doc__); return 1
    cmd, rest = argv[0], argv[1:]
    kw, proj, pos = {}, None, []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a.startswith("--"):
            k = a[2:].replace("-", "_")
            # F1: a valueless flag (--dry-run) must NOT eat the token after it.
            # The old unconditional i += 2 swallowed whatever followed, so
            # `drop --dry-run --project X` silently lost --project and fell
            # back to cwd resolution.
            took = i + 1 < len(rest) and not rest[i + 1].startswith("--")
            v = rest[i + 1] if took else "true"
            if k == "project":
                proj = v
            elif k == "owns":
                kw[k] = _norm_owns(v)
            elif k == "id":
                # worker-start/-stop take a string agent id (e.g. "ac82e6a6..."),
                # every other command's --id is a board task id (int).
                kw[k] = v if cmd in ("worker-start", "worker-stop") else int(v)
            elif k == "board":
                kw[k] = int(v)
            elif k == "blocked_by":               # F17 item 5: was landing as a raw string
                kw[k] = [int(x) for x in v.split(",") if x.strip()]
            else:
                kw[k] = v
            i += 2 if took else 1
        else:
            pos.append(a)
            i += 1
    if cmd == "list":
        print(json.dumps(summary(load(proj)), indent=2))
    elif cmd == "add":
        _refuse_if_worker()
        proj = _write_project(proj)
        print(json.dumps(mutate(op_add, project=proj, **kw), indent=2))
    elif cmd == "update":
        _refuse_if_worker()
        proj = _write_project(proj)
        if kw.get("id") is None:
            print("usage: board.py update --id N [--state s] [--branch b] [--agent a] "
                 "[--owns p,...] [--notes n] [--worker w]", file=sys.stderr)
            return 1
        print(json.dumps(mutate(op_update, project=proj, **kw), indent=2))
    elif cmd == "remove":
        _refuse_if_worker()
        proj = _write_project(proj)
        rid = pos[0] if pos else kw.get("id")
        if rid is None:
            print("usage: board.py remove <id>", file=sys.stderr); return 1
        print(json.dumps(mutate(op_remove, project=proj, id=rid), indent=2))
    elif cmd == "clean":
        _refuse_if_worker()
        proj = _write_project(proj)
        res = clean(proj)
        ids = ", ".join(f"#{i}" for i in res["cleaned"]) or "none"
        print(f"cleaned {res['removed']} merged task(s): {ids}")
        print(f"  {res['open']} open task(s) left, next_id still {res['next_id']}")
    elif cmd == "drop":
        # D5: the yes/no belongs to the lead (AskUserQuestion in chat), not to
        # the script — no stdin prompt and no --yes flag, matching remove/forget,
        # neither of which prompts either. What the script owes the lead is an
        # honest report BEFORE it acts, which is what this prints.
        # F1: --dry-run prints that report and stops. The lead's D3
        # confirmation names how many open rows go, which workers stop and
        # whether a plan is active — facts only this report holds, so there
        # has to be a way to get them without the destruction they describe.
        _refuse_if_worker()
        proj = _write_project(proj)
        dry = "dry_run" in kw
        rep = drop_report(proj)
        if not rep["exists"]:
            # F11: no board to drop — and drop must not CREATE one saying so.
            print("drop — nothing to drop: this project has no board "
                  "(.state/board.json does not exist)")
            print("  no files were created")
            return 0
        print_drop_report(rep)
        if dry:
            print("  dry run — nothing was changed; run the same command without "
                  "--dry-run to do it")
            return 0
        res = drop(proj)
        print(f"dropped {res['dropped']} task(s); next_id reset to {res['next_id']}; "
              f"ledger cleared")
        if res["stopped"]:
            print("  stopped worker(s): " + ", ".join(res["stopped"]))
        print(f"  backup: {res['backup']}")
    elif cmd == "worker-start":
        # D12: hook-driven (SubagentStart/PostToolUse carry the worker's id in
        # the payload, not CLAUDE_AGENT_ID) — no _refuse_if_worker() here. Safe
        # to leave ungated: all this can do is move a row along its own
        # lifecycle through mutate, where D9/overlap validation still applies.
        proj = _write_project(proj)
        if kw.get("id") is None:
            print("usage: board.py worker-start --id A [--board N] [--branch B]",
                 file=sys.stderr)
            return 1
        res = worker_start(kw["id"], proj, board=kw.get("board"), branch=kw.get("branch"))
        print(json.dumps(res if res is not None else {"updated": None}, indent=2))
    elif cmd == "worker-stop":
        proj = _write_project(proj)                # D12: hook-driven, see worker-start above
        if kw.get("id") is None:
            print("usage: board.py worker-stop --id A", file=sys.stderr)
            return 1
        res = worker_stop(kw["id"], proj)
        print(json.dumps(res if res is not None else {"updated": None}, indent=2))
    elif cmd == "status":
        db, lg = load(proj), ledger(proj)
        live = [t for t in db["tasks"] if t["state"] != "merged"]
        print(f"teamlead — {len(live)} open task(s), {len(lg['outstanding'])} worker(s) working")
        for t in live:
            b = f" [{t['branch']}]" if t.get("branch") else ""
            print(f"  #{t['id']:<3} {t['state']:<9} {t['task'][:64]}{b}")
        if lg["outstanding"]:
            print("  workers still working: " +
                  ", ".join(f"{a} ({lg['agents'].get(a, '?')})" for a in lg["outstanding"]))
        if lg["abandoned"]:
            print(f"  abandoned worker ids (started, never stopped): {', '.join(lg['abandoned'])}")
        probs = validate(db) + check_git(db, proj) + check_plan(db, proj)
        for p_ in probs:
            print(f"  ! {p_}")
    elif cmd == "ledger":
        print(json.dumps(ledger(proj), indent=2))
    elif cmd == "forget":
        proj = _write_project(proj)
        print(json.dumps(forget(pos or ["all"], proj,
                                 before=kw.get("before"), not_session=kw.get("not_session")),
                          indent=2))
    elif cmd == "render":                       # re-render md from json
        with _board_lock(proj):                 # load->save must not race a mutate()
            db = load(proj)
            _, m = _paths(proj)
            if not db["tasks"] and m.exists() and _has_task_rows(m.read_text()):
                print("refused — board.json is missing or has no tasks, but board.md still "
                     "holds task rows; rendering now would overwrite them with an empty board. "
                     "Investigate board.json before re-rendering.", file=sys.stderr)
                return 1
            save(db, proj); print("rendered")
    elif cmd == "check":                        # drift + validity, for the Stop gate
        db = load(proj)
        probs = validate(db) + check_git(db, proj) + check_plan(db, proj)
        _, m = _paths(proj)
        if not m.exists():
            if db["tasks"]:
                probs.append("board.md is missing but board.json has tasks — it is generated. "
                             "Fix with: board.py render --project <dir>  (and make changes "
                             "through the board tools, not by editing board.md)")
        elif m.read_text() != render(db):
            probs.append("board.md has drifted from board.json — it is generated. "
                         "Fix with: board.py render --project <dir>  (and make changes "
                         "through the board tools, not by editing board.md)")
        if probs:
            print("\n".join("  - " + p for p in probs)); return 1
    else:
        print(f"unknown command {cmd}")
        print("commands: add, update, remove, list, status, check, render, clean, "
              "drop, forget, ledger, worker-start, worker-stop")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]) or 0)
    except (ValueError, KeyError, TypeError) as e:
        print(str(e).strip('"'), file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        # F12: an unwritable .state/ used to escape as a traceback, printed
        # right under drop's confirmation-shaped report — the lead could not
        # tell whether anything had happened. Every write here is atomic
        # (tmp + os.replace) and the backup lands before any mutation, so a
        # failed write leaves the board as it was; say so.
        print(f"{e} — aborted before any change; the board was not modified",
              file=sys.stderr)
        sys.exit(1)
