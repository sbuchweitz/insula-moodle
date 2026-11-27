# shellcheck shell=bash
# shellcheck disable=SC2034 # FIX, LAST_JAR and others are used by run.sh, which sources this file
# Helpers for the docker-based integration tests (tests/integration/run.sh).
#
# Everything runs through the docker API: files go in with `docker cp` and
# requests are sent from inside the containers, so the tests work the same
# against a local daemon, a remote one (DOCKER_HOST) and a CI runner.

RUN_ID="${RUN_ID:-$$}"
P="imt${RUN_ID}"                    # prefix of every container/volume/network
NET="${P}-net"
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
IMG_OLD="${IMG_OLD:-insula-moodle:5.3.0-local}"
IMG_NEW="${IMG_NEW:-insula-moodle:5.3.1-local}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:12.3}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18}"
OFFICE_IMAGE="${OFFICE_IMAGE:-ghcr.io/insulahq/application-catalog/apache-php-office:8.4}"
HOST="moodle.test"
WWWROOT="http://${HOST}:8080"
ADMIN_PASS='Adm1n!pass-$x'

pass=0
fail=0
failures=()
ok() { pass=$((pass + 1)); printf '    ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$CURRENT: $1"); printf '    FAIL %s\n' "$1"; }
# pipefail is off while a check runs: `logs X | grep -q …` would otherwise
# fail whenever grep stops reading early and docker logs gets SIGPIPE.
check() {
  local r
  set +o pipefail
  if eval "$2"; then r=0; else r=1; fi
  set -o pipefail
  if [ "$r" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}
section() { CURRENT="$1"; printf '\n== %s\n' "$1"; }
note() { printf '    .. %s\n' "$*"; }

cleanup_all() {
  docker ps -aq --filter "name=^${P}-" | xargs -r docker rm -f >/dev/null 2>&1
  docker volume ls -q --filter "name=^${P}-" | xargs -r docker volume rm -f >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1 || true
}

net_up() { docker network create "$NET" >/dev/null; }

# db_up NAME TYPE [IMAGE] — start a database server with an empty "moodle" db.
db_up() {
  local name="$1" type="$2" image="${3:-}"
  case "$type" in
    mariadb)
      docker run -d --name "$P-$name" --network "$NET" \
        -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=moodle \
        -e MARIADB_USER=moodle -e 'MARIADB_PASSWORD=db"pa$s\word' \
        "${image:-$MARIADB_IMAGE}" --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci >/dev/null
      local _
      for _ in $(seq 1 60); do
        docker exec "$P-$name" mariadb -uroot -prootpw -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 2
      done
      ;;
    pgsql)
      docker run -d --name "$P-$name" --network "$NET" \
        -e POSTGRES_DB=moodle -e POSTGRES_USER=moodle -e 'POSTGRES_PASSWORD=db"pa$s\word' \
        "${image:-$POSTGRES_IMAGE}" >/dev/null
      local _
      for _ in $(seq 1 60); do
        docker exec "$P-$name" pg_isready -U moodle -d moodle >/dev/null 2>&1 && sleep 2 && return 0
        sleep 2
      done
      ;;
  esac
  echo "database $name did not come up" >&2
  return 1
}

# Root shell on a MariaDB server.
maria() { docker exec -i "$P-$1" mariadb -uroot -prootpw "${@:2}"; }
# SQL against the moodle database, tab-separated, no header.
msql() { docker exec -i "$P-$1" mariadb -uroot -prootpw -N -B "${3:-moodle}" -e "$2"; }
psql_() { docker exec -i "$P-$1" psql -U moodle -d "${3:-moodle}" -X -A -t -c "$2"; }

# moodle_start NAME IMAGE VOLUME DBNAME [EXTRA docker args/env…] — start a
# Moodle container against the database container DBNAME.
moodle_start() {
  local name="$1" image="$2" vol="$3" db="$4"
  shift 4
  docker rm -f "$P-$name" >/dev/null 2>&1 || true
  docker run -d --name "$P-$name" --network "$NET" --add-host "$HOST:127.0.0.1" \
    -v "$P-$vol:/var/www/moodle" \
    -e DB_HOST="$P-$db" -e DB_NAME=moodle -e DB_USER=moodle -e 'DB_PASSWORD=db"pa$s\word' \
    -e MOODLE_WWWROOT="$WWWROOT" -e MOODLE_ADMIN_PASSWORD="$ADMIN_PASS" \
    -e MOODLE_ADMIN_EMAIL=admin@example.test -e MOODLE_DB_WAIT_SECONDS=60 \
    "$@" "$image" >/dev/null
}

# wait_start NAME [TIMEOUT] — wait until the lifecycle finished and Apache
# answers (returns 0), or the container exited (returns 1). Saves the log.
wait_start() {
  local name="$1" timeout="${2:-600}" t=0 state
  while [ "$t" -lt "$timeout" ]; do
    state="$(docker inspect -f '{{.State.Status}}' "$P-$name" 2>/dev/null || echo gone)"
    if [ "$state" = exited ] || [ "$state" = gone ]; then
      docker logs "$P-$name" > "$LOGS/$name.$(date +%s).log" 2>&1 || true
      return 1
    fi
    if docker exec "$P-$name" curl -s -o /dev/null --max-time 5 http://127.0.0.1:8080/healthcheck 2>/dev/null; then
      docker logs "$P-$name" > "$LOGS/$name.$(date +%s).log" 2>&1 || true
      return 0
    fi
    sleep 3
    t=$((t + 3))
  done
  docker logs "$P-$name" > "$LOGS/$name.$(date +%s).log" 2>&1 || true
  echo "timed out waiting for $name" >&2
  return 2
}

logs() { docker logs "$P-$1" 2>&1; }
exit_code() { docker inspect -f '{{.State.ExitCode}}' "$P-$1"; }

# Run a command in a stopped-or-running site's volume as www-data, using the
# Moodle image itself (so the user and tools are the real ones).
vol_sh() {
  local vol="$1"
  shift
  docker run --rm -i --entrypoint bash -v "$P-$vol:/var/www/moodle" "$IMG_NEW" -c "$*"
}
# Copy a local directory into a volume path (as www-data).
vol_put() { # vol_put VOL SRC_DIR DEST_PATH
  local vol="$1" src="$2" dest="$3"
  tar -C "$src" -cf - . | docker run --rm -i --entrypoint bash -v "$P-$vol:/var/www/moodle" "$IMG_NEW" \
    -c "rm -rf '$dest' && mkdir -p '$dest' && tar -xf - -C '$dest'"
}

# HTTP from inside the container, with the site's host name.
mcurl() { local name="$1"; shift; docker exec "$P-$name" curl -s --resolve "$HOST:8080:127.0.0.1" "$@"; }

# Moodle CLI in a running container.
mcli() { local name="$1"; shift; docker exec -w /var/www/moodle/code "$P-$name" php "$@"; }
# Run PHP with Moodle bootstrapped (CLI_SCRIPT); code on stdin.
mphp() {
  local name="$1"
  { printf '<?php define("CLI_SCRIPT", true); require "/var/www/moodle/code/config.php";\n'; cat; } \
    | docker exec -i -w /var/www/moodle/code "$P-$name" php
}

# login NAME USER PASS — a real browser-style login; 0 when the dashboard loads.
login() {
  local name="$1" user="$2" pass="$3" jar="/tmp/jar-$RANDOM" token code
  token="$(docker exec "$P-$name" sh -c "curl -s -c $jar --resolve $HOST:8080:127.0.0.1 $WWWROOT/login/index.php" \
    | sed -n 's/.*name="logintoken" value="\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$token" ] || { rm_jar "$name" "$jar"; return 1; }
  # The password travels as an environment variable: no shell quoting can
  # mangle it on the way into curl.
  docker exec -e "PW=$pass" "$P-$name" sh -c "curl -s -b $jar -c $jar --resolve $HOST:8080:127.0.0.1 -o /dev/null \
    --data-urlencode 'username=$user' --data-urlencode \"password=\$PW\" --data-urlencode 'logintoken=$token' \
    $WWWROOT/login/index.php"
  code="$(docker exec "$P-$name" sh -c "curl -s -b $jar --resolve $HOST:8080:127.0.0.1 -o /dev/null -w '%{http_code} %{redirect_url}' $WWWROOT/my/")"
  LAST_JAR="$jar"
  [ "${code%% *}" = 200 ]
}
rm_jar() { docker exec "$P-$1" rm -f "$2" >/dev/null 2>&1 || true; }

# The database fingerprint the lifecycle uses, computed by the lifecycle's own
# code inside the image (MariaDB track only).
fingerprint() { # fingerprint DBCONTAINER [PREFIX] [DBTYPE]
  local db="$1" prefix="${2:-mdl_}" type="${3:-mariadb}"
  docker run --rm --network "$NET" --entrypoint bash \
    -e DB_TYPE="$type" -e DB_HOST="$P-$db" -e DB_PORT="$([ "$type" = pgsql ] && echo 5432 || echo 3306)" \
    -e DB_NAME=moodle -e DB_USER=moodle -e 'DB_PASSWORD=db"pa$s\word' -e DB_PREFIX="$prefix" \
    -e INSULA_MOODLE_ETC=/tmp "$IMG_NEW" -c \
    '. /usr/local/lib/insula-moodle/common.sh; . /usr/local/lib/insula-moodle/db.sh; db_prepare_client; db_fingerprint'
}

db_release() { msql "$1" "SELECT value FROM ${2:-mdl_}config WHERE name='release'"; }
pg_release() { psql_ "$1" "SELECT value FROM ${2:-mdl_}config WHERE name='release'"; }
code_id() { vol_sh "$1" 'cat /var/www/moodle/code/.insula-code-id 2>/dev/null'; }
image_id() { docker run --rm --entrypoint cat "$1" /usr/src/moodle/.insula-code-id; }
