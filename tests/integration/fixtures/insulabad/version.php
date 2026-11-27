<?php
// Test fixture: depends on a plugin that does not exist, so Moodle's plugin
// check refuses the upgrade before it changes anything.
defined('MOODLE_INTERNAL') || die();
$plugin->component = 'local_insulabad';
$plugin->version = 2026010100;
$plugin->requires = 2025041400;
$plugin->dependencies = ['local_doesnotexist' => ANY_VERSION];
