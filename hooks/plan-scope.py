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

A thin wrapper: the phase logic lives in board.py's plan_progress(), the same function
check_plan (Stop-gate check 1b) and the statusline use — not a second parser.
"""
import importlib.util
import pathlib
import sys

bpy, proj, plan, accf, mode = sys.argv[1:6]
stage = sys.argv[6] if len(sys.argv) > 6 else ""
spec = importlib.util.spec_from_file_location("board", bpy)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

db = b.load(proj)
if mode == "snap":
    acc = b.read_accepted(accf) | b.plan_merged(db)
    pathlib.Path(accf).write_text(" ".join(sorted(acc)) + "\n")
    sys.exit(0)

p = b.plan_progress(db, proj, pathlib.Path(plan).read_text(errors="replace"), accf,
                    stage if mode == "info" else "")
if p["scope"] is None:
    print("yes" if mode == "check" else "0|0|||")
    sys.exit(0)

idx, groups, names = p["scope"], p["groups"], p["names"]
if mode == "check":
    print("yes" if all(i in p["merged"] for i in groups[idx]["steps"]) else "no")
else:
    nxt = names[idx + 1] if idx + 1 < len(groups) else ""
    st = groups[idx]["steps"]
    rng = st[0] if len(st) == 1 else f"{st[0]}–{st[-1]}"
    print(f"{len(groups) if p['phased'] else 0}|{idx + 1}|{names[idx]}|{nxt}|{rng}")
