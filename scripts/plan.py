#!/usr/bin/env python3
"""Decide which versions a build run rebuilds. Prints a JSON array.

Usage: scripts/plan.py [EXTRA_VERSION…]

Each line in the catalog entry gets its newest two point releases rebuilt:
the current one, and the one sites that have not clicked Upgrade yet are on.
Older tags are no longer rebuilt (they keep their last build), which is the
nudge to upgrade. EXTRA_VERSION adds versions on top — a new release found
by detect-release.sh, or versions given to a manual run.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def line_of(v):
    return ".".join(v.split(".")[:2])


manifest = json.loads((ROOT / "moodle/manifest.json").read_text())
versions = [v["version"] for v in manifest["supportedVersions"]]
by_line = {}
for v in versions:
    by_line.setdefault(line_of(v), []).append(v)
plan = set()
for vs in by_line.values():
    plan.update(sorted(vs, key=vkey)[-2:])
plan.update(a for a in sys.argv[1:] if a)
print(json.dumps(sorted(plan, key=vkey)))
