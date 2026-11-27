# shellcheck shell=bash
# Database access for the lifecycle, using the DB_* variables Moodle itself is
# configured with. The command-line clients talk to the database directly so a
# decision about the site (install? upgrade? refuse?) never depends on the
# Moodle code that is about to be replaced.

DB_CLIENT_CNF="$INSULA_MOODLE_ETC/client.cnf"

# The password goes into a 0600 options file rather than onto the command line,
# where any process in the container could read it from /proc.
db_prepare_client() {
  case "$DB_TYPE" in
    mariadb|mysqli)
      umask 077
      {
        printf '[client]\n'
        printf 'host=%s\n' "$DB_HOST"
        printf 'port=%s\n' "$DB_PORT"
        printf 'user=%s\n' "$DB_USER"
        printf 'password="%s"\n' "$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        # Moodle's own mysqli connection does not use TLS, so neither does
        # this; the MariaDB 11.4+ client would otherwise insist on it.
        printf 'skip-ssl\n'
        printf 'protocol=TCP\n'
      } > "$DB_CLIENT_CNF"
      umask 022
      ;;
    pgsql) ;;
  esac
}

# db_sql SQL — run a query, print tab-separated rows without headers.
db_sql() {
  case "$DB_TYPE" in
    mariadb|mysqli)
      mariadb --defaults-extra-file="$DB_CLIENT_CNF" --batch --skip-column-names \
        --connect-timeout=10 "$DB_NAME" -e "$1"
      ;;
    pgsql)
      PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=10 psql -X -q -A -t -F $'\t' \
        -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$1"
      ;;
  esac
}

# Wait for the database to accept a login. A database pod started together
# with this one can take a minute; a wrong password never gets better, so the
# last error is printed when the wait gives up.
db_wait() {
  local timeout="${MOODLE_DB_WAIT_SECONDS:-300}" waited=0 err=""
  while :; do
    if err="$(db_sql 'SELECT 1' 2>&1 >/dev/null)"; then
      return 0
    fi
    if [ "$waited" -ge "$timeout" ]; then
      printf '[insula-moodle] ERROR: cannot log in to the %s database %s at %s:%s as %s after %ss: %s\n' \
        "$DB_TYPE" "$DB_NAME" "$DB_HOST" "$DB_PORT" "$DB_USER" "$timeout" "$err" >&2
      return 1
    fi
    if [ $((waited % 30)) -eq 0 ]; then
      log "waiting for the database at $DB_HOST:$DB_PORT ($err)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# The prefix as a LIKE pattern: "_" is a wildcard there.
db_prefix_like() {
  printf '%s%%' "${DB_PREFIX//_/\\_}"
}

db_schema_expr() {
  case "$DB_TYPE" in
    pgsql) printf 'current_schema()' ;;
    *) printf 'DATABASE()' ;;
  esac
}

# Is there a Moodle site with this prefix in the database? 0 = yes.
db_site_installed() {
  local n
  n="$(db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = $(db_schema_expr) AND table_name = '${DB_PREFIX}config'")" || return 2
  [ "${n:-0}" -gt 0 ]
}

# Any tables with this prefix at all? Used to refuse installing over the
# remains of a half-installed or foreign site.
db_prefixed_table_count() {
  db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = $(db_schema_expr) AND table_name LIKE '$(db_prefix_like)'"
}

db_core_version() {
  db_sql "SELECT value FROM ${DB_PREFIX}config WHERE name = 'version'"
}

db_release() {
  db_sql "SELECT value FROM ${DB_PREFIX}config WHERE name = 'release'"
}

# A fingerprint of everything an upgrade changes: every version row, the
# upgrade-running flag Moodle sets the moment real upgrade steps begin, and the
# shape of every table. Equal before and after a failed upgrade.php means the
# upgrade never started (environment check, missing plugin dependency, …) and
# the previous code can be put back as if nothing happened.
db_fingerprint() {
  local like schema
  like="$(db_prefix_like)"
  schema="$(db_schema_expr)"
  {
    db_sql "SELECT name, value FROM ${DB_PREFIX}config WHERE name IN ('version', 'release', 'allversionshash', 'upgraderunning') ORDER BY name"
    db_sql "SELECT plugin, value FROM ${DB_PREFIX}config_plugins WHERE name = 'version' ORDER BY plugin"
    db_sql "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = ${schema} AND table_name LIKE '${like}' ORDER BY table_name, column_name"
  } | sha256sum | cut -d' ' -f1
}

# The database server's version string, for log lines and for the clearest
# possible error when it is too old for the target Moodle.
db_server_version() {
  db_sql 'SELECT version()' 2>/dev/null | head -n 1
}

# db_dump FILE — a consistent gzip'd dump of the Moodle tables. Writes to a
# temporary name and renames, so a dump that dies half way is never mistaken
# for a good one.
db_dump() {
  local out="$1" tmp="$1.partial"
  rm -f "$tmp"
  case "$DB_TYPE" in
    mariadb|mysqli)
      # Only this site's tables: a database shared by several prefixes must
      # not be dumped (or later restored) wholesale.
      local tables
      tables="$(db_sql "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE '$(db_prefix_like)' ORDER BY table_name")" || return 1
      [ -n "$tables" ] || { warn "no tables with prefix $DB_PREFIX to dump"; return 1; }
      # shellcheck disable=SC2086 # one argument per table name
      mariadb-dump --defaults-extra-file="$DB_CLIENT_CNF" --single-transaction --quick \
        --routines --triggers --hex-blob --default-character-set=utf8mb4 --no-tablespaces \
        "$DB_NAME" $tables | gzip -1 > "$tmp" || { rm -f "$tmp"; return 1; }
      ;;
    pgsql)
      PGPASSWORD="$DB_PASSWORD" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --no-owner --no-privileges --table="${DB_PREFIX}*" | gzip -1 > "$tmp" || { rm -f "$tmp"; return 1; }
      ;;
  esac
  # pipefail is set by the caller, so a failing dump fails the pipeline; also
  # check the result is a readable, non-trivial gzip.
  if ! gzip -t "$tmp" 2>/dev/null || [ "$(gzip -dc "$tmp" | head -c 4096 | wc -c)" -lt 100 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
}
