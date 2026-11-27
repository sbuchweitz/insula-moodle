#!/usr/bin/env python3
"""Add a Moodle point release to releases.json and the catalog entry.

Usage: scripts/add-release.py VERSION SHA256 PLUGINS_REF [--releases-only]

The new version becomes the default; its upgradeFrom lists every older
release of the same line, and the older versions keep theirs. Nothing else in
the manifest changes. --releases-only records the release (so CI can build
it) without offering it in the catalog yet.

A new LTS line (say 5.7 after 5.3) is NOT added by this script: which 5.3
releases may upgrade to it, and whether anything else changes, is a decision
for a person, made in the manifest by hand.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMAGE = "ghcr.io/sbuchweitz/insula-moodle"


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def line_of(v):
    return ".".join(v.split(".")[:2])


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 3:
        sys.exit(__doc__)
    version, sha, ref = args
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit(f"not a Moodle release number: {version}")
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        sys.exit("sha256 must be 64 hex characters")

    releases_only = "--releases-only" in argv
    mpath = ROOT / "moodle/manifest.json"
    m = json.loads(mpath.read_text())
    versions = [v["version"] for v in m["supportedVersions"]]
    older = sorted((v for v in versions if line_of(v) == line_of(version) and vkey(v) < vkey(version)), key=vkey)
    # Every refusal comes before anything is written.
    if line_of(version) not in {line_of(v) for v in versions}:
        sys.exit(f"{version} starts a new line; add it to the manifest by hand")
    if not releases_only and version in versions:
        sys.exit(f"{version} is already in the manifest")
    if vkey(version) < vkey(max(versions, key=vkey)):
        sys.exit(f"{version} is older than a version already in the manifest; refusing to reorder history")

    rpath = ROOT / "releases.json"
    rel = json.loads(rpath.read_text())
    rel["releases"][version] = {"sha256": sha, "plugins_ref": ref}
    rel["releases"] = dict(sorted(rel["releases"].items(), key=lambda kv: vkey(kv[0])))
    rpath.write_text(json.dumps(rel, indent=2) + "\n")
    if releases_only:
        return
    for v in m["supportedVersions"]:
        v["isDefault"] = False
    m["supportedVersions"].append({
        "version": version,
        "isDefault": True,
        "components": [{"name": "moodle", "image": f"{IMAGE}:{version}"}],
        "upgradeFrom": older,
    })
    m["version"] = version
    m["components"][0]["image"] = f"{IMAGE}:{version}"
    mpath.write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
