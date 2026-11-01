#!/usr/bin/env python3
"""Which part of the plan is the lead working on right now?  One parser, two readers:
gate.sh (the stage 5 -> 6 check) and state.sh (the `phase:` / `next:` lines).

    plan-scope.py <board.py> <project> <plan-file> <phase-accepted-file> <mode> [stage]

modes
  check  prints "yes" when every I<n> step of the CURRENT scope is boarded and merged,
         else "no". The scope is the current phase, or the whole table when it has no
         phase rows. A table with no I<n> step at all has nothing to wait for: "yes".
  snap   records the steps that are merged right now into <phase-accepted-file>
         (called while the header sits at stage 6 or 7 — see gate.sh).
  info   prints  total|idx|label|nextlabel|steps
         total      number of phases (0 when the table has no phase rows)
         idx        1-based position of the scope phase
         label      the phase row's label ("A"); the number when it has none
         nextlabel  the phase after it, empty for the last phase
         steps      the scope's step range ("I1–I10", or just "I3" for one step)
         For stage 6/7 the scope is the phase UNDER TEST (the last fully merged one):
         once a phase is recorded as accepted the plain "current phase" has already
         moved on to the next one, which is not what the header is about.

It reads the wave table with board.py's own regexes (_PHASE_RE/_STEP_RE), the same
ones check_plan uses — not a second parser.
"""
import importlib.util
import pathlib
import sys

bpy, proj, plan, accf, mode = sys.argv[1:6]
stage = sys.argv[6] if len(sys.argv) > 6 else ""
spec = importlib.util.spec_from_file_location("board", bpy)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

states = {}
for t in b.load(proj)["tasks"]:
    if t.get("plan"):
        states.setdefault(t["plan"], []).append(t["state"])
merged = {i for i, st in states.items() if all(x == "merged" for x in st)}
acc_path = pathlib.Path(accf)
try:
    accepted = set(acc_path.read_text().split())
except OSError:
    accepted = set()

if mode == "snap":
    acc_path.write_text(" ".join(sorted(accepted | merged)) + "\n")
    sys.exit(0)

groups, cur, phased = [], None, False
for line in pathlib.Path(plan).read_text(errors="replace").splitlines():
    if b._PHASE_RE.match(line):
        phased = True
        cells = [c.strip() for c in line.split("|")]
        cur = {"label": cells[2].strip("* ") if len(cells) > 2 else "", "steps": []}
        groups.append(cur)
        continue
    m = b._STEP_RE.match(line)
    if m:
        if cur is None:
            cur = {"label": "", "steps": []}
            groups.append(cur)
        cur["steps"].append(m.group(2))
groups = [g for g in groups if g["steps"]]
if not groups:
    print("yes" if mode == "check" else "0|0|||")
    sys.exit(0)

live = accepted & merged
idx = next((n for n, g in enumerate(groups) if any(i not in live for i in g["steps"])),
           len(groups) - 1)
if mode == "info" and stage in ("6", "7"):
    done = [n for n, g in enumerate(groups) if all(i in merged for i in g["steps"])]
    if done:
        idx = done[-1]

if mode == "check":
    print("yes" if all(i in merged for i in groups[idx]["steps"]) else "no")
else:
    def name(n):
        return groups[n]["label"] or str(n + 1)
    nxt = name(idx + 1) if idx + 1 < len(groups) else ""
    st = groups[idx]["steps"]
    rng = st[0] if len(st) == 1 else f"{st[0]}–{st[-1]}"
    print(f"{len(groups) if phased else 0}|{idx + 1}|{name(idx)}|{nxt}|{rng}")
