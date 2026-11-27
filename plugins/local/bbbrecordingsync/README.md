# local_bbbrecordingsync

Stopgap for a defect in Moodle's BigBlueButton activity (mod_bigbluebuttonbn), present in Moodle 5.0, 5.1 and
main as of November 2026. Remove it once Moodle ships the fix (see `../../upstream/`).

## The defect

Changing the BigBlueButton **server URL** in Moodle (Site administration > Plugins > BigBlueButton) queues
`reset_recordings`, which sets every recording to RESET. The `check_pending_recordings` task (every 5 minutes)
queries all RESET recordings, with no time limit, and only moves the ones the server has to "processed". Recordings
the server never had (meetings where nobody pressed record) or has deleted stay RESET and are queried forever.
On one production site this was ~2,850 recordings and ~35,000 getRecordings calls a day.

## What this plugin does

An hourly task, "Resolve BigBlueButton recordings stuck after a server change", looks at recordings in RESET:

| BigBlueButton says | Result |
|---|---|
| has the recording | processed, for every row with that recording id (imported copies share it; core only updates the first) |
| answered without it, recording older than 30 days | dismissed (`check_dismissed_recordings` still re-checks it for 30 days) |
| answered without it, newer | back to awaiting, so it ages out like any pending recording |
| did not answer (down, wrong secret during a rotation) | left in RESET, retried next hour |

"Answered without it" uses the module's own check (`recording_proxy::fetch_missing_recordings`), the same rule
the module applies when listing recordings since MDL-80225, so a failed request never hides real recordings.
Each row is read again right before it is changed and skipped if it left RESET in the meantime, so changes made
while the server was being queried are kept. It only changes `status` (and `timemodified`) and stores nothing.

## Before the first run

The first run decides the whole backlog at once (on this site ~2,850 rows, ~230 getRecordings calls). One case the
"answered without it" rule cannot tell apart: a BigBlueButton server that is up but has lost its recordings storage
(e.g. an unmounted NFS share) answers "no such recording" for everything. So for the first run:

1. Back up the table: `pg_dump -t mdl_bigbluebuttonbn_recordings` (or `mysqldump ... mdl_bigbluebuttonbn_recordings`).
2. Check the server plays existing recordings, then run the task once by hand (command below) and read the counts.
   Expect most rows "dismissed" and the recordings people still use "found".
3. If something was dismissed that should not have been: `check_dismissed_recordings` re-checks dismissed rows for
   30 days and restores the ones the server has, and `mod/bigbluebuttonbn/cli/update_dismissed_recordings.php -r=1`
   does the same without that time limit.

## Install

Moodle 5.0: copy this folder to `<moodle>/local/bbbrecordingsync`; Moodle 5.1+: `<moodle>/public/local/bbbrecordingsync`.
Then visit Site administration > Notifications or run `php admin/cli/upgrade.php`. The first run clears the existing
backlog; to run it right away:

```bash
sudo -u www-data php admin/cli/scheduled_task.php --execute='\local_bbbrecordingsync\task\resolve_reset_recordings'
```

Use either this plugin or the patched module, not both for long: once Moodle includes the fix, uninstall
(Site administration > Plugins > Local plugins > Uninstall, then delete the folder). They are safe together in the
meantime; whichever runs first leaves nothing in RESET for the other.

## Tests

PHPUnit, against the BigBlueButton mock server (`MOODLE_DOCKER_BBB_MOCK=true` with moodle-docker):

```bash
vendor/bin/phpunit local/bbbrecordingsync/tests/resolver_test.php
```

Tested on Moodle 5.0.12, PHP 8.3, PostgreSQL 17 (8 tests), alone and together with the patched module;
moodle-cs (`moodle-extra`) clean.
