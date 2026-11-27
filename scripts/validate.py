#!/usr/bin/env python3
"""Check the catalog entry against releases.json and the rules Insula relies on.

The manifest is what the platform deploys (an image tag per version, the
upgrade paths, which settings a tenant can change), so a mistake here reaches
every site at the next catalog sync. Checked:

  - the JSON schema Insula's catalogs use (schema/manifest.schema.json), when
    the jsonschema module is installed;
  - every version has a releases.json entry and the image tag <IMAGE>:<version>;
  - exactly one default, the newest, matching the top-level version and image;
  - each version's upgradeFrom lists exactly the older versions of its line,
    so the Upgrade button offers every newer point release and nothing else;
  - versionLockMode is strict, so nothing upgrades without a click;
  - every configurable env var has a parameter and vice versa, and the
    generated admin password is not also configurable.

Usage: scripts/validate.py
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMAGE = "ghcr.io/sbuchweitz/insula-moodle"
errors = []


def err(msg):
    errors.append(msg)


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def line_of(v):
    return ".".join(v.split(".")[:2])


manifest = json.loads((ROOT / "moodle/manifest.json").read_text())
releases = json.loads((ROOT / "releases.json").read_text())["releases"]
catalog = json.loads((ROOT / "catalog.json").read_text())

try:
    import jsonschema  # type: ignore

    schema = json.loads((ROOT / "schema/manifest.schema.json").read_text())
    for e in jsonschema.Draft7Validator(schema).iter_errors(manifest):
        err(f"schema: {'/'.join(str(p) for p in e.path)}: {e.message}")
except ImportError:
    print("note: jsonschema not installed; schema check skipped")

if catalog.get("entries") != ["moodle"]:
    err("catalog.json must list exactly the moodle entry")
if manifest.get("versionLockMode") != "strict":
    err("versionLockMode must be strict: upgrades only when someone changes the version")

versions = [v["version"] for v in manifest.get("supportedVersions", [])]
if versions != sorted(versions, key=vkey):
    err(f"supportedVersions must be in ascending order: {versions}")
for v in manifest.get("supportedVersions", []):
    ver = v["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
        err(f"{ver}: versions are full Moodle release numbers (5.3.0, not 5.3)")
        continue
    if ver not in releases:
        err(f"{ver}: no releases.json entry (its checksum and plugins_ref)")
    images = [c["image"] for c in v["components"]]
    if images != [f"{IMAGE}:{ver}"]:
        err(f"{ver}: image must be {IMAGE}:{ver}, got {images}")
    older = sorted((o for o in versions if line_of(o) == line_of(ver) and vkey(o) < vkey(ver)), key=vkey)
    if sorted(v.get("upgradeFrom", []), key=vkey) != older:
        err(f"{ver}: upgradeFrom must be exactly the older {line_of(ver)} releases {older}, got {v.get('upgradeFrom', [])}")

defaults = [v["version"] for v in manifest.get("supportedVersions", []) if v.get("isDefault")]
if len(defaults) != 1:
    err(f"exactly one version must be isDefault, got {defaults}")
elif versions and defaults[0] != max(versions, key=vkey):
    err(f"the default must be the newest version ({max(versions, key=vkey)}), got {defaults[0]}")
elif manifest.get("version") != defaults[0]:
    err(f"top-level version {manifest.get('version')} must equal the default {defaults[0]}")
comps = manifest.get("components", [])
if defaults and (len(comps) != 1 or comps[0].get("image") != f"{IMAGE}:{defaults[0]}"):
    err(f"components[0].image must be the default version's image {IMAGE}:{defaults[0]}")

env = manifest.get("env_vars", {})
configurable = env.get("configurable", [])
param_keys = [p["key"] for p in manifest.get("parameters", [])]
if sorted(configurable) != sorted(param_keys):
    err(f"configurable env vars and parameters differ: only configurable {sorted(set(configurable) - set(param_keys))}, "
        f"only parameters {sorted(set(param_keys) - set(configurable))}")
if env.get("fixed"):
    err("env_vars.fixed must stay empty: a fixed value silently wins over the tenant's; put defaults in the image ENV")
if "MOODLE_ADMIN_PASSWORD" not in env.get("generated", []):
    err("MOODLE_ADMIN_PASSWORD must be generated")
if "MOODLE_ADMIN_PASSWORD" in configurable:
    err("MOODLE_ADMIN_PASSWORD is generated and cannot also be configurable")

for name, rel in releases.items():
    if name.startswith("_"):
        continue
    if not re.fullmatch(r"[0-9a-f]{64}", rel.get("sha256", "")):
        err(f"releases.json {name}: sha256 must be 64 hex characters")
    if not re.fullmatch(r"[0-9a-f]{40}", rel.get("plugins_ref", "")):
        # A moving ref (HEAD, a branch) would let a later plugin change alter
        # the code of an already-published tag.
        err(f"releases.json {name}: plugins_ref must be a full commit sha, got {rel.get('plugins_ref')!r}")

if errors:
    for e in errors:
        print(f"ERROR: {e}")
    sys.exit(1)
print(f"ok: {len(versions)} versions, default {defaults[0]}, {len(param_keys)} parameters")
