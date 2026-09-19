#!/usr/bin/env python3
"""Teamlead board: JSON is the truth, board.md is a rendering.

The board is the one durable artefact the model writes, so it is the one that can
be wrong. Making it a generated file removes that whole class of error: the model
never writes the table, it calls a mutation and the table is re-rendered.

Two front ends over the same core:
  CLI   board.py <cmd> ...            (hooks, tests, humans)
  MCP   board.py --mcp                (the agent, as tool calls)

Validation happens at WRITE time, so a bad board cannot exist rather than being
detected afterwards.
"""
from __future__ import annotations
import json, os, re, sys, datetime, pathlib, subprocess

STATES = ("queued", "running", "returned", "merged", "blocked")


def now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


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


def _paths(project=None):
    r = root(project)
    return r / ".state" / "board.json", r / "board.md"


def load(project=None) -> dict:
    j, _ = _paths(project)
    if j.exists():
        try:
            return json.loads(j.read_text())
        except json.JSONDecodeError:
            pass
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


def check_git(db: dict, project=None) -> list[str]:
    """The board validates itself; nothing asked git whether 'merged' was true.
    A task marked merged whose commits are not in HEAD is exactly the reported
    'work never merged back', and was undetectable."""
    proj = pathlib.Path(_main_checkout(project or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()))
    if _git(proj, "rev-parse", "--is-inside-work-tree") != "true":
        return []
    problems = []
    for t in db["tasks"]:
        br = (t.get("branch") or "").strip()
        if t["state"] != "merged" or not br or br in ("-", "—"):
            continue
        if _git(proj, "rev-parse", "--verify", "--quiet", br) is None:
            continue                      # branch already deleted after merging: fine
        n = _git(proj, "rev-list", "--count", f"HEAD..{br}")
        if n and n != "0":
            problems.append(
                f"task {t['id']} is marked merged but branch {br} has {n} commit(s) "
                f"not in HEAD — it was not actually merged back")
    return problems


def validate(db: dict) -> list[str]:
    """Only unfinished tasks can collide. Finished work shares freely."""
    problems, seen = [], set()
    live = [t for t in db["tasks"] if t["state"] not in ("merged",)]
    for t in db["tasks"]:
        if t["id"] in seen:
            problems.append(f"duplicate task id {t['id']}")
        seen.add(t["id"])
        if t["state"] not in STATES:
            problems.append(f"task {t['id']} has unknown state {t['state']!r}")
        if t["state"] in ("running", "returned") and not t.get("agent"):
            problems.append(f"task {t['id']} is {t['state']} with no agent")
    for i, a in enumerate(live):
        for b in live[i + 1:]:
            for pa in a["owns"]:
                for pb in b["owns"]:
                    if _overlap(pa, pb):
                        problems.append(
                            f"tasks {a['id']} and {b['id']} are both unfinished and own "
                            f"overlapping paths ({pa!r} vs {pb!r}) — two writers on one path")
    return problems


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


def save(db: dict, project=None) -> None:
    j, m = _paths(project)
    j.parent.mkdir(parents=True, exist_ok=True)
    j.write_text(json.dumps(db, indent=2) + "\n")
    m.write_text(render(db))


# ---- operations -------------------------------------------------------------

def op_add(db, task, agent=None, owns=None, plan=None, blocked_by=None, **_):
    t = {"id": db["next_id"], "task": task, "agent": agent,
         "owns": _norm_owns(owns), "state": "blocked" if blocked_by else "queued",
         "branch": None, "plan": plan, "blocked_by": blocked_by or [],
         "notes": None, "created": now(), "updated": now()}
    db["next_id"] += 1
    db["tasks"].append(t)
    return t


def op_update(db, id, **kw):
    for t in db["tasks"]:
        if t["id"] == int(id):
            for k in ("task", "agent", "state", "branch", "plan", "notes"):
                if kw.get(k) is not None:
                    t[k] = kw[k]
            if kw.get("owns") is not None:
                t["owns"] = _norm_owns(kw["owns"])
            if kw.get("blocked_by") is not None:
                t["blocked_by"] = kw["blocked_by"]
            t["updated"] = now()
            return t
    raise KeyError(f"no task with id {id}")


def mutate(fn, project=None, **kw):
    db = load(project)
    res = fn(db, **kw)
    problems = validate(db)
    if problems:
        raise ValueError("refused — the board would be invalid:\n  " + "\n  ".join(problems))
    save(db, project)
    return res


def forget(ids, project=None):
    """Close out workers that will never report back.

    A killed or cancelled agent fires no SubagentStop, so its start sits
    outstanding until the stale age-out — far too long when the user cancelled
    minutes ago. This writes the missing close, rather than editing history.
    """
    lg = ledger(project)
    targets = lg["outstanding"] + lg["abandoned"] if ids in (["all"], "all") else list(ids)
    live = set(lg["outstanding"]) | set(lg["abandoned"])
    done = []
    f = root(project) / ".state" / "events.log"
    f.parent.mkdir(parents=True, exist_ok=True)
    with f.open("a") as fh:
        for a in targets:
            if a in live:
                fh.write(f"{now()}  cancel    id={a}  reason=cancelled by the lead\n")
                done.append(a)
    return {"forgotten": done, "still_outstanding": ledger(project)["outstanding"]}


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
    live, seen = {}, {}
    disp = starts = 0
    recent = (datetime.datetime.now(datetime.UTC)
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
        elif rest.startswith(("return", "cancel")):
            live.pop(aid, None)
            seen[aid] = tok.get("agent", seen.get(aid, "?"))
    cutoff = (datetime.datetime.now(datetime.UTC)
              - datetime.timedelta(minutes=LEDGER_STALE_MIN)).strftime("%Y-%m-%dT%H:%M:%SZ")
    outstanding = {a: t for a, t in live.items() if t >= cutoff}
    abandoned = {a: t for a, t in live.items() if t < cutoff}
    pending = max(0, disp - starts)
    return {"outstanding": sorted(outstanding), "pending": pending,
            "abandoned": sorted(abandoned), "known": sorted(seen), "agents": seen}


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
         "blocked_by": {"type": "array", "items": {"type": "integer"}}}}},
]


def _rpc(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _call(name, args):
    if name == "board_list":
        return summary(load())
    if name == "board_add":
        added = []
        db = load()
        for spec in args.get("tasks", []):
            added.append(op_add(db, **spec))
        problems = validate(db)
        if problems:
            raise ValueError("refused — the board would be invalid:\n  " + "\n  ".join(problems))
        save(db)
        return {"added": added, "open": summary(db)["open"]}
    if name == "board_update":
        t = mutate(op_update, **args)
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
            v = rest[i + 1] if i + 1 < len(rest) and not rest[i + 1].startswith("--") else "true"
            if k == "project":
                proj = v
            elif k == "owns":
                kw[k] = _norm_owns(v)
            elif k == "id":
                kw[k] = int(v)
            else:
                kw[k] = v
            i += 2
        else:
            pos.append(a)
            i += 1
    if cmd == "list":
        print(json.dumps(summary(load(proj)), indent=2))
    elif cmd == "add":
        print(json.dumps(mutate(op_add, project=proj, **kw), indent=2))
    elif cmd == "update":
        print(json.dumps(mutate(op_update, project=proj, **kw), indent=2))
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
        probs = validate(db) + check_git(db, proj)
        for p_ in probs:
            print(f"  ! {p_}")
    elif cmd == "ledger":
        print(json.dumps(ledger(proj), indent=2))
    elif cmd == "forget":
        print(json.dumps(forget(pos or ["all"], proj), indent=2))
    elif cmd == "render":                       # re-render md from json
        save(load(proj), proj); print("rendered")
    elif cmd == "check":                        # drift + validity, for the Stop gate
        db = load(proj)
        probs = validate(db) + check_git(db, proj)
        _, m = _paths(proj)
        if m.exists() and m.read_text() != render(db):
            probs.append("board.md has drifted from board.json — it is generated. "
                         "Fix with: board.py render --project <dir>  (and make changes "
                         "through the board tools, not by editing board.md)")
        if probs:
            print("\n".join("  - " + p for p in probs)); return 1
    else:
        print(f"unknown command {cmd}"); return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]) or 0)
    except (ValueError, KeyError) as e:
        print(str(e).strip('"'), file=sys.stderr)
        sys.exit(1)
