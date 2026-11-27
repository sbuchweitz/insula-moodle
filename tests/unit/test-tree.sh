#!/usr/bin/env bash
# Unit tests for the code-tree logic (rootfs/usr/local/lib/insula-moodle/tree.sh):
# staging a new tree, keeping add-on plugins, the 5.1 public/ move, swapping and
# recovering an interrupted swap. Miniature trees, no docker, no database.
#
# The add-on cases follow erseco/alpine-moodle's tests/unit/test-sync-moodle-code.sh
# (MIT; see THIRD_PARTY.md), adapted to the stage-and-swap design.
#
# Run from the repository root: tests/unit/test-tree.sh
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
lib="$repo/rootfs/usr/local/lib/insula-moodle"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A miniature Moodle tree. layout=public (5.1+) or root (5.0).
seed_moodle() {
  local root="$1" layout="$2" version="$3" release="$4" web
  mkdir -p "$root"
  if [ "$layout" = public ]; then web="$root/public"; else web="$root"; fi
  mkdir -p "$web/mod/forum" "$web/mod/assign" "$web/theme/boost" "$root/lib"
  printf '<?php\n$version  = %s;\n$release  = '\''%s (Build: 1)'\'';\n' "$version" "$release" > "$web/version.php"
  printf '<?php $plugin->version = %s;\n' "$version" > "$web/mod/forum/version.php"
  printf '<?php $plugin->version = %s;\n' "$version" > "$web/mod/assign/version.php"
  printf '<?php $plugin->version = %s;\n' "$version" > "$web/theme/boost/version.php"
  printf '<?php // theme config %s\n' "$release" > "$web/theme/boost/config.php"
}

# Each case gets fresh image, volume and config dirs.
new_case() {
  rm -rf "$work/case"
  mkdir -p "$work/case/share" "$work/case/etc"
  export MOODLE_ROOT="$work/case/vol" MOODLE_SRC_DIR="$work/case/image" \
    INSULA_MOODLE_SHARE="$work/case/share" INSULA_MOODLE_ETC="$work/case/etc" WORK_DIR="$work/case"
  mkdir -p "$MOODLE_ROOT"
  cp "$repo/rootfs/usr/local/share/insula-moodle/config.php" "$INSULA_MOODLE_SHARE/config.php"
  # shellcheck source=/dev/null
  . "$lib/common.sh"
  # shellcheck source=/dev/null
  . "$lib/tree.sh"
  seed_moodle "$MOODLE_SRC_DIR" public 2026100501.00 5.3.1
  printf 'image-id\n' > "$MOODLE_SRC_DIR/.insula-code-id"
  # plugins.json/components.json the way 5.3 ships them (paths include public/).
  printf '{"standard":{},"deleted":{"assignment":["offline"],"block":["quiz_results"]}}\n' > "$MOODLE_SRC_DIR/lib/plugins.json"
  printf '{"plugintypes":{"mod":"public/mod","block":"public/blocks","assignment":"public/mod/assignment/type","local":"public/local","theme":"public/theme"},"subsystems":{},"deprecatedplugintypes":{}}\n' \
    > "$MOODLE_SRC_DIR/lib/components.json"
}

addon() { # addon TREE RELPATH VERSION
  mkdir -p "$1/$2"
  printf '<?php $plugin->version = %s;\n' "$3" > "$1/$2/version.php"
  printf 'marker %s\n' "$2" > "$1/$2/lib.php"
}

echo "== staging without an old tree"
new_case
stage_next_tree "" >/dev/null 2>&1
check "image files copied" '[ -f "$NEXT_DIR/public/mod/forum/version.php" ]'
check "code id copied with the tree" '[ "$(tree_code_id "$NEXT_DIR")" = image-id ]'
check "config.php stub written" 'config_is_stub "$NEXT_DIR"'
check "config.php is read-only" '[ "$(stat -c %a "$NEXT_DIR/config.php")" = 444 ]'
check "staging marker present" '[ -f "$NEXT_DIR/.insula-staged" ]'
swap_in_next
check "swap: code/ is the new tree" '[ "$(tree_code_id "$CODE_DIR")" = image-id ]'
check "swap: staging marker removed" '[ ! -f "$CODE_DIR/.insula-staged" ]'
check "swap: no .code-next left" '[ ! -e "$NEXT_DIR" ]'

echo "== add-on plugins from a 5.3 tree"
new_case
seed_moodle "$CODE_DIR" public 2026100500.00 5.3
addon "$CODE_DIR" public/mod/attendance 2026090100
addon "$CODE_DIR" "public/local/sp ace" 2026010100
addon "$CODE_DIR" "public/local/sp ace/sub/one" 2026010100
addon "$CODE_DIR" public/vendor/somepkg 1
printf 'stale core file\n' > "$CODE_DIR/public/mod/forum/removed_in_new_release.php"
printf '<?php // site config\n' > "$CODE_DIR/config.php"
stage_next_tree "$CODE_DIR" >/dev/null 2>&1
check "third-party plugin kept" '[ -f "$NEXT_DIR/public/mod/attendance/lib.php" ]'
check "plugin with a space in its name kept" '[ -f "$NEXT_DIR/public/local/sp ace/lib.php" ]'
check "its sub-plugin kept inside it" '[ -f "$NEXT_DIR/public/local/sp ace/sub/one/lib.php" ]'
check "parent not nested inside itself" '[ ! -e "$NEXT_DIR/public/local/sp ace/sp ace" ]'
check "vendor/ is not a plugin" '[ ! -e "$NEXT_DIR/public/vendor/somepkg" ]'
check "stale core file gone (fresh tree, not an overlay)" '[ ! -e "$NEXT_DIR/public/mod/forum/removed_in_new_release.php" ]'
check "core plugin comes from the image" 'grep -q 2026100501.00 "$NEXT_DIR/public/mod/forum/version.php"'
check "theme config.php comes from the image" 'grep -q "5.3.1" "$NEXT_DIR/public/theme/boost/config.php"'
check "site config.php replaced by the stub" 'config_is_stub "$NEXT_DIR"'
swap_in_next
check "previous tree kept in backups/code-previous" '[ -f "$PREVIOUS_DIR/config.php" ] && ! config_is_stub "$PREVIOUS_DIR"'
restore_previous
check "restore_previous puts the old tree back" '! config_is_stub "$CODE_DIR" && [ -f "$CODE_DIR/public/mod/forum/removed_in_new_release.php" ]'
check "restore_previous leaves no backup" '[ ! -e "$PREVIOUS_DIR" ] && [ ! -e "$MOODLE_ROOT/.code-failed" ]'

echo "== a 5.0 tree (no public/) moved onto a 5.3 image"
new_case
seed_moodle "$CODE_DIR" root 2025041400.00 5.0
addon "$CODE_DIR" mod/attendance 2025090100
addon "$CODE_DIR" mod/attendance/report/x 2025090100
addon "$CODE_DIR" blocks/quiz_results 2024010100
addon "$CODE_DIR" mod/assignment/type/offline 2024010100
addon "$CODE_DIR" theme/moove 2025010100
stage_next_tree "$CODE_DIR" >/dev/null 2>"$work/stderr"
check "plugin relocated under public/" '[ -f "$NEXT_DIR/public/mod/attendance/lib.php" ]'
check "not left at the old root path" '[ ! -e "$NEXT_DIR/mod/attendance" ]'
check "sub-plugin travels with its parent" '[ -f "$NEXT_DIR/public/mod/attendance/report/x/lib.php" ]'
check "add-on theme relocated" '[ -f "$NEXT_DIR/public/theme/moove/lib.php" ]'
check "plugin removed from core is dropped" '[ ! -e "$NEXT_DIR/public/blocks/quiz_results" ]'
check "sub-plugin of a removed type is dropped" '[ ! -e "$NEXT_DIR/public/mod/assignment/type/offline" ]'
check "dropping is logged on stderr, not mixed into the plugin list" 'grep -q "dropping blocks/quiz_results" "$work/stderr"'
check "core plugins of the old layout not copied" '[ ! -e "$NEXT_DIR/mod/forum" ] && [ ! -e "$NEXT_DIR/public/public" ]'

echo "== the site has a newer copy of a plugin the image bundles"
new_case
addon "$MOODLE_SRC_DIR" public/local/bbbrecordingsync 2026111800
seed_moodle "$CODE_DIR" public 2026100500.00 5.3
addon "$CODE_DIR" public/local/bbbrecordingsync 2026120100
stage_next_tree "$CODE_DIR" >/dev/null 2>"$work/stderr"
check "site's newer copy kept (no downgrade error)" 'grep -q 2026120100 "$NEXT_DIR/public/local/bbbrecordingsync/version.php"'
check "and said so" 'grep -q "kept the site.s own copy of public/local/bbbrecordingsync" "$work/stderr"'
new_case
addon "$MOODLE_SRC_DIR" public/local/bbbrecordingsync 2026111800
seed_moodle "$CODE_DIR" public 2026100500.00 5.3
addon "$CODE_DIR" public/local/bbbrecordingsync 2026010100
stage_next_tree "$CODE_DIR" >/dev/null 2>&1
check "older or equal copy: the image's wins" 'grep -q 2026111800 "$NEXT_DIR/public/local/bbbrecordingsync/version.php"'

echo "== interrupted swaps"
new_case
seed_moodle "$CODE_DIR" public 2026100500.00 5.3
stage_next_tree "$CODE_DIR" >/dev/null 2>&1
mkdir -p "$BACKUP_DIR" && mv "$CODE_DIR" "$PREVIOUS_DIR"   # killed between the two renames
recover_interrupted_swap >/dev/null
check "complete staging tree: swap finished" '[ "$(tree_code_id "$CODE_DIR")" = image-id ] && [ ! -e "$NEXT_DIR" ]'
new_case
seed_moodle "$CODE_DIR" public 2026100500.00 5.3
stage_next_tree "$CODE_DIR" >/dev/null 2>&1
rm -f "$NEXT_DIR/.insula-staged"                              # killed while copying
mkdir -p "$BACKUP_DIR" && mv "$CODE_DIR" "$PREVIOUS_DIR"
recover_interrupted_swap >/dev/null
check "incomplete staging tree: previous tree restored" '[ -z "$(tree_code_id "$CODE_DIR")" ] && [ -f "$CODE_DIR/public/version.php" ] && [ ! -e "$NEXT_DIR" ]'
new_case
seed_moodle "$CODE_DIR" public 2026100500.00 5.3
stage_next_tree "$CODE_DIR" >/dev/null 2>&1
recover_interrupted_swap >/dev/null                           # killed before any rename
check "leftover staging tree next to a live one is removed" '[ ! -e "$NEXT_DIR" ] && [ -z "$(tree_code_id "$CODE_DIR")" ]'

echo "== version helpers"
new_case
seed_moodle "$CODE_DIR" root 2025041400.05 5.0.4
check "core version of a 5.0 tree" '[ "$(tree_core_version "$CODE_DIR")" = 2025041400.05 ]'
check "release of a 5.0 tree" '[ "$(tree_release "$CODE_DIR")" = "5.0.4 (Build: 1)" ]'
check "version_cmp less" '[ "$(version_cmp 2025041400.05 2026100501.00)" = -1 ]'
check "version_cmp equal" '[ "$(version_cmp 2026100501.00 2026100501)" = 0 ]'
check "version_cmp greater (fractional part)" '[ "$(version_cmp 2026100501.01 2026100501.00)" = 1 ]'

echo
echo "tree: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
