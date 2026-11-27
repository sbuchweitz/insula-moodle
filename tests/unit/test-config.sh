#!/usr/bin/env bash
# Unit tests for the environment validation (env.sh), the platform config
# renderer (render-config.php) and the converter for a site's own config.php
# (adopt-config.php). Needs bash and php, nothing else.
#
# Run from the repository root: tests/unit/test-config.sh
# shellcheck disable=SC2034 # rc and friends are read inside the check strings eval runs
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

# Run validate_env in a clean subshell with only the given variables set.
# Prints the errors; exit status is validate_env's.
run_validate() {
  env -i PATH="$PATH" "$@" bash -c '
    . "'"$lib"'/common.sh"; . "'"$lib"'/env.sh"
    validate_env 2>&1; rc=$?
    echo "DB_PORT=$DB_PORT DB_PREFIX=$DB_PREFIX WWWROOT=$MOODLE_WWWROOT BBB=${MOODLE_BBB_SERVER_URL:-} CRON=$MOODLE_CRON"
    exit $rc'
}
good=(DB_HOST=db DB_NAME=moodle DB_USER=moodle DB_PASSWORD=secret MOODLE_WWWROOT=https://learn.example.test)

echo "== env validation"
out="$(run_validate "${good[@]}")"; rc=$?
check "a minimal valid environment passes" '[ $rc -eq 0 ]'
check "MariaDB port defaults to 3306" 'grep -q "DB_PORT=3306" <<<"$out"'
check "prefix defaults to mdl_" 'grep -q "DB_PREFIX=mdl_ " <<<"$out"'
check "cron defaults to on" 'grep -q "CRON=true" <<<"$out"'
out="$(run_validate "${good[@]}" DB_TYPE=pgsql)"
check "PostgreSQL port defaults to 5432" 'grep -q "DB_PORT=5432" <<<"$out"'
out="$(run_validate DB_TYPE=mssql)"; rc=$?
check "missing and invalid values all reported at once" '[ $rc -ne 0 ] && [ "$(grep -c ERROR <<<"$out")" -ge 6 ]'
check "names the unsupported DB_TYPE" 'grep -q "DB_TYPE=.mssql. is not supported" <<<"$out"'
check "names each missing variable" 'grep -q "DB_HOST is required" <<<"$out" && grep -q "MOODLE_WWWROOT is required" <<<"$out"'
out="$(run_validate "${good[@]:0:4}" MOODLE_WWWROOT=https://learn.example.test/)"
check "trailing slash on the URL is dropped" 'grep -q "WWWROOT=https://learn.example.test " <<<"$out"'
out="$(run_validate "${good[@]:0:4}" "MOODLE_WWWROOT=learn.example.test")"; rc=$?
check "URL without a scheme refused" '[ $rc -ne 0 ] && grep -q "MOODLE_WWWROOT=" <<<"$out"'
out="$(run_validate "${good[@]:0:4}" "MOODLE_WWWROOT=https://x.example.test/?a=1")"; rc=$?
check "URL with a query string refused" '[ $rc -ne 0 ]'
out="$(run_validate "${good[@]}" DB_PREFIX=mdl_too_long_)"; rc=$?
check "prefix over 10 characters refused" '[ $rc -ne 0 ] && grep -q "at most 10" <<<"$out"'
out="$(run_validate "${good[@]}" DB_PREFIX=Mdl_)"; rc=$?
check "upper-case prefix refused" '[ $rc -ne 0 ]'
out="$(run_validate "${good[@]}" DB_PREFIX=m2_)"; rc=$?
check "a custom prefix like m2_ accepted" '[ $rc -eq 0 ] && grep -q "DB_PREFIX=m2_ " <<<"$out"'
out="$(run_validate "${good[@]}" MOODLE_BBB_SERVER_URL=https://bbb.example.test/bigbluebutton)"; rc=$?
check "BBB URL without the secret refused" '[ $rc -ne 0 ] && grep -q "MOODLE_BBB_SHARED_SECRET is required" <<<"$out"'
out="$(run_validate "${good[@]}" MOODLE_BBB_SERVER_URL=https://bbb.example.test/bigbluebutton MOODLE_BBB_SHARED_SECRET=s)"; rc=$?
check "BBB pin accepted, trailing slash added" '[ $rc -eq 0 ] && grep -q "BBB=https://bbb.example.test/bigbluebutton/ " <<<"$out"'
out="$(run_validate "${good[@]}" MOODLE_CRON=False)"
check "MOODLE_CRON=False normalised to false" 'grep -q "CRON=false" <<<"$out"'
out="$(run_validate "${good[@]}" MOODLE_CRON=sometimes)"; rc=$?
check "MOODLE_CRON=sometimes refused" '[ $rc -ne 0 ]'
out="$(run_validate "${good[@]}" DB_HOST='db;rm -rf /')"; rc=$?
check "shell metacharacters in DB_HOST refused" '[ $rc -ne 0 ]'

run_install_validate() {
  env -i PATH="$PATH" "$@" bash -c '
    . "'"$lib"'/common.sh"; . "'"$lib"'/env.sh"
    validate_install_env 2>&1; rc=$?; echo "USER=$MOODLE_ADMIN_USER LANG=$MOODLE_LANG"; exit $rc'
}
out="$(run_install_validate MOODLE_ADMIN_PASSWORD=x MOODLE_ADMIN_EMAIL=admin@example.test)"; rc=$?
check "install settings: defaults for user and language" '[ $rc -eq 0 ] && grep -q "USER=admin LANG=en" <<<"$out"'
out="$(run_install_validate MOODLE_ADMIN_EMAIL=nope)"; rc=$?
check "install settings: missing password and bad e-mail refused" '[ $rc -ne 0 ] && grep -q "MOODLE_ADMIN_PASSWORD is required" <<<"$out" && grep -q "MOODLE_ADMIN_EMAIL=" <<<"$out"'

echo "== platform config rendering"
render() { # render OUT VAR=VALUE...
  local out="$1"; shift
  env -i PATH="$PATH" "$@" php "$lib/render-config.php" "$out"
}
load() { # load FILE — print the resulting $CFG as JSON
  php -r '$CFG = new stdClass(); require $argv[1]; echo json_encode($CFG);' "$1"
}
weird='pa"ss'"'"'w$rd\\ & <?php'
render "$work/p1.php" DB_HOST=db DB_NAME=moodle DB_USER=u "DB_PASSWORD=$weird" DB_PORT=3307 \
  MOODLE_WWWROOT=https://learn.example.test MOODLE_ROOT=/var/www/moodle
check "rendered file is valid PHP" 'php -l "$work/p1.php" >/dev/null'
cfg="$(load "$work/p1.php")"
jq_() { php -r '$c = json_decode($argv[1], true); $v = $c; foreach (explode(".", $argv[2]) as $k) { $v = $v[$k] ?? null; } echo $v === null ? "" : (is_bool($v) ? ($v ? "true" : "false") : (is_scalar($v) ? $v : json_encode($v)));' "$cfg" "$1"; }
check "a password with quotes, \$, backslash and <?php survives exactly" '[ "$(jq_ dbpass)" = "$weird" ]'
check "database settings from env" '[ "$(jq_ dbtype)" = mariadb ] && [ "$(jq_ dbhost)" = db ] && [ "$(jq_ dboptions.dbport)" = 3307 ]'
check "MariaDB gets the collation" '[ "$(jq_ dboptions.dbcollation)" = utf8mb4_unicode_ci ]'
check "https wwwroot turns on sslproxy" '[ "$(jq_ sslproxy)" = true ]'
check "dataroot under the volume" '[ "$(jq_ dataroot)" = /var/www/moodle/moodledata ]'
check "router configured" '[ "$(jq_ routerconfigured)" = true ]'
check "exec paths locked" '[ "$(jq_ preventexecpath)" = true ] && [ "$(jq_ pathtogs)" = /usr/bin/gs ] && [ "$(jq_ pathtounoconv)" = /usr/bin/unoconv ]'
check "debug display forced off" '[ "$(jq_ debugdisplay)" = 0 ]'
check "no BBB pin without the variables" '[ "$(jq_ bigbluebuttonbn_server_url)" = "" ]'
check "BBB task schedules set" 'grep -q "check_dismissed_recordings" <<<"$cfg"'
render "$work/p2.php" DB_TYPE=pgsql DB_HOST=pg DB_NAME=m DB_USER=u DB_PASSWORD=p MOODLE_WWWROOT=http://localhost:8080 \
  MOODLE_BBB_SERVER_URL=https://bbb.example.test/bigbluebutton/ MOODLE_BBB_SHARED_SECRET=sec
cfg="$(load "$work/p2.php")"
check "pgsql: port 5432, no MySQL collation" '[ "$(jq_ dboptions.dbport)" = 5432 ] && [ "$(jq_ dboptions.dbcollation)" = "" ]'
check "http wwwroot leaves sslproxy off" '[ "$(jq_ sslproxy)" = false ]'
check "BBB pinned when both variables are set" '[ "$(jq_ bigbluebuttonbn_server_url)" = https://bbb.example.test/bigbluebutton/ ] && [ "$(jq_ bigbluebuttonbn_shared_secret)" = sec ]'
check "rendered file is not world-readable (it holds the DB password)" '[ "$(stat -c %a "$work/p2.php")" = 640 ]'
# A schedule the site set in config-local.php wins over the platform default.
php -r '$CFG = new stdClass(); $CFG->scheduled_tasks = ["\\mod_bigbluebuttonbn\\task\\check_pending_recordings" => ["schedule" => "*/5 * * * *"]]; require $argv[1]; echo $CFG->scheduled_tasks["\\mod_bigbluebuttonbn\\task\\check_pending_recordings"]["schedule"], "|", count($CFG->scheduled_tasks);' "$work/p2.php" > "$work/sched"
check "site's own task schedule wins, platform default still added" '[ "$(cat "$work/sched")" = "*/5 * * * *|2" ]'

echo "== converting a site's own config.php"
mkdir -p "$work/old/moodle"
cat > "$work/old/moodle/config.php" <<'PHP'
<?php  // Moodle configuration file
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'old-db';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodle';
$CFG->dbpass    = 'oldpass';
$CFG->prefix    = 'm2_';
$CFG->dboptions = array('dbpersist' => 0, 'dbport' => 3306, 'dbcollation' => 'utf8mb4_unicode_ci');
$CFG->wwwroot   = 'https://old.example.test';
$CFG->dataroot  = '/var/www/html/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;
$CFG->session_handler_class = '\core\session\database';
$CFG->forced_plugin_settings = ['theme_boost' => ['brandcolor' => '#123456']];
$CFG->tempdir = '/var/www/html/moodledata/temp';
$CFG->customscripts = __DIR__ . '/customscripts';
$CFG->debugdisplay = 1;
$CFG->pathtogs = '/usr/local/bin/gs';
require_once(__DIR__ . '/lib/setup.php');
// There is no php closing tag in this file,
PHP
php "$lib/adopt-config.php" "$work/old/moodle/config.php" "$work/old/moodle" /var/www/moodle "$work/local.php" > "$work/adopt.out" 2>&1; rc=$?
check "converter succeeds" '[ $rc -eq 0 ]'
check "reports the old prefix" 'grep -q "^old_prefix=m2_$" "$work/adopt.out"'
check "output is valid PHP" 'php -l "$work/local.php" >/dev/null'
cfg="$(php -r '$CFG = new stdClass(); require $argv[1]; echo json_encode($CFG);' "$work/local.php")"
check "platform-owned settings left out" '[ "$(jq_ dbhost)" = "" ] && [ "$(jq_ wwwroot)" = "" ] && [ "$(jq_ dataroot)" = "" ] && [ "$(jq_ pathtogs)" = "" ] && [ "$(jq_ debugdisplay)" = "" ] && [ "$(jq_ prefix)" = "" ]'
check "site settings kept" '[ "$(jq_ session_handler_class)" = "\\core\\session\\database" ] && [ "$(jq_ forced_plugin_settings.theme_boost.brandcolor)" = "#123456" ]'
check "directorypermissions kept (octal 0777 = 511)" '[ "$(jq_ directorypermissions)" = 511 ]'
check "path into the old data dir moved to the new one" '[ "$(jq_ tempdir)" = /var/www/moodle/moodledata/temp ]'
check "path into the old code tree moved to code/" '[ "$(jq_ customscripts)" = /var/www/moodle/code/customscripts ]'
printf '<?php\n$x = 1;\n' > "$work/notconfig.php"
php "$lib/adopt-config.php" "$work/notconfig.php" "$work/old/moodle" /var/www/moodle "$work/x.php" > "$work/adopt2.out" 2>&1; rc=$?
check "a file that is not a Moodle config.php is refused" '[ $rc -ne 0 ] && grep -q "does not look like a Moodle config.php" "$work/adopt2.out"'

echo
echo "config: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
