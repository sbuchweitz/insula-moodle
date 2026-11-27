<?php
// Moodle configuration file. Managed by the insula-moodle image: it is
// rewritten on every start and on every upgrade, so do not edit it.
//
//  - Site-specific settings belong in config-local.php, in the folder above
//    code/ (next to moodledata/). That file is kept across upgrades. Anything
//    you set there is applied before the platform settings below.
//  - Database, site URL, data directory, executable paths and the other
//    platform settings come from the deployment's environment and are written
//    to /etc/insula-moodle/platform-config.php when the container starts.

unset($CFG);
global $CFG;
$CFG = new stdClass();

if (is_readable(__DIR__ . '/../config-local.php')) {
    require(__DIR__ . '/../config-local.php');
}
require('/etc/insula-moodle/platform-config.php');

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
