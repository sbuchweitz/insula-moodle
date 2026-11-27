# shellcheck shell=bash
# Building, swapping and restoring the Moodle code tree on the volume.
#
# The new tree is assembled NEXT TO the live one (.code-next) from this image's
# pristine copy plus the site's add-on plugins, and only then swapped in with
# two renames on the same filesystem. Moodle's own upgrade instructions say the
# same: never copy a new release over the old one; move the old one aside, put
# the new one in place, carry config and add-on plugins across. The previous
# tree stays in backups/code-previous until the next upgrade, so a failed
# upgrade can put it back and an operator can always find it.
#
# The add-on plugin detection is ported from erseco/alpine-moodle's
# 010-sync-moodle-code.sh (MIT, Copyright (c) Ernesto Serrano; see
# THIRD_PARTY.md), which worked out the cases this has to get right: sub-plugins
# that sort before their parent, plugins removed from core, vendor directories
# that ship a version.php, and the move of the web root under public/ in 5.1.

# Translate a path inside an old tree into the image tree's layout: Moodle 5.1
# moved everything web-facing under public/, so mod/attendance from a 5.0 site
# belongs at public/mod/attendance in a 5.3 tree.
translate_layout_path() {
  local rel="$1"
  if [ -d "$MOODLE_SRC_DIR/public" ]; then
    case "$rel" in
      public|public/*) printf '%s\n' "$rel" ;;
      *) printf 'public/%s\n' "$rel" ;;
    esac
  else
    case "$rel" in
      public/*) printf '%s\n' "${rel#public/}" ;;
      *) printf '%s\n' "$rel" ;;
    esac
  fi
}

# Directories that carry a version.php without being Moodle plugins.
is_ignored_plugin_dir() {
  case "$1" in
    vendor|vendor/*|public/vendor|public/vendor/*) return 0 ;;
    node_modules|node_modules/*|*/node_modules|*/node_modules/*) return 0 ;;
    .git|.git/*|*/.git|*/.git/*) return 0 ;;
  esac
  return 1
}

# $plugin->version from a plugin's version.php, or empty.
plugin_version() {
  sed -n 's/.*\$plugin->version[[:space:]]*=[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$1/version.php" 2>/dev/null | head -n 1
}

# Plugins the image's release removed from core, as tree-relative paths
# (public/mod/assignment, …). A site's leftover copy of one is not an add-on.
deleted_core_plugins() {
  local lib="$MOODLE_SRC_DIR/lib"
  [ -f "$lib/plugins.json" ] && [ -f "$lib/components.json" ] || return 0
  php -r '
    $plugins = json_decode(file_get_contents($argv[1] . "/plugins.json"), true, 512, JSON_THROW_ON_ERROR);
    $components = json_decode(file_get_contents($argv[1] . "/components.json"), true, 512, JSON_THROW_ON_ERROR);
    foreach ($plugins["deleted"] ?? [] as $type => $names) {
        $directory = $components["plugintypes"][$type] ?? $components["deprecatedplugintypes"][$type] ?? null;
        if ($directory === null) { continue; }
        foreach ($names as $name) { echo "$directory/$name\n"; }
    }
  ' "$lib"
}

# list_addon_plugins OLD_TREE — print the tree-relative directories of the
# site's add-on plugins, parents before (and instead of) their sub-plugins.
# Also prints, prefixed with "keep ", plugins the image ships but the site has
# a NEWER copy of: putting the image's older copy back would make Moodle refuse
# to start with a "downgrade" error.
list_addon_plugins() {
  local old="$1" tmp
  # Under the lifecycle's WORK_DIR, which its EXIT trap removes.
  tmp="$(mktemp -d "${WORK_DIR:-/tmp}/addons.XXXXXX")"
  deleted_core_plugins > "$tmp/deleted"
  find "$old" -mindepth 2 -maxdepth 8 -type f -name version.php 2>/dev/null \
    | sed 's|/version\.php$||' | LC_ALL=C sort > "$tmp/dirs"
  : > "$tmp/taken"
  local pdir rel target covered p oldv newv
  while IFS= read -r pdir; do
    rel="${pdir#"$old"/}"
    case "$rel" in .|public) continue ;; esac
    is_ignored_plugin_dir "$rel" && continue
    # A sub-plugin of something already taken travels with its parent.
    covered=no
    while IFS= read -r p; do
      case "$rel" in "$p"/*) covered=yes; break ;; esac
    done < "$tmp/taken"
    [ "$covered" = yes ] && continue
    target="$(translate_layout_path "$rel")"
    if awk -v dir="$target" '$0 == dir || index(dir, $0 "/") == 1 { found = 1 } END { exit !found }' "$tmp/deleted"; then
      # stderr: stdout of this function is the plugin list itself.
      log "  dropping $rel: removed from Moodle core in this release" >&2
      continue
    fi
    if [ -d "$MOODLE_SRC_DIR/$target" ]; then
      oldv="$(plugin_version "$pdir")"
      newv="$(plugin_version "$MOODLE_SRC_DIR/$target")"
      if [ -n "$oldv" ] && [ -n "$newv" ] && [ "$(version_cmp "$oldv" "$newv")" -gt 0 ]; then
        printf 'keep %s\n' "$rel"
        printf '%s\n' "$rel" >> "$tmp/taken"
      fi
      continue
    fi
    printf '%s\n' "$rel"
    printf '%s\n' "$rel" >> "$tmp/taken"
  done < "$tmp/dirs"
  rm -rf "$tmp"
}

# stage_next_tree [OLD_TREE] — assemble .code-next: the image's code, the old
# tree's add-on plugins, our config.php. Ends with a completion marker so an
# interrupted swap can tell a finished staging tree from a half-copied one.
stage_next_tree() {
  local old="${1:-}" line rel target
  rm -rf "$NEXT_DIR"
  # cp as www-data: the copy is owned by www-data so Moodle's plugin installer
  # can write into it; modes and timestamps come from the image.
  cp -R --preserve=mode,timestamps,links "$MOODLE_SRC_DIR" "$NEXT_DIR"
  if [ -n "$old" ] && tree_present "$old"; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        keep\ *)
          rel="${line#keep }"
          target="$(translate_layout_path "$rel")"
          rm -rf "${NEXT_DIR:?}/${target:?}"
          cp -R --preserve=mode,timestamps,links "$old/$rel" "$NEXT_DIR/$target"
          warn "kept the site's own copy of $rel: it is newer than the one in this image"
          ;;
        *)
          rel="$line"
          target="$(translate_layout_path "$rel")"
          mkdir -p "$NEXT_DIR/$(dirname "$target")"
          rm -rf "${NEXT_DIR:?}/${target:?}"
          cp -R --preserve=mode,timestamps,links "$old/$rel" "$NEXT_DIR/$target"
          if [ "$target" = "$rel" ]; then
            log "  kept add-on plugin $rel"
          else
            log "  kept add-on plugin $rel -> $target (Moodle 5.1+ layout)"
          fi
          ;;
      esac
    done < <(list_addon_plugins "$old")
  fi
  write_config_stub "$NEXT_DIR"
  : > "$NEXT_DIR/.insula-staged"
}

# Swap .code-next in. code -> backups/code-previous, .code-next -> code.
swap_in_next() {
  mkdir -p "$BACKUP_DIR"
  rm -rf "$PREVIOUS_DIR"
  if [ -d "$CODE_DIR" ]; then
    mv "$CODE_DIR" "$PREVIOUS_DIR"
  fi
  mv "$NEXT_DIR" "$CODE_DIR"
  rm -f "$CODE_DIR/.insula-staged"
}

# Put the previous tree back after an upgrade that changed nothing.
restore_previous() {
  [ -d "$PREVIOUS_DIR" ] || return 1
  rm -rf "$MOODLE_ROOT/.code-failed"
  if [ -d "$CODE_DIR" ]; then
    mv "$CODE_DIR" "$MOODLE_ROOT/.code-failed"
  fi
  mv "$PREVIOUS_DIR" "$CODE_DIR"
  rm -rf "$MOODLE_ROOT/.code-failed"
}

# A pod killed between the two renames of swap_in_next leaves no code/ at all.
# Finish the swap if the staging tree was complete, otherwise undo it.
recover_interrupted_swap() {
  rm -rf "$MOODLE_ROOT/.code-failed"
  if [ -d "$NEXT_DIR" ]; then
    if [ -d "$CODE_DIR" ]; then
      log "removing an unfinished staging tree from an interrupted start"
      rm -rf "$NEXT_DIR"
    elif [ -f "$NEXT_DIR/.insula-staged" ]; then
      log "completing a code swap that was interrupted"
      mv "$NEXT_DIR" "$CODE_DIR"
      rm -f "$CODE_DIR/.insula-staged"
    else
      log "undoing a code swap that was interrupted before the new tree was complete"
      rm -rf "$NEXT_DIR"
      if [ -d "$PREVIOUS_DIR" ]; then
        mv "$PREVIOUS_DIR" "$CODE_DIR"
      fi
    fi
  fi
}

# Our config.php. Moodle requires it at <tree>/config.php; it holds no
# settings of its own. Site settings live in ../config-local.php (kept across
# upgrades, editable in the file manager) and the platform's settings in a file
# rendered from the environment on every start.
write_config_stub() {
  local tree="$1"
  rm -f "$tree/config.php"
  cp "$INSULA_MOODLE_SHARE/config.php" "$tree/config.php"
  # Moodle's core_configrw check wants config.php read-only.
  chmod 0444 "$tree/config.php"
}

config_is_stub() {
  [ -f "$1/config.php" ] && grep -q "$STUB_MARKER" "$1/config.php"
}
