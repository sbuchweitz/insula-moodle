#!/usr/bin/env bash
# Integration tests: real Moodle images against real MariaDB/PostgreSQL
# servers, driven only through what an operator can do — start a version,
# restart it, change its settings, put files in its volume — and asserting
# what a user or operator would see.
#
# Usage: tests/integration/run.sh [TRACK…]   (default: all tracks)
#   IMG_OLD / IMG_NEW  the two images of consecutive point releases
#                      (default insula-moodle:5.3.0-local / :5.3.1-local)
# Tracks: install upgrade sticky undo interrupt inputs pgsql migrate office
# shellcheck disable=SC2034 # fp0, rc and friends are read inside the check strings eval runs
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/integration/lib.sh
. "$here/lib.sh"
LOGS="${LOGS:-$(mktemp -d)}"
trap cleanup_all EXIT
cleanup_all
net_up

OLD_ID="$(image_id "$IMG_OLD")"
NEW_ID="$(image_id "$IMG_NEW")"
printf 'images: %s (%s)  ->  %s (%s)\nlogs: %s\n' "$IMG_OLD" "${OLD_ID:0:12}" "$IMG_NEW" "${NEW_ID:0:12}" "$LOGS"

probe_install() { # probe_install NAME VOLUME FIXTURE — drop the probe plugin in and install it the way the admin UI would
  vol_put "$2" "$FIX/$3" /var/www/moodle/code/public/local/insulaprobe
  mcli "$1" admin/cli/upgrade.php --non-interactive >/dev/null
}

# ----------------------------------------------------------------------------
track_install() {
  section "install: fresh site on MariaDB, restart, settings"
  db_up db1 mariadb
  moodle_start m1 "$IMG_OLD" v1 db1
  wait_start m1 300; rc=$?; check "fresh install starts" '[ $rc -eq 0 ]'
  check "lifecycle installed a new site" 'logs m1 | grep -q "installed Moodle 5.3"'
  check "login page answers 200" '[ "$(mcurl m1 -o /dev/null -w "%{http_code}" "$WWWROOT/login/index.php")" = 200 ]'
  check "admin can log in with MOODLE_ADMIN_PASSWORD" 'login m1 admin "$ADMIN_PASS"'
  check "all of Moodle's status checks pass (incl. the router)" 'checks_ok m1'
  mphp m1 > "$LOGS/env-install.txt" 2>&1 <<'PHP'
require_once($CFG->libdir . '/environmentlib.php');
[$ok, $results] = check_moodle_environment(normalize_version($CFG->release), ENV_SELECT_RELEASE);
foreach ($results as $r) {
    if (!$r->getStatus() && $r->getLevel() === 'required') { echo "REQUIRED FAIL: ", $r->getPart(), " ", $r->getInfo(), "\n"; }
    if (!$r->getStatus()) { echo "NOT OK (", $r->getLevel(), "): ", $r->getPart(), " ", $r->getInfo(), "\n"; }
}
echo $ok ? "ENV OK\n" : "ENV FAIL\n";
PHP
  check "environment check: no required failures" 'grep -q "^ENV OK" "$LOGS/env-install.txt"'
  check "Composer libraries installed and optimised (Moodle's own checks)" '! grep -qiE "composer" "$LOGS/env-install.txt"'
  check "web service OpenAPI route answers 200 (needs the Composer libraries)" '[ "$(mcurl m1 -o /dev/null -w "%{http_code}" "$WWWROOT/api/rest/v2/openapi.json")" = 200 ]'
  check "Ghostscript path pinned" '[ "$(mcli m1 admin/cli/cfg.php --name=pathtogs)" = /usr/bin/gs ]'
  check "max_input_vars is 5000 for web requests" 'mcurl m1 -o /dev/null -w "%{http_code}" "$WWWROOT/login/index.php" >/dev/null && docker exec "$P-m1" php-fpm -i 2>/dev/null | grep -q "max_input_vars => 5000"'
  check "config.php is the read-only stub" 'vol_sh v1 "grep -q \"Managed by the insula-moodle image\" /var/www/moodle/code/config.php && [ \$(stat -c %a /var/www/moodle/code/config.php) = 444 ]"'
  check "config.php is outside the web root (not servable)" '[ "$(mcurl m1 "$WWWROOT/config.php" | wc -c)" -eq 0 ]'
  check "moodledata is not reachable over HTTP" '[ "$(mcurl m1 -o /dev/null -w "%{http_code}" "$WWWROOT/../moodledata/")" != 200 ]'

  # The admin changes things in Moodle's UI; a restart must keep all of it.
  mphp m1 <<'PHP'
$u = get_admin(); update_internal_user_password($u, 'Ch4nged!byadmin');
set_config('smtphosts', 'smtp.example.test:587');
set_config('supportemail', 'help@example.test');
PHP
  probe_install m1 v1 insulaprobe-v1
  msql db1 "INSERT INTO mdl_local_insulaprobe (note) VALUES ('survives everything')"
  moodle_start m1 "$IMG_OLD" v1 db1 -e MOODLE_ADMIN_PASSWORD=ignored-after-install -e MOODLE_SITE_NAME=Renamed
  wait_start m1 300
  check "restart on the same tag: nothing to do" 'logs m1 | grep -q "nothing to do"'
  check "restart does not dump or swap anything" '! logs m1 | grep -qE "dumping|assembling"'
  check "admin password changed in Moodle survives the restart" 'login m1 admin "Ch4nged!byadmin"'
  check "MOODLE_ADMIN_PASSWORD is ignored after install" '! login m1 admin "ignored-after-install"'
  check "SMTP setting made in Moodle survives the restart" '[ "$(mcli m1 admin/cli/cfg.php --name=smtphosts)" = smtp.example.test:587 ]'
  check "site name is install-only" '[ "$(msql db1 "SELECT fullname FROM mdl_course WHERE id=1")" != Renamed ]'
  check "add-on plugin installed through the CLI/UI is there" '[ "$(msql db1 "SELECT note FROM mdl_local_insulaprobe")" = "survives everything" ]'

  # Settings that come from the environment apply on restart; config-local.php
  # holds the site's own; the platform's always win.
  vol_sh v1 "printf '%s\n' '<?php' '\$CFG->noemailever = true;' '\$CFG->wwwroot = \"http://hijacked.example.test\";' '\$CFG->pathtogs = \"/bin/sh\";' > /var/www/moodle/config-local.php"
  moodle_start m1 "$IMG_OLD" v1 db1 -e MOODLE_BBB_SERVER_URL=https://bbb.example.test/bigbluebutton -e MOODLE_BBB_SHARED_SECRET=s3cret -e PHP_MEMORY_LIMIT=384M
  wait_start m1 300
  mphp m1 > "$LOGS/cfg.txt" 2>&1 <<'PHP'
echo "bbb=", $CFG->bigbluebuttonbn_server_url ?? '', "\n";
echo "bbb_locked=", isset($CFG->config_php_settings['bigbluebuttonbn_server_url']) ? 'yes' : 'no', "\n";
echo "noemailever=", !empty($CFG->noemailever) ? 'yes' : 'no', "\n";
echo "wwwroot=", $CFG->wwwroot, "\n";
echo "pathtogs=", $CFG->pathtogs, "\n";
echo "debugdisplay=", (int) $CFG->debugdisplay, "\n";
echo "sched=", $CFG->scheduled_tasks['\mod_bigbluebuttonbn\task\check_pending_recordings']['schedule'] ?? '', "\n";
PHP
  check "BBB server pinned from env, trailing slash added" 'grep -q "^bbb=https://bbb.example.test/bigbluebutton/$" "$LOGS/cfg.txt"'
  check "BBB setting is locked in the admin UI (defined in config.php)" 'grep -q "^bbb_locked=yes" "$LOGS/cfg.txt"'
  check "config-local.php setting applied" 'grep -q "^noemailever=yes" "$LOGS/cfg.txt"'
  check "config-local.php cannot override wwwroot" 'grep -q "^wwwroot=$WWWROOT$" "$LOGS/cfg.txt"'
  check "config-local.php cannot repoint an executable" 'grep -q "^pathtogs=/usr/bin/gs$" "$LOGS/cfg.txt"'
  check "debugdisplay forced off" 'grep -q "^debugdisplay=0" "$LOGS/cfg.txt"'
  check "BBB task schedule override present" 'grep -q "^sched=\*/15 \* \* \* \*" "$LOGS/cfg.txt"'
  check "PHP setting from env reaches PHP-FPM" 'docker exec "$P-m1" php-fpm -i 2>/dev/null | grep -q "memory_limit => 384M"'
  check "Moodle cron is running in the container" 'docker exec "$P-m1" sh -c "pgrep -f admin/cli/cron.php" >/dev/null'
  vol_sh v1 'rm -f /var/www/moodle/config-local.php'

  # An add-on dropped into code/ without finishing it in Moodle: the start
  # says so, and does not run the upgrade itself.
  vol_put v1 "$FIX/insulaprobe-v2-good" /var/www/moodle/code/public/local/insulaprobe
  moodle_start m1 "$IMG_OLD" v1 db1
  wait_start m1 300
  check "pending add-on upgrade is reported on start" 'logs m1 | grep -q "Moodle has a pending upgrade"'
  check "and left to the site admin (not run on a restart)" '[ "$(msql db1 "SELECT value FROM mdl_config_plugins WHERE plugin=\"local_insulaprobe\" AND name=\"version\"")" = 2026010100 ]'
}

# ----------------------------------------------------------------------------
track_upgrade() {
  section "upgrade: point release, refusal before any change, downgrade"
  db_up db2 mariadb
  moodle_start m2 "$IMG_OLD" v2 db2
  wait_start m2 300 || { bad "5.3.0 site did not install"; return; }
  probe_install m2 v2 insulaprobe-v1
  msql db2 "INSERT INTO mdl_local_insulaprobe (note) VALUES ('kept across upgrade')"
  vol_put v2 "$FIX/insulabad" /var/www/moodle/code/public/local/insulabad
  docker stop "$P-m2" >/dev/null

  local fp0 fp1
  fp0="$(fingerprint db2)"
  moodle_start m2 "$IMG_NEW" v2 db2
  wait_start m2 300; rc=$?; check "upgrade blocked by a missing plugin dependency: start fails" '[ $rc -eq 1 ] && [ "$(exit_code m2)" != 0 ]'
  check "says Moodle refused before changing anything" 'logs m2 | grep -q "refused the upgrade to 5.3.1.*before changing anything"'
  check "names the plugin problem" 'logs m2 | grep -qiE "insulabad|doesnotexist|plugin"'
  fp1="$(fingerprint db2)"
  check "database untouched (fingerprint equal)" '[ "$fp0" = "$fp1" ]'
  check "previous code put back" '[ "$(code_id v2)" = "$OLD_ID" ]'
  check "a pre-upgrade dump was taken" 'vol_sh v2 "ls /var/www/moodle/backups/db-before-*.sql.gz" >/dev/null'
  check "no failure marker, no in-progress file" 'vol_sh v2 "[ ! -e /var/www/moodle/backups/UPGRADE-FAILED.txt ] && [ ! -e /var/www/moodle/backups/upgrade-in-progress.txt ]"'
  moodle_start m2 "$IMG_NEW" v2 db2
  wait_start m2 300
  check "retrying while still blocked reuses the dump instead of dumping again" 'logs m2 | grep -q "reusing that dump"'
  check "old site still works after the refusal (old image)" 'moodle_start m2 "$IMG_OLD" v2 db2 && wait_start m2 300 && logs m2 | grep -q "nothing to do"'

  vol_sh v2 'rm -rf /var/www/moodle/code/public/local/insulabad'
  docker stop "$P-m2" >/dev/null
  moodle_start m2 "$IMG_NEW" v2 db2
  wait_start m2 600; rc=$?; check "upgrade 5.3.0 -> 5.3.1 succeeds" '[ $rc -eq 0 ] && logs m2 | grep -q "upgraded to Moodle 5.3.1"'
  check "database is on 5.3.1" 'db_release db2 | grep -q "^5.3.1 "'
  check "code on the volume is the new image's" '[ "$(code_id v2)" = "$NEW_ID" ]'
  check "add-on plugin kept in the new tree" 'vol_sh v2 "[ -f /var/www/moodle/code/public/local/insulaprobe/version.php ]"'
  check "add-on plugin data intact" '[ "$(msql db2 "SELECT note FROM mdl_local_insulaprobe")" = "kept across upgrade" ]'
  check "previous code kept in backups/code-previous" '[ "$(vol_sh v2 "cat /var/www/moodle/backups/code-previous/.insula-code-id")" = "$OLD_ID" ]'
  check "exactly one dump kept" '[ "$(vol_sh v2 "ls /var/www/moodle/backups/db-before-*.sql.gz | wc -l")" = 1 ]'
  check "admin logs in after the upgrade" 'login m2 admin "$ADMIN_PASS"'
  check "status checks OK after the upgrade" 'checks_ok m2'

  moodle_start m2 "$IMG_NEW" v2 db2
  wait_start m2 300
  check "restart after the upgrade: nothing to do" 'logs m2 | grep -q "nothing to do"'

  fp0="$(fingerprint db2)"
  moodle_start m2 "$IMG_OLD" v2 db2
  wait_start m2 120; rc=$?; check "older image on an upgraded site refuses to start" '[ $rc -eq 1 ]'
  check "says why (downgrade) and how to go back" 'logs m2 | grep -q "older than the site.s Moodle 5.3.1" && logs m2 | grep -q "RESTORE-PREVIOUS"'
  check "downgrade attempt changed nothing" '[ "$(fingerprint db2)" = "$fp0" ] && [ "$(code_id v2)" = "$NEW_ID" ]'
}

# ----------------------------------------------------------------------------
# An upgrade that fails AFTER the database changed: sticky, then RETRY.
track_sticky() {
  section "sticky failure after the database changed, then retry"
  db_up db3 mariadb
  moodle_start m3 "$IMG_OLD" v3 db3
  wait_start m3 300 || { bad "5.3.0 site did not install"; return; }
  probe_install m3 v3 insulaprobe-v1
  vol_put v3 "$FIX/insulaprobe-v2-throws" /var/www/moodle/code/public/local/insulaprobe
  docker stop "$P-m3" >/dev/null
  moodle_start m3 "$IMG_NEW" v3 db3
  wait_start m3 600; rc=$?; check "failing plugin upgrade step: start fails" '[ $rc -eq 1 ]'
  check "says the database was changed" 'logs m3 | grep -q "failed after it changed the database"'
  check "UPGRADE-FAILED.txt written with retry and undo instructions" 'vol_sh v3 "grep -q RETRY /var/www/moodle/backups/UPGRADE-FAILED.txt && grep -q UNDO /var/www/moodle/backups/UPGRADE-FAILED.txt"'
  check "the plugin's error is in the marker" 'vol_sh v3 "grep -q \"failed on purpose\" /var/www/moodle/backups/UPGRADE-FAILED.txt"'
  moodle_start m3 "$IMG_NEW" v3 db3
  wait_start m3 120; rc=$?; check "restart keeps refusing while the marker exists" '[ $rc -eq 1 ] && logs m3 | grep -q "an earlier install or upgrade failed"'
  check "and does not touch the database again" '! logs m3 | grep -q "running Moodle.s upgrade"'

  vol_put v3 "$FIX/insulaprobe-v2-good" /var/www/moodle/code/public/local/insulaprobe
  vol_sh v3 'rm -f /var/www/moodle/backups/UPGRADE-FAILED.txt'
  moodle_start m3 "$IMG_NEW" v3 db3
  wait_start m3 600; rc=$?; check "RETRY: after fixing the cause and deleting the marker, the upgrade completes" '[ $rc -eq 0 ] && logs m3 | grep -q "retrying the failed upgrade" && logs m3 | grep -q "upgraded to Moodle 5.3.1"'
  check "retry leaves no incomplete record behind" 'vol_sh v3 "[ ! -e /var/www/moodle/backups/upgrade-incomplete.txt ]"'
  check "no upgrade left pending after the retry (cron can run)" 'mcli m3 admin/cli/upgrade.php --is-pending >/dev/null 2>&1'
  check "core on 5.3.1 and the plugin on its new version" 'db_release db3 | grep -q "^5.3.1 " && [ "$(msql db3 "SELECT value FROM mdl_config_plugins WHERE plugin=\"local_insulaprobe\" AND name=\"version\"")" = 2026020100 ]'
  check "admin logs in after the retried upgrade" 'login m3 admin "$ADMIN_PASS"'
}

# ----------------------------------------------------------------------------
# The same failure, then UNDO with RESTORE-PREVIOUS.
track_undo() {
  section "sticky failure, then undo with RESTORE-PREVIOUS"
  db_up db4 mariadb
  moodle_start m4 "$IMG_OLD" v4 db4
  wait_start m4 300 || { bad "5.3.0 site did not install"; return; }
  probe_install m4 v4 insulaprobe-v1
  msql db4 "INSERT INTO mdl_local_insulaprobe (note) VALUES ('back in time')"
  local fp_before broken="$P-broken:latest"
  docker stop "$P-m4" >/dev/null
  fp_before="$(fingerprint db4)"
  # The failure has to come from the NEW release: an image whose bundled copy
  # of the plugin has an upgrade step that fails. The old site only has v1.
  docker build -q -t "$broken" -f - "$FIX" >/dev/null <<DOCKERFILE
FROM $IMG_NEW
USER root
COPY insulaprobe-v2-throws /usr/src/moodle/public/local/insulaprobe
RUN cd /usr/src/moodle && find . -type f ! -name .insula-code-id ! -path './vendor/composer/*' ! -path ./vendor/autoload.php -print0 \\
    | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > .insula-code-id
USER www-data
DOCKERFILE
  moodle_start m4 "$broken" v4 db4
  wait_start m4 600; rc=$?; check "upgrade fails after changing the database" '[ $rc -eq 1 ] && vol_sh v4 "[ -f /var/www/moodle/backups/UPGRADE-FAILED.txt ]"'
  check "database did change" '[ "$(fingerprint db4)" != "$fp_before" ]'
  # The operator rolls the version back in Insula: the old image starts…
  moodle_start m4 "$IMG_OLD" v4 db4
  wait_start m4 120; rc=$?; check "old image still refuses while the marker exists" '[ $rc -eq 1 ]'
  # …and asks for the restore.
  vol_sh v4 ': > /var/www/moodle/backups/RESTORE-PREVIOUS'
  moodle_start m4 "$IMG_OLD" v4 db4
  wait_start m4 300; rc=$?; check "RESTORE-PREVIOUS on the old image: site starts" '[ $rc -eq 0 ]'
  check "logs the restore" 'logs m4 | grep -q "RESTORE-PREVIOUS: done"'
  check "database back on 5.3.0" 'db_release db4 | grep -qE "^5\.3 "'
  check "plugin back on v1 in the database and in the code" '[ "$(msql db4 "SELECT value FROM mdl_config_plugins WHERE plugin=\"local_insulaprobe\" AND name=\"version\"")" = 2026010100 ] && vol_sh v4 "grep -q 2026010100 /var/www/moodle/code/public/local/insulaprobe/version.php"'
  check "nothing left pending after the restore" 'mcli m4 admin/cli/upgrade.php --is-pending >/dev/null 2>&1'
  check "plugin data restored" '[ "$(msql db4 "SELECT note FROM mdl_local_insulaprobe")" = "back in time" ]'
  check "database exactly as before the upgrade (fingerprint)" '[ "$(fingerprint db4)" = "$fp_before" ]'
  check "code back on the old image's tree" '[ "$(code_id v4)" = "$OLD_ID" ]'
  check "marker and request file gone" 'vol_sh v4 "[ ! -e /var/www/moodle/backups/UPGRADE-FAILED.txt ] && [ ! -e /var/www/moodle/backups/RESTORE-PREVIOUS ]"'
  check "admin logs in on the restored site" 'login m4 admin "$ADMIN_PASS"'
  moodle_start m4 "$IMG_OLD" v4 db4
  wait_start m4 300
  check "restart after the restore: nothing to do" 'logs m4 | grep -q "nothing to do"'
}

# ----------------------------------------------------------------------------
track_interrupt() {
  section "interrupted upgrades (pod killed)"
  db_up db5 mariadb
  moodle_start m5 "$IMG_OLD" v5 db5
  wait_start m5 300 || { bad "5.3.0 site did not install"; return; }
  docker stop "$P-m5" >/dev/null

  # Killed while the new tree is being assembled.
  moodle_start m5 "$IMG_NEW" v5 db5
  local t=0
  until logs m5 | grep -q "assembling the new code tree" || [ $t -ge 300 ]; do sleep 0.5; t=$((t + 1)); done
  sleep 1
  docker kill "$P-m5" >/dev/null
  check "killed while assembling the tree: no half tree became code/" '[ "$(code_id v5)" = "$OLD_ID" ]'
  moodle_start m5 "$IMG_NEW" v5 db5
  wait_start m5 600; rc=$?; check "next start cleans up and completes the upgrade" '[ $rc -eq 0 ] && logs m5 | grep -q "upgraded to Moodle 5.3.1"'

  # A fresh install killed half way leaves a partial site; it must never be
  # mistaken for an installed one.
  section "interrupted fresh install"
  db_up dbi mariadb
  moodle_start mi "$IMG_NEW" vmi dbi
  t=0
  until logs mi | grep -q "installing a new site" || [ $t -ge 600 ]; do sleep 0.5; t=$((t + 1)); done
  until [ "$(msql dbi "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle'")" -gt 20 ] || [ $t -ge 900 ]; do sleep 0.5; t=$((t + 1)); done
  docker kill "$P-mi" >/dev/null
  check "killed while install_database.php was creating tables" '[ "$(msql dbi "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"moodle\"")" -gt 0 ]'
  moodle_start mi "$IMG_NEW" vmi dbi
  wait_start mi 120; rc=$?; check "next start refuses the partial site" '[ $rc -eq 1 ] && logs mi | grep -q "fresh install was interrupted"'
  check "and writes INSTALL FAILED with the way out" 'vol_sh vmi "grep -q \"drop every\" /var/www/moodle/backups/UPGRADE-FAILED.txt"'
  maria dbi -e "DROP DATABASE moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON moodle.* TO 'moodle'@'%';"
  vol_sh vmi 'rm -f /var/www/moodle/backups/UPGRADE-FAILED.txt'
  moodle_start mi "$IMG_NEW" vmi dbi
  wait_start mi 300; rc=$?; check "after dropping the tables and the marker, it installs" '[ $rc -eq 0 ] && logs mi | grep -q "installed Moodle"'
  db_up dbj mariadb
  vol_sh vmj 'mkdir -p /var/www/moodle/backups && echo started=x > /var/www/moodle/backups/install-in-progress.txt'
  moodle_start mj "$IMG_NEW" vmj dbj
  wait_start mj 300; rc=$?; check "cut off before any table existed: simply installs again" '[ $rc -eq 0 ] && logs mj | grep -q "interrupted before it created any tables" && logs mj | grep -q "installed Moodle"'

  # A pod killed during upgrade.php, simulated exactly: the swap done, the
  # in-progress record written, and either nothing or something changed.
  section "interrupted upgrade.php, database unchanged / changed"
  db_up db6 mariadb
  moodle_start m6 "$IMG_OLD" v6 db6
  wait_start m6 300 || { bad "5.3.0 site did not install"; return; }
  docker stop "$P-m6" >/dev/null
  local fp
  fp="$(fingerprint db6)"
  vol_sh v6 "cd /var/www/moodle && mkdir -p backups && mv code backups/code-previous && cp -R /usr/src/moodle code \
    && printf 'from_release=5.3\nto_release=5.3.1\nfingerprint=$fp\ndump=\n' > backups/upgrade-in-progress.txt"
  moodle_start m6 "$IMG_NEW" v6 db6
  wait_start m6 600; rc=$?; check "unchanged database: previous code put back and the upgrade runs again" '[ $rc -eq 0 ] && logs m6 | grep -q "interrupted before it changed the database" && logs m6 | grep -q "upgraded to Moodle 5.3.1"'

  db_up db7 mariadb
  moodle_start m7 "$IMG_OLD" v7 db7
  wait_start m7 300 || { bad "5.3.0 site did not install"; return; }
  docker stop "$P-m7" >/dev/null
  vol_sh v7 "cd /var/www/moodle && mkdir -p backups && printf 'from_release=5.3\nto_release=5.3.1\nfingerprint=not-what-the-db-is-now\ndump=\n' > backups/upgrade-in-progress.txt"
  moodle_start m7 "$IMG_NEW" v7 db7
  wait_start m7 120; rc=$?; check "changed database: refuses and writes UPGRADE-FAILED.txt" '[ $rc -eq 1 ] && logs m7 | grep -q "interrupted after it changed the database" && vol_sh v7 "[ -f /var/www/moodle/backups/UPGRADE-FAILED.txt ]"'
}

# ----------------------------------------------------------------------------
track_inputs() {
  section "bad settings and dangerous states"
  db_up db8 mariadb
  docker run -d --name "$P-e1" --network "$NET" -v "$P-ve1:/var/www/moodle" \
    -e DB_TYPE=oracle -e MOODLE_WWWROOT=learn.example.test -e DB_PREFIX=Toolongprefix_ "$IMG_NEW" >/dev/null
  wait_start e1 60; rc=$?; check "invalid settings: refuses to start" '[ $rc -eq 1 ]'
  check "lists every problem at once" '[ "$(logs e1 | grep -c "ERROR: ")" -ge 6 ] && logs e1 | grep -q "DB_TYPE=.oracle." && logs e1 | grep -q "MOODLE_WWWROOT=" && logs e1 | grep -q "DB_PASSWORD is required"'
  check "touched nothing on the volume" '[ -z "$(vol_sh ve1 "ls -A /var/www/moodle")" ]'

  moodle_start e2 "$IMG_NEW" ve2 db8 -e DB_PASSWORD=wrong -e MOODLE_DB_WAIT_SECONDS=10
  wait_start e2 90; rc=$?; check "wrong database password: refuses with the server's error" '[ $rc -eq 1 ] && logs e2 | grep -q "cannot log in to the mariadb database" && logs e2 | grep -qi "access denied"'

  vol_sh ve3 'mkdir -p /var/www/moodle/moodledata/filedir/ab && echo x > /var/www/moodle/moodledata/filedir/ab/file'
  moodle_start e3 "$IMG_NEW" ve3 db8
  wait_start e3 90; rc=$?; check "empty database but moodledata has files: no new site installed over them" '[ $rc -eq 1 ] && logs e3 | grep -q "never installed over existing data"'
  check "no tables were created" '[ "$(msql db8 "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"moodle\"")" = 0 ]'

  msql db8 "CREATE TABLE mdl_leftover (id INT)"
  moodle_start e4 "$IMG_NEW" ve4 db8
  wait_start e4 90; rc=$?; check "tables with the prefix but no site: refuses" '[ $rc -eq 1 ] && logs e4 | grep -q "remains of an interrupted install"'
  msql db8 "DROP TABLE mdl_leftover"

  moodle_start e5 "$IMG_NEW" ve5 db8 -e MOODLE_ADMIN_EMAIL=
  wait_start e5 90; rc=$?; check "fresh install without an admin e-mail: refuses before installing" '[ $rc -eq 1 ] && logs e5 | grep -q "MOODLE_ADMIN_EMAIL is required"'

  maria db8 -e "CREATE USER 'ro'@'%' IDENTIFIED BY 'ropw'; GRANT SELECT ON moodle.* TO 'ro'@'%';"
  moodle_start e6 "$IMG_NEW" ve6 db8 -e DB_USER=ro -e DB_PASSWORD=ropw
  wait_start e6 300; rc=$?; check "install fails (no CREATE privilege): start fails" '[ $rc -eq 1 ] && logs e6 | grep -q "installation failed"'
  check "INSTALL FAILED marker explains how to retry" 'vol_sh ve6 "grep -q \"INSTALL FAILED\" /var/www/moodle/backups/UPGRADE-FAILED.txt"'
  moodle_start e6 "$IMG_NEW" ve6 db8 -e DB_USER=ro -e DB_PASSWORD=ropw
  wait_start e6 60; rc=$?; check "and the next start refuses instead of treating it as a site" '[ $rc -eq 1 ] && logs e6 | grep -q "an earlier install or upgrade failed"'
  vol_sh ve6 'rm -f /var/www/moodle/backups/UPGRADE-FAILED.txt'
  msql db8 "CREATE TABLE mdl_partial_install (id INT)"
  moodle_start e6 "$IMG_NEW" ve6 db8
  wait_start e6 60; rc=$?; check "marker deleted but the partial tables still there: refuses" '[ $rc -eq 1 ] && logs e6 | grep -q "the failed install left"'
  msql db8 "DROP TABLE mdl_partial_install"
  moodle_start e6 "$IMG_NEW" ve6 db8 -e DB_PREFIX=retry_
  wait_start e6 300; rc=$?; check "after dropping them, the retry installs" '[ $rc -eq 0 ] && logs e6 | grep -q "installed Moodle"'
  docker rm -f "$P-e6" >/dev/null 2>&1

  moodle_start e7 "$IMG_NEW" ve7 db8 -e DB_PREFIX=m2_
  wait_start e7 300; rc=$?; check "custom prefix m2_: installs" '[ $rc -eq 0 ] && [ -n "$(msql db8 "SELECT value FROM m2_config WHERE name=\"version\"")" ]'
  moodle_start e8 "$IMG_NEW" ve8 db8
  wait_start e8 300; rc=$?; check "a second site with prefix mdl_ in the same database" '[ $rc -eq 0 ] && [ -n "$(msql db8 "SELECT value FROM mdl_config WHERE name=\"version\"")" ]'
  docker stop "$P-e8" >/dev/null
  moodle_start e8 "$IMG_NEW" ve8 db8 -e DB_PREFIX=m2_
  wait_start e8 60; rc=$?; check "a volume pointed at another site (prefix m2_ instead of mdl_): refuses" '[ $rc -eq 1 ] && logs e8 | grep -q "moodledata/ belongs to another Moodle site"'
  docker rm -f "$P-e8" >/dev/null 2>&1

  moodle_start e9 "$IMG_NEW" ve9 db8 -e DB_PREFIX=lang_ -e MOODLE_LANG=de -e MOODLE_SITE_NAME="Lernplattform Ä"
  wait_start e9 300; rc=$?; check "install in German downloads the language pack" '[ $rc -eq 0 ] && [ "$(msql db8 "SELECT value FROM lang_config WHERE name=\"lang\"")" = de ]'
  check "site name with a non-ASCII character" '[ "$(msql db8 "SELECT fullname FROM lang_course WHERE id=1")" = "Lernplattform Ä" ]'
}

# ----------------------------------------------------------------------------
track_pgsql() {
  section "PostgreSQL: install, point upgrade, undo"
  db_up pg1 pgsql
  moodle_start p1 "$IMG_OLD" vp1 pg1 -e DB_TYPE=pgsql
  wait_start p1 300; rc=$?; check "fresh install on PostgreSQL" '[ $rc -eq 0 ] && pg_release pg1 | grep -qE "^5\.3 "'
  check "admin logs in" 'login p1 admin "$ADMIN_PASS"'
  probe_install p1 vp1 insulaprobe-v1
  psql_ pg1 "INSERT INTO mdl_local_insulaprobe (note) VALUES ('pg row')" >/dev/null
  docker stop "$P-p1" >/dev/null
  local fp
  fp="$(fingerprint pg1 mdl_ pgsql)"
  moodle_start p1 "$IMG_NEW" vp1 pg1 -e DB_TYPE=pgsql
  wait_start p1 600; rc=$?; check "point upgrade on PostgreSQL (dump with pg_dump against the server)" '[ $rc -eq 0 ] && pg_release pg1 | grep -q "^5.3.1 "'
  check "dump is a valid gzip with the probe table" 'vol_sh vp1 "gzip -dc /var/www/moodle/backups/db-before-*.sql.gz | grep -q mdl_local_insulaprobe"'
  docker stop "$P-p1" >/dev/null
  vol_sh vp1 ': > /var/www/moodle/backups/RESTORE-PREVIOUS'
  moodle_start p1 "$IMG_OLD" vp1 pg1 -e DB_TYPE=pgsql
  wait_start p1 300; rc=$?; check "RESTORE-PREVIOUS on PostgreSQL: back on 5.3.0" '[ $rc -eq 0 ] && pg_release pg1 | grep -qE "^5\.3 "'
  check "PostgreSQL database exactly as before (fingerprint)" '[ "$(fingerprint pg1 mdl_ pgsql)" = "$fp" ]'
  check "probe row restored" '[ "$(psql_ pg1 "SELECT note FROM mdl_local_insulaprobe")" = "pg row" ]'
}

# ----------------------------------------------------------------------------
# Moving an existing production-shaped site (Moodle 5.0 on apache-php-office)
# onto this image.
track_migrate() {
  section "migration: a Moodle 5.0 site on apache-php-office -> this image"
  local ver=5.0.2
  db_up mdb mariadb
  maria mdb -e "CREATE DATABASE old CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON old.* TO 'moodle'@'%';"
  docker run --rm -u 0 -v "$P-olddata:/d" --entrypoint chown "$IMG_NEW" 33:33 /d
  # PHP_MAX_INPUT_VARS=5000: Moodle 5.0's installer requires it on PHP 8, so
  # every production site on apache-php-office has it set.
  docker run -d --name "$P-old" --network "$NET" --add-host "old.example.test:127.0.0.1" \
    -e PHP_MAX_INPUT_VARS=5000 -v "$P-oldhtml:/var/www/html" -v "$P-olddata:/var/www/moodledata" "$OFFICE_IMAGE" >/dev/null
  docker exec "$P-old" sh -c "curl -fsSL https://download.moodle.org/download.php/direct/stable500/moodle-$ver.tgz | tar -xz --strip-components=1 -C /var/www/html" \
    || { bad "could not download Moodle $ver"; return; }
  docker exec "$P-old" php /var/www/html/admin/cli/install.php --non-interactive --agree-license \
    --wwwroot=http://old.example.test:8080 --dataroot=/var/www/moodledata --dbtype=mariadb --dbhost="$P-mdb" \
    --dbname=old --dbuser=moodle --dbpass='db"pa$s\word' --prefix=m_ --fullname="Old site" --shortname=old \
    --adminpass='0ld!admin' --adminemail=admin@example.test > "$LOGS/old-install.log" 2>&1
  check "Moodle $ver installed on apache-php-office (the current production shape)" '[ "$(msql mdb "SELECT value FROM m_config WHERE name=\"release\"" old | cut -d" " -f1)" = "$ver" ]'
  # The site's own settings, an add-on plugin with data, the bundled plugin
  # installed by hand (as on today's sites), a course with files.
  docker exec -i "$P-old" php -- /var/www/html/config.php <<'PHP'
<?php
$f = $argv[1];
$extra = '$CFG->session_handler_class = \'\\core\\session\\database\';' . "\n"
    . '$CFG->forced_plugin_settings = [\'theme_boost\' => [\'brandcolor\' => \'#0a7\']];' . "\n"
    . '$CFG->tempdir = \'/var/www/moodledata/mytemp\';' . "\n";
file_put_contents($f, preg_replace_callback('/^require_once/m', fn() => $extra . 'require_once', file_get_contents($f), 1));
PHP
  tar -C "$FIX/insulaprobe-v1" -cf - . | docker exec -i "$P-old" sh -c 'mkdir -p /var/www/html/local/insulaprobe && tar -xf - -C /var/www/html/local/insulaprobe'
  tar -C "$here/../../plugins/local/bbbrecordingsync" -cf - . | docker exec -i "$P-old" sh -c 'mkdir -p /var/www/html/local/bbbrecordingsync && tar -xf - -C /var/www/html/local/bbbrecordingsync'
  docker exec "$P-old" php /var/www/html/admin/cli/upgrade.php --non-interactive > "$LOGS/old-plugins.log" 2>&1
  msql mdb "INSERT INTO m_local_insulaprobe (note) VALUES ('migrated row')" old
  docker exec "$P-old" php /var/www/html/admin/tool/generator/cli/maketestcourse.php --shortname=mig --size=XS --bypasscheck > "$LOGS/old-course.log" 2>&1
  local files_before course_before
  files_before="$(msql mdb "SELECT COUNT(*) FROM m_files WHERE filename <> '.'" old)"
  course_before="$(msql mdb "SELECT COUNT(*) FROM m_course" old)"
  check "old site has the add-on, its data and a test course with files" '[ "$(msql mdb "SELECT note FROM m_local_insulaprobe" old)" = "migrated row" ] && [ "$course_before" -ge 2 ] && [ "$files_before" -gt 0 ]'

  # The runbook: freeze the old site (CLI maintenance), copy the database
  # (the old site stays untouched as the fallback), copy code + moodledata
  # into the new deployment's volume.
  docker exec "$P-old" php /var/www/html/admin/cli/maintenance.php --enable >/dev/null
  maria mdb -e "CREATE DATABASE moodle53 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON moodle53.* TO 'moodle'@'%';"
  docker exec "$P-mdb" sh -c "mariadb-dump -uroot -prootpw --single-transaction old | mariadb -uroot -prootpw moodle53"
  docker run --rm -v "$P-oldhtml:/src/code:ro" -v "$P-olddata:/src/moodledata:ro" -v "$P-vmig:/var/www/moodle" \
    --entrypoint bash "$IMG_NEW" -c 'cp -a /src/code /var/www/moodle/code && cp -a /src/moodledata /var/www/moodle/moodledata'

  # Wrong prefix first: the data directory is a site's, the DB looks empty.
  moodle_start mig "$IMG_NEW" vmig mdb -e DB_NAME=moodle53
  wait_start mig 120; rc=$?; check "adoption with the wrong DB_PREFIX refuses (and installs nothing)" '[ $rc -eq 1 ] && logs mig | grep -q "never installed over existing data"'

  moodle_start mig "$IMG_NEW" vmig mdb -e DB_NAME=moodle53 -e DB_PREFIX=m_
  wait_start mig 900; rc=$?; check "5.0 site adopted and upgraded to 5.3.1" '[ $rc -eq 0 ] && logs mig | grep -q "upgraded to Moodle 5.3.1"'
  check "database on 5.3.1" '[ "$(msql mdb "SELECT value FROM m_config WHERE name=\"release\"" moodle53 | cut -d" " -f1)" = 5.3.1 ]'
  check "add-on plugin relocated to public/local/" 'vol_sh vmig "[ -f /var/www/moodle/code/public/local/insulaprobe/version.php ] && [ ! -e /var/www/moodle/code/local/insulaprobe ]"'
  check "add-on plugin data intact" '[ "$(msql mdb "SELECT note FROM m_local_insulaprobe" moodle53)" = "migrated row" ]'
  check "bundled BBB plugin now comes from the image" '[ "$(code_id vmig)" = "$NEW_ID" ] && vol_sh vmig "[ -f /var/www/moodle/code/public/local/bbbrecordingsync/version.php ]"'
  check "site's own settings carried into config-local.php" 'vol_sh vmig "grep -q session_handler_class /var/www/moodle/config-local.php && grep -q brandcolor /var/www/moodle/config-local.php"'
  check "path into the old data dir relocated" 'vol_sh vmig "grep -q \"/var/www/moodle/moodledata/mytemp\" /var/www/moodle/config-local.php"'
  check "the original config.php kept in backups/" 'vol_sh vmig "grep -q old.example.test /var/www/moodle/backups/config.php.orig"'
  check "courses and files all there" '[ "$(msql mdb "SELECT COUNT(*) FROM m_course" moodle53)" = "$course_before" ] && [ "$(msql mdb "SELECT COUNT(*) FROM m_files WHERE filename <> \".\"" moodle53)" -ge "$files_before" ]'
  check "the maintenance flag copied from the frozen old site is cleared" 'logs mig | grep -q "arrived in CLI maintenance mode" && [ "$(mcurl mig -o /dev/null -w "%{http_code}" "$WWWROOT/login/index.php")" = 200 ]'
  check "the old admin password works on the moved site" 'login mig admin "0ld!admin"'
  local fid
  fid="$(mphp mig <<'PHP'
$f = $DB->get_record_sql("SELECT * FROM {files} WHERE component = 'mod_resource' AND filearea = 'content' AND filename <> '.'", [], IGNORE_MULTIPLE);
if ($f) { echo moodle_url::make_pluginfile_url($f->contextid, $f->component, $f->filearea, $f->itemid, $f->filepath, $f->filename)->out(false); }
PHP
)"
  if [ -n "$fid" ]; then
    check "a course file is served through pluginfile.php" '[ "$(docker exec "$P-mig" curl -s -b "$LAST_JAR" --resolve "$HOST:8080:127.0.0.1" -o /dev/null -w "%{http_code}" "$fid")" = 200 ]'
  else
    note "no mod_resource file in the XS course; pluginfile check skipped"
  fi
  check "status checks OK on the moved site" 'checks_ok mig'
  check "the old site is untouched (still 5.0.2, still in maintenance)" '[ "$(msql mdb "SELECT value FROM m_config WHERE name=\"release\"" old | cut -d" " -f1)" = "$ver" ] && docker exec "$P-old" test -f /var/www/moodledata/climaintenance.html'

  section "migration refused: Moodle 5.0 on MariaDB 10.11 (5.3 needs 11.4)"
  db_up mdb10 mariadb mariadb:10.11
  docker exec "$P-mdb" sh -c "mariadb-dump -uroot -prootpw --single-transaction old" | docker exec -i "$P-mdb10" mariadb -uroot -prootpw moodle
  docker run --rm -v "$P-oldhtml:/src/code:ro" -v "$P-olddata:/src/moodledata:ro" -v "$P-vmig10:/var/www/moodle" \
    --entrypoint bash "$IMG_NEW" -c 'cp -a /src/code /var/www/moodle/code && cp -a /src/moodledata /var/www/moodle/moodledata'
  local fp10
  fp10="$(fingerprint mdb10 m_)"
  moodle_start mig10 "$IMG_NEW" vmig10 mdb10 -e DB_PREFIX=m_
  wait_start mig10 300; rc=$?; check "refused: start fails" '[ $rc -eq 1 ]'
  check "names the database version problem" 'logs mig10 | grep -qiE "mariadb.*(11\.4|version)|database.*version"'
  check "says nothing was changed" 'logs mig10 | grep -q "before changing anything"'
  check "database untouched" '[ "$(fingerprint mdb10 m_)" = "$fp10" ]'
  check "the site's own 5.0 tree and config.php are back" 'vol_sh vmig10 "[ -f /var/www/moodle/code/version.php ] && grep -q old.example.test /var/www/moodle/code/config.php && [ ! -e /var/www/moodle/code/public ]"'
  check "no config-local.php left behind" 'vol_sh vmig10 "[ ! -e /var/www/moodle/config-local.php ]"'
}

# ----------------------------------------------------------------------------
track_office() {
  section "documents: conversion and annotation inside web requests"
  db_up db9 mariadb
  moodle_start o1 "$IMG_NEW" vo1 db9
  wait_start o1 300 || { bad "site did not install"; return; }
  login o1 admin "$ADMIN_PASS" || { bad "admin login failed"; return; }
  local sesskey
  sesskey="$(docker exec "$P-o1" curl -s -b "$LAST_JAR" --resolve "$HOST:8080:127.0.0.1" "$WWWROOT/my/" | sed -n 's/.*"sesskey":"\([^"]*\)".*/\1/p' | head -n1)"
  check "unoconv test page (in a web request) reports success" 'docker exec "$P-o1" curl -s -b "$LAST_JAR" --resolve "$HOST:8080:127.0.0.1" "$WWWROOT/files/converter/unoconv/testunoconv.php?sesskey=$sesskey" | grep -qi "properly configured"'
  check "Ghostscript test page (in a web request) reports success" 'docker exec "$P-o1" curl -s -b "$LAST_JAR" --resolve "$HOST:8080:127.0.0.1" "$WWWROOT/mod/assign/feedback/editpdf/testgs.php" | grep -qi "ghostscript path appears to be OK"'
  mphp o1 > "$LOGS/convert.txt" 2>&1 <<'PHP'
set_config('converter_plugins_sortorder', 'unoconv');
$fs = get_file_storage();
$ctx = context_system::instance();
$tmp = make_temp_directory('insula');
file_put_contents("$tmp/a.txt", "Essay\n\nA student's submission.\n");
exec('cd ' . escapeshellarg($tmp) . ' && /usr/bin/unoconv -f docx -o a.docx a.txt 2>&1', $o, $rc);
if (!is_file("$tmp/a.docx")) { echo "fixture: could not make a.docx ($rc): ", implode(' ', $o), "\n"; }
$file = $fs->create_file_from_pathname(['contextid' => $ctx->id, 'component' => 'user', 'filearea' => 'draft', 'itemid' => 1, 'filepath' => '/', 'filename' => 'a.docx'], "$tmp/a.docx");
$converter = new \core_files\converter();
$conversion = $converter->start_conversion($file, 'pdf');
for ($i = 0; $i < 10 && $conversion->get('status') != \core_files\conversion::STATUS_COMPLETE; $i++) { $converter->poll_conversion($conversion); sleep(1); }
$out = $conversion->get_destfile();
echo "status=", $conversion->get('status'), " pdf=", $out ? $out->get_filesize() : 0, "\n";
PHP
  check "a .docx converts to PDF through Moodle's converter API" 'grep -qE "status=2 pdf=[1-9]" "$LOGS/convert.txt"'

  # Real client IP: a request from another container (a private address the
  # platform's proxies use) with X-Forwarded-For.
  docker run --rm --network "$NET" curlimages/curl:8.11.1 -s -o /dev/null -H "Host: $HOST:8080" \
    -H "X-Forwarded-For: 203.0.113.7" "http://$P-o1:8080/login/index.php?insula=ipcheck" >/dev/null 2>&1
  check "Apache logs the client IP from X-Forwarded-For" 'logs o1 | grep "insula=ipcheck" | grep -q "203.0.113.7"'

  # Moodle's "Cron running" check wants a cron start at least every two
  # minutes; a cron.php left on its default keep-alive (three minutes) fails it
  # a few minutes after start, which a check right after install never sees.
  local up
  up="$(docker inspect -f '{{.State.StartedAt}}' "$P-o1")"
  while [ $(( $(date +%s) - $(date -d "$up" +%s) )) -lt 300 ]; do sleep 10; done
  check "five minutes in, Moodle's status checks (incl. cron running) are all OK" 'checks_ok o1'
}

TRACKS=("$@")
[ "${#TRACKS[@]}" -gt 0 ] || TRACKS=(install upgrade sticky undo interrupt inputs pgsql migrate office)
for t in "${TRACKS[@]}"; do
  "track_$t"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
