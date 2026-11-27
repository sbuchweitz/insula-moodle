# insula-moodle

Moodle for the [Insula](https://github.com/insulahq/insula) hosting platform: one
image per Moodle point release of the current long-term-support line, published as
`ghcr.io/sbuchweitz/insula-moodle:<version>` (e.g. `5.3.1`), plus the Insula catalog
entry that deploys it.

It is built for one operator's needs and kept small on purpose; it is not meant to
compete with general-purpose Moodle images.

- **Runtime:** the Official Catalog's `apache-php` image, with its PHP extensions,
  `PHP_*` settings, real-client-IP handling and weekly base patching.
  - PHP is 8.4, because Moodle 5.3 supports 8.3 and 8.4 only.
- **Documents:** LibreOffice (through a small `unoconv` shim), Ghostscript, poppler,
  graphviz and aspell. With these, Annotate PDF and document conversion work in web
  requests as well as in cron.
- **Bundled plugin:** `local_bbbrecordingsync` resolves BigBlueButton recordings
  stuck after a server change. BBB's own task schedules are also toned down.
- **Database:** none bundled. Point `DB_*` at a MariaDB, MySQL or PostgreSQL database
  in the tenant.
- **Your files:** code, add-on plugins, `moodledata` and site settings all live on the
  deployment's volume. You can reach them in the file manager and over SFTP.

## Versions and upgrades

Each Moodle point release is its own catalog version with its own image tag. A tag's
Moodle code never changes. The weekly rebuild only brings operating-system and PHP
patches for the newest two releases of each line.

**Moodle is upgraded only when someone changes the deployment's version in Insula**
(the Upgrade button):

- The entry is `versionLockMode: "strict"`, so Insula's auto-upgrade never touches it.
- A restart on the same tag finds the code on the volume identical to the image's,
  and does nothing.

When the version does change, the container's start-up does the following before
Apache starts, so no request ever reaches a half-upgraded site:

1. Dump the database to `backups/db-before-<release>-<time>.sql.gz`.
2. Build the new code tree next to the old one: this release's code plus every add-on
   plugin from the old tree. "Add-on" means any directory with a `version.php` that
   core does not ship. Plugins are moved under `public/` when coming from Moodle 5.0
   or older.
3. Swap the trees. The old one is kept in `backups/code-previous/`.
4. Run Moodle's `admin/cli/upgrade.php`, then purge caches.

New point releases appear by themselves. The weekly build finds a new Moodle release,
builds it, and tests an upgrade from the previous release to it (including a refusal
and an undo). Only then does it add the release to the catalog entry. Insula picks it up
at its next catalog sync (daily, or **Sync** under Applications → Repositories) and offers
it as an upgrade.

A new long-term-support line (5.3 → next LTS) is added to `moodle/manifest.json` by
hand, because which versions may jump to it is a decision.

### When an upgrade fails

- **Moodle refused before changing anything.** Examples: the database server is too
  old, or an add-on plugin's dependency is missing.
  - The previous code is put back and the database is untouched; its fingerprint is
    compared before and after.
  - The container exits with the reason, and Insula shows the deployment as failed,
    with that reason as its error.
  - Fix the cause, or roll the version back in Insula. Retries reuse the existing
    dump.
- **It failed after the database changed.** The container keeps refusing to start
  until a person decides, and `backups/UPGRADE-FAILED.txt` explains the options:
  - **Retry:** fix the cause (often an add-on plugin; it is in `code/`), then delete
    `UPGRADE-FAILED.txt`. Moodle continues from the last step it completed.
  - **Undo:** roll the version back in Insula, then create an empty file
    `backups/RESTORE-PREVIOUS`. The next start restores the database from the dump
    and puts `backups/code-previous` back.
- **A pod is killed during a fresh install.** If it had not created any tables yet,
  the install simply runs again. Otherwise the partial site is never taken for a
  real one: the start refuses, and `UPGRADE-FAILED.txt` says to drop the half-created
  tables and delete the file.
- **A pod is killed during an upgrade.** The next start sees the in-progress record.
  - Database unchanged: the old code is put back and the upgrade runs again.
  - Database changed: it is treated as a failed upgrade (above).
- **An older image starts against an upgraded site** (Insula's rollback button, after
  a successful upgrade). It refuses: Moodle cannot run older code against an upgraded
  database. Use the undo steps above.

## The volume

```
code/              Moodle + add-on plugins (web root: code/public)
moodledata/        Moodle's data directory (not reachable over HTTP)
config-local.php   your own Moodle settings, kept across upgrades (optional)
backups/           pre-upgrade database dump, previous code, failure notes
```

`code/config.php` belongs to the image and is rewritten on every start. Put any
settings of your own in `config-local.php`, as `$CFG->name = value;` lines. The
platform's settings below always win over it.

## Settings

All settings are fields in Insula's deployment form. Defaults live in the image, so an
untouched field gets the default shown.

| Variable | Default | |
|---|---|---|
| `MOODLE_WWWROOT` | required | Public URL, e.g. `https://learn.example.com` |
| `DB_TYPE` | `mariadb` | `mariadb`, `mysqli` (MySQL) or `pgsql` |
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | required | The tenant's database deployment |
| `DB_PORT` | 3306 / 5432 | |
| `DB_PREFIX` | `mdl_` | A moved site keeps the prefix from its `config.php` |
| `DB_COLLATION` | `utf8mb4_unicode_ci` | MariaDB/MySQL; Insula creates databases with it |
| `MOODLE_BBB_SERVER_URL`, `MOODLE_BBB_SHARED_SECRET` | empty | Optional, both or neither: pins BigBlueButton so it cannot be edited (editing it in Moodle resets every recording) |
| `MOODLE_CRON` | `true` | Moodle cron inside the container, every minute |
| `MOODLE_ADMIN_USER`, `MOODLE_ADMIN_EMAIL`, `MOODLE_SITE_NAME`, `MOODLE_LANG` | `admin`, –, `Moodle`, `en` | **Install only**, ignored afterwards |
| `MOODLE_ADMIN_PASSWORD` | generated by Insula | **Install only** |
| `PHP_MEMORY_LIMIT` | `256M` | |
| `PHP_UPLOAD_MAX_FILE_SIZE`, `PHP_POST_MAX_SIZE` | `100M` | |
| `PHP_MAX_EXECUTION_TIME` | `99` | |
| `PHP_MAX_INPUT_VARS` | `5000` | Moodle's minimum |
| `PHP_DATE_TIMEZONE` | `UTC` | |
| `PHP_FPM_PM_MAX_CHILDREN` | `10` | Concurrent requests; each may use up to `PHP_MEMORY_LIMIT` |
| `PHP_FPM_PM_CONTROL`, `PHP_FPM_PM_MAX_REQUESTS`, `PHP_OPCACHE_MEMORY_CONSUMPTION` | `ondemand`, `500`, `128` | Advanced |

**Set by the platform and locked in Moodle's admin UI:**

- **Database, URL and data location:** the database settings, `wwwroot`, `dataroot`.
- **`sslproxy`:** on for an https URL, because TLS ends at Insula's ingress.
- **`routerconfigured`:** Apache sends missing paths to `r.php`.
- **`localcachedir`:** on the container's own disk.
- **`preventexecpath`, plus the paths to `gs`, `pdftoppm`, `unoconv`, `dot`, `du`,
  `python3` and `aspell`:** an admin cannot point Moodle at another binary.
- **`debugdisplay = 0`:** debug output in pages breaks Moodle's JSON responses, and
  debug messages still reach the pod log.

**Left to Moodle's UI on purpose:** outgoing mail (SMTP), themes, authentication,
caching and everything else Moodle stores in its database. A restart never rewrites
any of it.

## Moving an existing site onto this image

The database server must meet the target release's minimum: for Moodle 5.3, MariaDB
11.4, MySQL 8.4 or PostgreSQL 17. A site on an older server is refused before
anything changes. Upgrade the database server first.

1. **Freeze the old site.** Turn on maintenance mode
   (`php admin/cli/maintenance.php --enable`) so nothing changes while you copy.
2. **Copy the database** into a new, empty database (`mysqldump old | mysql new`).
   Keep the old one untouched as your fallback.
3. **Create the Moodle deployment** in Insula:
   - `DB_*` pointing at the new database;
   - `DB_PREFIX` = the old `config.php`'s `$CFG->prefix`;
   - `MOODLE_WWWROOT` = the site's URL.

   Stop it right after it is created.
4. **Copy the files** into the deployment's folder: the old Moodle code tree into
   `code/` (with its `config.php` and add-on plugins), the old data directory into
   `moodledata/`.
5. **Start the deployment.** The start-up recognises the moved site and then:
   - turns its `config.php` into `config-local.php`: platform-owned settings are
     dropped, everything else is kept, and paths into the old data directory are
     moved;
   - keeps the original as `backups/config.php.orig`;
   - clears the maintenance flag that came along with `moodledata/` (the old site
     stays frozen);
   - upgrades the site to this release (Moodle 4.4 or later upgrades to 5.3
     directly).
6. **Check the site, then switch the domain's route** to the new deployment. Remove
   the old deployment once you are satisfied.

## Development

```sh
tests/unit/test-tree.sh            # code-tree logic (no docker)
tests/unit/test-config.sh          # env validation, config rendering, config.php conversion
scripts/validate.py                # catalog entry vs. releases.json and the rules above
scripts/build-context.sh 5.3.1 /tmp/ctx > /tmp/args          # prints MOODLE_VERSION=… MOODLE_SHA256=…
docker build $(sed 's/^/--build-arg /' /tmp/args) -t insula-moodle:5.3.1 /tmp/ctx
scripts/check-office-tools.sh <image>
IMG_OLD=<5.3.0 image> IMG_NEW=<5.3.1 image> tests/integration/run.sh [track…]
```

The integration tests run real Moodle images against real MariaDB and PostgreSQL
servers through the docker API, so they also work against a remote daemon. The tracks
are:

- `install`: fresh install, restart, settings
- `upgrade`: point upgrade, refusal before change, downgrade
- `sticky`: failure after the database changed, then retry
- `undo`: `RESTORE-PREVIOUS`
- `interrupt`: killed upgrades
- `inputs`: bad settings and dangerous states
- `pgsql`: PostgreSQL
- `migrate`: a Moodle 5.0 site moved from `apache-php-office`, and a refusal on
  MariaDB 10.11
- `office`: conversion and annotation inside web requests, and the real client IP

`releases.json` records each release's tarball checksum and the commit whose
`plugins/` that release bundles. Rebuilding a tag later therefore reproduces exactly
the same code.

## Licence

GPL-3.0-or-later, like Moodle itself. `tree.sh`'s add-on plugin detection and parts of
the unit tests are ported from [erseco/alpine-moodle](https://github.com/erseco/alpine-moodle)
(MIT); see [THIRD_PARTY.md](THIRD_PARTY.md).
