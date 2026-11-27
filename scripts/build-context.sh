#!/usr/bin/env bash
# Assemble the docker build context for one Moodle release and print the
# build arguments it needs.
#
# Usage: scripts/build-context.sh VERSION OUT_DIR
#
# plugins/ is taken from the commit releases.json records for VERSION (its
# plugins_ref), not from the working tree, so a rebuild of an existing tag
# bundles exactly the plugin code that tag shipped with. "HEAD" (only used
# before a release's first commit) means the working tree.
set -euo pipefail
version="${1:?usage: build-context.sh VERSION OUT_DIR}"
out="${2:?usage: build-context.sh VERSION OUT_DIR}"
repo="$(cd "$(dirname "$0")/.." && pwd)"

read -r sha ref < <(python3 - "$repo/releases.json" "$version" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1]))["releases"]
r = releases.get(sys.argv[2])
if r is None:
    sys.exit(f"{sys.argv[2]} is not in releases.json")
print(r["sha256"], r["plugins_ref"])
PY
)

rm -rf "$out"
mkdir -p "$out"
cp -a "$repo/Dockerfile" "$repo/rootfs" "$out/"
if [ "$ref" = "HEAD" ]; then
  cp -a "$repo/plugins" "$out/plugins"
else
  mkdir -p "$out/plugins"
  git -C "$repo" archive "$ref" plugins | tar -x -C "$out"
fi
printf 'MOODLE_VERSION=%s\nMOODLE_SHA256=%s\n' "$version" "$sha"
