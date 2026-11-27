<?php
defined('MOODLE_INTERNAL') || die();
function xmldb_local_insulaprobe_upgrade($oldversion) {
    if ($oldversion < 2026020100) {
        upgrade_plugin_savepoint(true, 2026020100, 'local', 'insulaprobe');
    }
    return true;
}
