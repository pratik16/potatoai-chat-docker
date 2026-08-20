#!/bin/sh
set -eu

mkdir -p \
  storage/app \
  storage/framework/cache \
  storage/framework/sessions \
  storage/framework/views \
  storage/logs \
  bootstrap/cache

chown -R www-data:www-data storage bootstrap/cache

# bootstrap/cache is a persisted named volume (backend_cache) and the image installs
# with `composer install --no-scripts`, so package:discover never runs during a build.
# packages.php therefore survives a rebuild holding the PREVIOUS deploy's package list,
# and any newly added package's service provider is silently never registered — its
# routes just don't exist, and a later `artisan optimize` caches that incomplete route
# table. The symptom is a 404 that still carries `x-powered-by: PHP`.
#
# Laravel's PackageManifest rebuilds these lazily when the files are absent, so simply
# dropping them here is enough, and is cheaper and less race-prone than invoking
# artisan from every container that shares this entrypoint.
rm -f bootstrap/cache/packages.php bootstrap/cache/services.php

exec "$@"
