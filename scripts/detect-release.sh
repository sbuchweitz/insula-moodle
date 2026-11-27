#!/usr/bin/env bash
# Print the newest released Moodle point release of a line and its checksum,
# when it is not in releases.json yet:  VERSION SHA256
# Prints nothing when releases.json is already up to date, or when the release
# is tagged but its download is not published yet (the next run picks it up).
#
# Usage: scripts/detect-release.sh LINE     e.g. 5.3
set -euo pipefail
line="${1:?usage: detect-release.sh LINE (e.g. 5.3)}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
major="${line%%.*}"
minor="${line#*.}"

# Release tags only (v5.3.1); never -beta/-rc tags.
latest="$(git ls-remote --tags --refs https://github.com/moodle/moodle.git "v${line}.*" \
  | sed -n "s#.*refs/tags/v\(${major}\.${minor}\.[0-9][0-9]*\)\$#\1#p" | sort -t. -k3,3n | tail -n 1)"
[ -n "$latest" ] || exit 0

if python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["releases"] else 1)' \
    "$repo/releases.json" "$latest"; then
  exit 0
fi

patch="${latest##*.}"
if [ "$patch" = 0 ]; then name="moodle-${line}.tgz"; else name="moodle-${latest}.tgz"; fi
stable="$(printf 'stable%d%02d' "$major" "$minor")"
sum="$(curl -fsSL --retry 3 "https://download.moodle.org/download.php/direct/${stable}/${name}.sha256" 2>/dev/null \
  | grep -oE '[0-9a-f]{64}' | head -n 1 || true)"
[ -n "$sum" ] || { echo "Moodle $latest is tagged but its download is not published yet" >&2; exit 0; }
printf '%s %s\n' "$latest" "$sum"
