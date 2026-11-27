# syntax=docker/dockerfile:1.7
# Moodle for the Insula hosting platform.
#
# FROM the Official Catalog's apache-php runtime, so the PHP extensions, the
# PHP_* tuning knobs, the real-client-IP handling and the weekly base patching
# all come from the same image every other PHP site on the platform runs on.
# This image adds the document toolchain Moodle shells out to, the database
# clients the upgrade dump needs, one exact Moodle release, the bundled
# plugins, and the start-up lifecycle (rootfs/usr/local/bin/moodle-lifecycle).
#
# PHP 8.4, not the catalog's 8.5 default: Moodle 5.3 LTS supports PHP 8.3 and
# 8.4 only; 8.5 support is still being built upstream (MDL-84684). Revisit
# when the next Moodle LTS line is added.
ARG PHP_VERSION=8.4
ARG BASE_IMAGE=ghcr.io/insulahq/application-catalog/apache-php:${PHP_VERSION}
FROM ${BASE_IMAGE}

USER root

# Document toolchain, at the paths config.php pins (render-config.php):
#   ghostscript   /usr/bin/gs        Annotate PDF feedback
#   poppler-utils /usr/bin/pdftoppm  editpdf page rendering
#   libreoffice   via /usr/bin/unoconv (shim below): .docx/.odt/… -> PDF
#   graphviz      /usr/bin/dot       aspell /usr/bin/aspell   python3
# The -nogui LibreOffice packages skip GTK/X11; Java is not needed for
# Writer/Calc/Impress -> PDF. Fonts decide how a converted page paginates.
# No ClamAV: antivirus_clamav speaks tcpsocket, so a shared clamd Service beats
# a scanner and its signature database in every site's image.
#
# Database clients for the pre-upgrade dump and the lifecycle's checks.
# postgresql-client comes from the PostgreSQL project's apt repository because
# Debian's (17) cannot dump a newer server; the metapackage there follows the
# newest major, so no pin needs bumping when PostgreSQL 19 ships.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL --retry 5 -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    # --force-confold: serversideup edits /etc/apache2/envvars; an apache2
    # update must keep their version rather than stop at a conffile prompt.
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ghostscript \
      poppler-utils \
      libreoffice-writer-nogui \
      libreoffice-calc-nogui \
      libreoffice-impress-nogui \
      fonts-liberation \
      fonts-dejavu-core \
      graphviz \
      aspell \
      aspell-en \
      python3 \
      mariadb-client \
      postgresql-client \
      gzip \
    ; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Moodle's default pathtounoconv. See the script header for why this is a shim
# and which unoconv behaviours Moodle depends on.
COPY --chmod=0755 rootfs/usr/bin/unoconv /usr/bin/unoconv
RUN set -eux; \
    /usr/bin/unoconv --version | grep -qE 'unoconv [0-9]+\.[0-9]+'; \
    /usr/bin/unoconv --show 2>&1 >/dev/null | grep -q '\[\.pdf\]'; \
    test -x /usr/bin/gs; test -x /usr/bin/pdftoppm; \
    mariadb-dump --version; pg_dump --version

# One exact Moodle release, from the official download (which already bundles
# its third-party libraries). The checksum comes from releases.json, so every
# rebuild of a tag installs byte-identical code.
ARG MOODLE_VERSION
ARG MOODLE_SHA256
RUN set -eux; \
    test -n "${MOODLE_VERSION}" && test -n "${MOODLE_SHA256}"; \
    major="${MOODLE_VERSION%%.*}"; rest="${MOODLE_VERSION#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"; \
    if [ "$patch" = "0" ]; then name="moodle-${major}.${minor}.tgz"; else name="moodle-${MOODLE_VERSION}.tgz"; fi; \
    stable="$(printf 'stable%d%02d' "$major" "$minor")"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o /tmp/moodle.tgz \
      "https://download.moodle.org/download.php/direct/${stable}/${name}"; \
    echo "${MOODLE_SHA256}  /tmp/moodle.tgz" | sha256sum -c -; \
    mkdir -p /usr/src/moodle; \
    # Owner and modes are settled HERE, in the layer that creates the files: a
    # later chown/chmod -R would rewrite every file into a new layer, i.e. a
    # second copy of the whole tree (518 MB) for every node to download.
    tar -xzf /tmp/moodle.tgz --strip-components=1 --no-same-owner -C /usr/src/moodle; \
    chmod -R a+rX,go-w /usr/src/moodle; \
    rm -f /tmp/moodle.tgz; \
    release="$(sed -n "s/^[[:space:]]*\$release[[:space:]]*=[[:space:]]*'\([^ ']*\).*/\1/p" /usr/src/moodle/public/version.php)"; \
    expected="${MOODLE_VERSION%.0}"; \
    test "$release" = "$expected" || { echo "tarball holds Moodle $release, expected $expected"; exit 1; }

# The download does NOT contain vendor/: since 5.1 part of Moodle's libraries
# come through Composer, and without them 5.3's OAuth2 and web service routes
# die with 'Trait "League\OAuth2\Server\…" not found'. Installed from Moodle's
# own composer.lock, exactly as its environment check asks
# ("composer install --no-dev --classmap-authoritative"), with the base
# image's composer.
RUN set -eux; \
    COMPOSER_HOME=/tmp/composer COMPOSER_ALLOW_SUPERUSER=1 composer install \
      --working-dir=/usr/src/moodle --no-dev --classmap-authoritative --no-interaction --no-progress; \
    test -f /usr/src/moodle/vendor/autoload.php; \
    rm -rf /tmp/composer

# Bundled plugins, in the 5.1+ layout (public/<type dir>/<name>). The build
# context's plugins/ is checked out at the commit releases.json records for
# this release, so a later plugin change never alters an existing tag.
COPY plugins/ /usr/src/moodle/public/

# The code id: a hash of every file in the tree. The lifecycle compares it with
# the stamp on the volume — equal means "this site already runs exactly this
# code", which is what makes a restart on the same tag a no-op. Composer's
# generated autoloader is left out: it is derived from composer.lock (which is
# in the hash) and may differ in form between composer versions, which would
# otherwise make a weekly rebuild look like new code.
RUN set -eux; \
    cd /usr/src/moodle; \
    find . -type f ! -name .insula-code-id ! -path './vendor/composer/*' ! -path ./vendor/autoload.php -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > .insula-code-id; \
    cat .insula-code-id; \
    # Everything must already be root-owned and not writable by others (see the
    # extraction step); fail the build rather than fix it with a copying chown.
    test -z "$(find /usr/src/moodle ! -user root -print -quit)"; \
    test -z "$(find /usr/src/moodle -perm /022 -print -quit)"

COPY rootfs/etc/ /etc/
COPY rootfs/usr/local/ /usr/local/
RUN set -eux; \
    chmod 0755 /usr/local/bin/moodle-lifecycle /etc/entrypoint.d/60-insula-moodle.sh \
      /etc/s6-overlay/s6-rc.d/moodle-cron/run; \
    for tpl in http https; do \
      printf '\n# --- insula-moodle ---\nInclude /etc/apache2/insula/moodle.conf\n' \
        >> "/etc/apache2/vhost-templates/${tpl}.conf"; \
    done; \
    install -d -o www-data -g www-data -m 0750 /etc/insula-moodle; \
    install -d -o www-data -g www-data -m 0750 /var/cache/insula-moodle /var/cache/insula-moodle/localcache; \
    install -d -o www-data -g www-data -m 0755 /var/www/moodle; \
    php -l /usr/local/lib/insula-moodle/render-config.php; \
    php -l /usr/local/lib/insula-moodle/adopt-config.php; \
    php -l /usr/local/share/insula-moodle/config.php; \
    bash -n /usr/local/bin/moodle-lifecycle

# Defaults for a tenant who configures nothing. They live here, not in the
# manifest's env_vars.fixed: the platform resolves "fixed" first and skips any
# key already set, so a fixed value would silently win over the tenant's.
#   APACHE_DOCUMENT_ROOT              Moodle 5.1+ web root
#   PHP_MAX_INPUT_VARS=5000           Moodle warns below 5000 (base: 1000)
#   PHP_OPCACHE_MEMORY_CONSUMPTION    Moodle is a large code base
#   PHP_OPCACHE_MAX_ACCELERATED_FILES 5.3 ships over 55,000 PHP files (base: 32531)
#   PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 plugins are installed into the live tree
#                                     through Moodle's UI (base: 0 = never re-read)
#   PHP_OPCACHE_REVALIDATE_FREQ=60    Moodle's documented production value
#   PHP_FPM_PM_MAX_CHILDREN=10        one site per pod; see README for sizing
ENV APACHE_DOCUMENT_ROOT=/var/www/moodle/code/public \
    PHP_MAX_INPUT_VARS=5000 \
    PHP_OPCACHE_MEMORY_CONSUMPTION=128 \
    PHP_OPCACHE_MAX_ACCELERATED_FILES=65407 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=60 \
    PHP_FPM_PM_MAX_CHILDREN=10 \
    DB_TYPE=mariadb \
    DB_PREFIX=mdl_ \
    DB_COLLATION=utf8mb4_unicode_ci \
    MOODLE_CRON=true \
    MOODLE_ADMIN_USER=admin \
    MOODLE_SITE_NAME=Moodle \
    MOODLE_LANG=en

ARG MOODLE_VERSION
LABEL org.opencontainers.image.title="insula-moodle" \
      org.opencontainers.image.description="Moodle ${MOODLE_VERSION} for the Insula hosting platform" \
      org.opencontainers.image.source="https://github.com/sbuchweitz/insula-moodle" \
      org.opencontainers.image.version="${MOODLE_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

WORKDIR /var/www/moodle
USER www-data
