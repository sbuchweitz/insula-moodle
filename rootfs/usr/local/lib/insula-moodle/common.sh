# shellcheck shell=bash
# shellcheck disable=SC2034 # the constants below are used by the scripts that source this file
# Shared paths and helpers for the insula-moodle lifecycle scripts.
#
# Every path can be overridden from the environment so the unit tests can run
# the same code against throwaway directories. Nothing in the catalog manifest
# exposes these: in the platform they are always the defaults below.

MOODLE_ROOT="${MOODLE_ROOT:-/var/www/moodle}"          # the deployment's volume
MOODLE_SRC_DIR="${MOODLE_SRC_DIR:-/usr/src/moodle}"    # this image's code, read-only
INSULA_MOODLE_ETC="${INSULA_MOODLE_ETC:-/etc/insula-moodle}"
INSULA_MOODLE_LIB="${INSULA_MOODLE_LIB:-/usr/local/lib/insula-moodle}"
INSULA_MOODLE_SHARE="${INSULA_MOODLE_SHARE:-/usr/local/share/insula-moodle}"

CODE_DIR="$MOODLE_ROOT/code"
DATA_DIR="$MOODLE_ROOT/moodledata"
BACKUP_DIR="$MOODLE_ROOT/backups"
LOCAL_CONFIG="$MOODLE_ROOT/config-local.php"
NEXT_DIR="$MOODLE_ROOT/.code-next"
PREVIOUS_DIR="$BACKUP_DIR/code-previous"
FAILED_MARKER="$BACKUP_DIR/UPGRADE-FAILED.txt"
IN_PROGRESS="$BACKUP_DIR/upgrade-in-progress.txt"
# Left by a failed upgrade (or install) next to UPGRADE-FAILED.txt. Deleting
# the marker while this stays is the request to try again.
INCOMPLETE="$BACKUP_DIR/upgrade-incomplete.txt"
# Written right before install_database.php, removed when it succeeds. Found at
# start, it means a fresh install was cut off (pod killed, node lost).
INSTALL_IN_PROGRESS="$BACKUP_DIR/install-in-progress.txt"
CODE_ID_FILE=".insula-code-id"
# Marks a config.php as ours. Anything without it is a site's own config.php,
# found when an existing site is moved onto this image.
STUB_MARKER="Managed by the insula-moodle image"

log() { printf '[insula-moodle] %s\n' "$*"; }
warn() { printf '[insula-moodle] WARNING: %s\n' "$*" >&2; }
die() {
  printf '[insula-moodle] ERROR: %s\n' "$*" >&2
  # Kubernetes copies this file into the container's terminated state, which is
  # what Insula shows as the deployment's error — the reason, not just "exit
  # code 1". It exists only under Kubernetes; the API caps it at 4 KiB.
  if [ -w /dev/termination-log ]; then
    printf '%s' "$*" | head -c 3800 > /dev/termination-log 2>/dev/null || true
  fi
  exit 1
}

# Echo the code id of a tree: the stamp the image wrote at build time. Empty
# when the tree has none (a site's own tree, or no tree at all).
tree_code_id() {
  local root="$1"
  if [ -f "$root/$CODE_ID_FILE" ]; then
    tr -d '[:space:]' < "$root/$CODE_ID_FILE"
  fi
}

# Path of the root version.php of a Moodle tree: <root>/version.php before 5.1,
# <root>/public/version.php from 5.1 on.
tree_version_php() {
  local root="$1"
  if [ -f "$root/public/version.php" ]; then
    printf '%s\n' "$root/public/version.php"
  elif [ -f "$root/version.php" ]; then
    printf '%s\n' "$root/version.php"
  fi
}

tree_present() {
  [ -n "$(tree_version_php "$1")" ]
}

# $version of a tree, e.g. 2026100501.00. Empty if unparseable.
tree_core_version() {
  local vp
  vp="$(tree_version_php "$1")"
  [ -n "$vp" ] || return 0
  sed -n 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$vp" | head -n 1
}

# $release of a tree, e.g. "5.3.1 (Build: 20261112)".
tree_release() {
  local vp
  vp="$(tree_version_php "$1")"
  [ -n "$vp" ] || return 0
  sed -n "s/^[[:space:]]*\$release[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$vp" | head -n 1
}

# Compare two Moodle $version numbers (YYYYMMDDXX.XX). Prints -1, 0 or 1.
version_cmp() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (a + 0 < b + 0) print -1; else if (a + 0 > b + 0) print 1; else print 0 }'
}
