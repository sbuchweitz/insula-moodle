# shellcheck shell=bash
# Validate and normalise the environment before anything touches the volume or
# the database. Every failure names the variable and what it should look like:
# in the platform these are fields in the deployment form, and a tenant has to
# be able to fix one from the log line alone.

env_errors=()

env_fail() { env_errors+=("$1"); }

# required NAME — must be set and non-empty.
env_required() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    env_fail "$name is required but empty"
    return 1
  fi
}

# matches NAME REGEX DESCRIPTION — checked only when the variable is set.
env_matches() {
  local name="$1" re="$2" what="$3"
  local value="${!name:-}"
  [ -z "$value" ] && return 0
  if ! [[ "$value" =~ $re ]]; then
    env_fail "$name='$value' is not valid: expected $what"
    return 1
  fi
}

validate_env() {
  env_errors=()

  # --- Database -------------------------------------------------------------
  DB_TYPE="${DB_TYPE:-mariadb}"
  case "$DB_TYPE" in
    mariadb|mysqli|pgsql) ;;
    *) env_fail "DB_TYPE='$DB_TYPE' is not supported: use mariadb, mysqli (MySQL) or pgsql" ;;
  esac
  env_required DB_HOST
  env_required DB_NAME
  env_required DB_USER
  env_required DB_PASSWORD
  if [ -z "${DB_PORT:-}" ]; then
    case "$DB_TYPE" in
      pgsql) DB_PORT=5432 ;;
      *) DB_PORT=3306 ;;
    esac
  fi
  env_matches DB_PORT '^[0-9]{1,5}$' 'a port number'
  env_matches DB_HOST '^[A-Za-z0-9._:-]+$' 'a host name or IP address (the database service name in your tenant)'
  DB_PREFIX="${DB_PREFIX-mdl_}"
  # Moodle refuses prefixes longer than 10 characters (xmldb_table::PREFIX_MAX_LENGTH).
  env_matches DB_PREFIX '^[a-z][a-z0-9_]{0,9}$' 'lower-case letters, digits and _, starting with a letter, at most 10 characters (e.g. mdl_)'
  [ -n "$DB_PREFIX" ] || env_fail "DB_PREFIX must not be empty"
  DB_COLLATION="${DB_COLLATION:-utf8mb4_unicode_ci}"
  env_matches DB_COLLATION '^[a-z0-9_]+$' 'a collation name such as utf8mb4_unicode_ci'

  # --- Site URL -------------------------------------------------------------
  if env_required MOODLE_WWWROOT; then
    # A trailing slash makes Moodle build "//" URLs; drop it rather than fail.
    MOODLE_WWWROOT="${MOODLE_WWWROOT%/}"
    env_matches MOODLE_WWWROOT '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' \
      'the full public URL of the site, e.g. https://learn.example.com (no query string)'
  fi

  # --- BigBlueButton pin (optional, both or neither) ------------------------
  if [ -n "${MOODLE_BBB_SERVER_URL:-}" ] || [ -n "${MOODLE_BBB_SHARED_SECRET:-}" ]; then
    env_required MOODLE_BBB_SERVER_URL
    env_required MOODLE_BBB_SHARED_SECRET
    if [ -n "${MOODLE_BBB_SERVER_URL:-}" ]; then
      env_matches MOODLE_BBB_SERVER_URL '^https?://[^[:space:]]+$' 'the BigBlueButton API base URL, e.g. https://bbb.example.com/bigbluebutton/'
      # Moodle appends "api/…" directly, so the base must end in a slash.
      case "$MOODLE_BBB_SERVER_URL" in */) ;; *) MOODLE_BBB_SERVER_URL="$MOODLE_BBB_SERVER_URL/" ;; esac
    fi
  fi

  # --- Cron -----------------------------------------------------------------
  MOODLE_CRON="${MOODLE_CRON:-true}"
  case "${MOODLE_CRON,,}" in
    true|1|yes|on) MOODLE_CRON=true ;;
    false|0|no|off) MOODLE_CRON=false ;;
    *) env_fail "MOODLE_CRON='$MOODLE_CRON' is not valid: use true or false" ;;
  esac

  export DB_TYPE DB_PORT DB_PREFIX DB_COLLATION MOODLE_WWWROOT MOODLE_BBB_SERVER_URL MOODLE_CRON

  if [ "${#env_errors[@]}" -gt 0 ]; then
    local e
    for e in "${env_errors[@]}"; do
      printf '[insula-moodle] ERROR: %s\n' "$e" >&2
    done
    return 1
  fi
}

# Only needed for a fresh install, so only checked then: once a site exists
# these are ignored, and a site that has been running for a year must not stop
# starting because someone cleared the admin e-mail field.
validate_install_env() {
  env_errors=()
  MOODLE_ADMIN_USER="${MOODLE_ADMIN_USER:-admin}"
  env_matches MOODLE_ADMIN_USER '^[a-z0-9_.@-]+$' 'a lower-case Moodle username such as admin'
  env_required MOODLE_ADMIN_PASSWORD
  env_required MOODLE_ADMIN_EMAIL
  env_matches MOODLE_ADMIN_EMAIL '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' 'an e-mail address'
  MOODLE_SITE_NAME="${MOODLE_SITE_NAME:-Moodle}"
  MOODLE_LANG="${MOODLE_LANG:-en}"
  env_matches MOODLE_LANG '^[a-z]{2,3}(_[a-z0-9]+)*$' 'a Moodle language code such as en, de or pt_br'
  if [ "${#env_errors[@]}" -gt 0 ]; then
    local e
    for e in "${env_errors[@]}"; do
      printf '[insula-moodle] ERROR: %s\n' "$e" >&2
    done
    return 1
  fi
}
