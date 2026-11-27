<?php
// Turn an existing site's own config.php into config-local.php.
//
// When a site is moved onto this image, its config.php holds two kinds of
// settings: the ones the platform now owns (database, wwwroot, dataroot, …),
// which come from the deployment's environment, and the site's own (session
// handler, forced plugin settings, theme options, …), which must survive. This
// loads the file the way Moodle would — minus the call into lib/setup.php — and
// writes every setting the platform does not own to config-local.php as a
// plain value.
//
// Paths that pointed into the old data directory or code tree are rewritten to
// the new locations; anything computed at runtime (getenv(), constants) is
// frozen at its current value, which the header of the output says.
//
// Usage: php adopt-config.php OLD_CONFIG OLD_TREE NEW_ROOT OUTPUT

declare(strict_types=1);

if ($argc !== 5) {
    fwrite(STDERR, "usage: adopt-config.php OLD_CONFIG OLD_TREE NEW_ROOT OUTPUT\n");
    exit(2);
}
[, $oldconfig, $oldtree, $newroot, $output] = $argv;

// Settings the platform sets from the environment on every start. Copying
// them would only leave a stale, misleading duplicate in config-local.php.
const PLATFORM_OWNED = [
    'dbtype', 'dblibrary', 'dbhost', 'dbname', 'dbuser', 'dbpass', 'prefix', 'dboptions',
    'wwwroot', 'dataroot', 'admin', 'dirroot', 'libdir', 'sslproxy', 'reverseproxy',
    'routerconfigured', 'localcachedir', 'preventexecpath', 'pathtogs', 'pathtopdftoppm',
    'pathtounoconv', 'pathtodot', 'pathtodu', 'pathtopython', 'aspellpath', 'debugdisplay',
];

$source = file_get_contents($oldconfig);
if ($source === false) {
    fwrite(STDERR, "cannot read $oldconfig\n");
    exit(1);
}
// Drop the bootstrap: everything after it is Moodle itself, not configuration.
$source = preg_replace('/^\s*require(_once)?\s*\(?[^;]*lib\/setup\.php[\'"]\s*\)?\s*;.*$/ms', '', $source, 1, $found);
if (!$found) {
    fwrite(STDERR, "$oldconfig does not look like a Moodle config.php (no require of lib/setup.php)\n");
    exit(1);
}
$source = preg_replace('/^\s*<\?php/', '', $source, 1);

$CFG = null;
(static function () use ($source, $oldtree) {
    global $CFG;
    // __DIR__ inside eval() is not the file's directory; make the common
    // dirname(__FILE__) / __DIR__ references resolve to the old tree.
    $code = str_replace(['dirname(__FILE__)', '__DIR__'], [var_export($oldtree, true), var_export($oldtree, true)], $source);
    eval($code);
})();

if (!is_object($CFG)) {
    fwrite(STDERR, "$oldconfig did not define \$CFG\n");
    exit(1);
}

$olddata = isset($CFG->dataroot) ? rtrim((string) $CFG->dataroot, '/') : null;
$oldroot = rtrim($oldtree, '/');
$newdata = rtrim($newroot, '/') . '/moodledata';
$newcode = rtrim($newroot, '/') . '/code';

$relocate = static function ($value) use (&$relocate, $olddata, $oldroot, $newdata, $newcode) {
    if (is_string($value)) {
        if ($olddata !== null && $olddata !== '' && ($value === $olddata || str_starts_with($value, $olddata . '/'))) {
            return $newdata . substr($value, strlen($olddata));
        }
        if ($value === $oldroot || str_starts_with($value, $oldroot . '/')) {
            return $newcode . substr($value, strlen($oldroot));
        }
        return $value;
    }
    if (is_array($value)) {
        return array_map($relocate, $value);
    }
    return $value;
};

$kept = [];
$skipped = [];
foreach (get_object_vars($CFG) as $name => $value) {
    if (in_array($name, PLATFORM_OWNED, true)) {
        $skipped[] = $name;
        continue;
    }
    if ($value instanceof Closure || is_resource($value)) {
        fwrite(STDERR, "WARNING: \$CFG->$name cannot be carried over (not a plain value); see the original config.php\n");
        continue;
    }
    $kept[$name] = $relocate($value);
}

$out = "<?php\n"
    . "// Site-specific Moodle settings, kept across upgrades. Loaded by config.php\n"
    . "// before the platform's own settings, which always win for the database, the\n"
    . "// site URL, the data directory and the executable paths.\n"
    . "//\n"
    . "// Converted from the site's original config.php on " . gmdate('Y-m-d') . " (a copy is in\n"
    . "// backups/config.php.orig). Values computed in the original (getenv(), constants)\n"
    . "// were frozen at their value at that moment.\n\n";
foreach ($kept as $name => $value) {
    $out .= '$CFG->' . $name . ' = ' . var_export($value, true) . ";\n";
}
if ($kept === []) {
    $out .= "// (the original config.php had no settings beyond the platform's own)\n";
}

if (file_put_contents($output, $out) === false) {
    fwrite(STDERR, "cannot write $output\n");
    exit(1);
}
printf("kept %d setting(s): %s\n", count($kept), $kept === [] ? '-' : implode(', ', array_keys($kept)));
printf("left to the platform: %s\n", $skipped === [] ? '-' : implode(', ', $skipped));
// Read by the lifecycle: a site whose tables use another prefix than DB_PREFIX
// would look like an empty database.
printf("old_prefix=%s\n", isset($CFG->prefix) ? (string) $CFG->prefix : '');
