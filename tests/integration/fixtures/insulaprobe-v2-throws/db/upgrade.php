<?php
defined('MOODLE_INTERNAL') || die();
function xmldb_local_insulaprobe_upgrade($oldversion) {
    // Fails on purpose: the tests need an upgrade that breaks AFTER Moodle's
    // core upgrade has already changed the database.
    throw new coding_exception('insulaprobe: upgrade step failed on purpose');
}
