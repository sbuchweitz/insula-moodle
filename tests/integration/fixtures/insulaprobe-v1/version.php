<?php
// Test fixture: an add-on plugin with its own table, so the integration tests
// can check that add-on code AND its data survive an upgrade or a move.
defined('MOODLE_INTERNAL') || die();
$plugin->component = 'local_insulaprobe';
$plugin->version = 2026010100;
$plugin->requires = 2025041400; // Moodle 5.0.
$plugin->maturity = MATURITY_STABLE;
$plugin->release = '1';
