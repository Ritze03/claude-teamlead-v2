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
import json, os, sys, datetime, pathlib

STATES = ("queued", "running", "returned", "merged", "blocked")


def now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def root(project: str | None = None) -> pathlib.Path:
    p = project or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    return pathlib.Path(p) / ".claude" / "teamlead"


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
        task = t["task"] + (f" — {t['plan']}" if t.get("plan") else "")
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


def summary(db):
    live = [t for t in db["tasks"] if t["state"] != "merged"]
    by = {}
    for t in live:
        by.setdefault(t["state"], []).append(t["id"])
    return {"open": len(live),
            "by_state": {k: v for k, v in sorted(by.items())},
            "tasks": live}


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
    kw, proj = {}, None
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
            i += 1
    if cmd == "list":
        print(json.dumps(summary(load(proj)), indent=2))
    elif cmd == "add":
        print(json.dumps(mutate(op_add, project=proj, **kw), indent=2))
    elif cmd == "update":
        print(json.dumps(mutate(op_update, project=proj, **kw), indent=2))
    elif cmd == "render":                       # re-render md from json
        save(load(proj), proj); print("rendered")
    elif cmd == "check":                        # drift + validity, for the Stop gate
        db = load(proj)
        probs = validate(db)
        _, m = _paths(proj)
        if m.exists() and m.read_text() != render(db):
            probs.append("board.md has drifted from board.json — it is generated; "
                         "re-render it and make changes through the board tools instead")
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
