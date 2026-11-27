#!/bin/sh
# Install, upgrade or simply check the Moodle site before s6 starts Apache and
# PHP-FPM. serversideup's entrypoint sources this file in a subshell; a
# non-zero exit stops the container, which Insula shows as a failed deployment.
#
# Only for the image's normal start (/init). `docker run <image> php -v` and
# other one-off commands must not install or upgrade anything.
if [ "${SERVERSIDEUP_DEFAULT_COMMAND:-false}" = "true" ]; then
  /usr/local/bin/moodle-lifecycle
fi
