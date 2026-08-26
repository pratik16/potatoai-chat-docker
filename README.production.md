# PotatoAI Production Deployment

Production uses separate Docker assets from local development:

- Local: `docker-compose.yml` plus optional `docker-compose.override.yml`
- Production: `docker-compose.prod.yml` with `.env.production`
- Frontend production runtime serves compiled files from `~/potatoaihub/frontend-dist`

Do not commit `.env.production`.
Do not put frontend `node_modules` or source builds inside Docker runtime containers.

## How backend code reaches production

**The host checkout is the code.** `~/potatoaihub/backend` is bind-mounted at `/var/www/backend`
into `app`, `queue`, `scheduler` and `websockets`, and `php.production.ini` sets
`opcache.validate_timestamps = 1` (`revalidate_freq = 2`). So a `git pull` — or a hand edit on the
box — is live on the next request, with **no image build and no container recreate**.

`Dockerfile.production` still does `COPY backend/ ./`, so the image remains self-contained and
buildable. The bind mount just shadows it. That is what makes this reversible: drop the mount from
compose and `up -d`, and you are back on baked-in code without a rebuild.

What still needs a nudge after a code change, and what does not:

| | Needs anything? |
|---|---|
| `app` (PHP-FPM) | **No.** opcache re-stats the file within `revalidate_freq`. |
| `backend-nginx` | **No.** It mounts the same `backend/public`. |
| `scheduler` | **No.** Every iteration spawns a fresh `schedule:run`. |
| `queue` | `php artisan queue:restart` — a long-lived process holds the old code in memory. |
| `websockets` (Reverb) | `up -d --force-recreate websockets` — no graceful reload exists. |
| Routes / config / `.env` | An artisan cache command. `bootstrap/cache/routes-v7.php` is what Laravel reads, not `routes/*.php`. |
| `vendor/` | `composer install` **through the container** (see below). Never as `ubuntu`. |
| PHP version or extensions | A real image rebuild. |

`vendor/` now lives in the host checkout, not the image, and must be built with the image's own PHP
and extensions:

```bash
cd ~/potatoaihub/docker
docker compose --env-file .env.production -f docker-compose.prod.yml \
  run --rm --no-deps app composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
```

> **Artisan commands that write into `public/` now write to the host checkout, as `root`.**
> The PHP containers run as root, so `filament:assets` and `storage:link` create root-owned files
> and directories inside `~/potatoaihub/backend/public`. Git can replace a root-owned *file* (it
> unlinks and recreates), but a root-owned *directory* makes the next `git pull` fail with a
> permission error. If that happens:
> `sudo chown -R ubuntu:ubuntu ~/potatoaihub/backend/public`. Committing generated assets (see
> `backend/CLAUDE.md` §3) is what keeps you out of this situation in the first place.

`backend/.github/workflows/deploy-production.yml` gates every expensive step on the actual git diff,
so a push that only touches PHP under `app/` **recreates no container at all**. It rebuilds the
image only when `php/Dockerfile.production` or `docker-compose.prod.yml` moved, and re-runs
`composer install` only when `composer.lock` moved (or `vendor/autoload.php` is missing).

### One-time cutover — order is load-bearing

**Applied 2026-08-26** (backend `c929928`, docker `999272a`). Measured across a 1s probe of `/up`
spanning the recreate: **141/141 requests returned 200 — zero failed requests.** Kept here because
the ordering rule still applies to any rebuild of this box, and to a rollback.

Do it in this order; reversing it takes production down.

1. **Push the backend repo first** (workflow only). Against the *old* compose this deploy changes
   nothing that matters: `up -d` is a no-op, and its `composer install` step writes into the
   image layer — there is no bind mount yet — so the `--rm` container throws it away. It costs a
   wasted minute, once. `app` keeps running baked-in code throughout.
2. **Then push the docker repo** (`docker-compose.prod.yml` + `php/php.production.ini`). Now the
   new workflow does the whole cutover in the right order inside a single run: it sees the compose
   diff and rebuilds, then runs `composer install` **with the mount already active** — populating
   `~/potatoaihub/backend/vendor` on the host — and only then does `up -d` recreate the four PHP
   services onto that mount.

The ordering rule exists because of what the **old** workflow does, not what the new one does. The
old one has no `composer install` step at all: point it at the new compose and it goes straight to
`up -d app`, mounting a host checkout with no `vendor/`. The mount shadows the image's copy, so
there is no autoloader and the API is fully down until someone runs `composer install` by hand.

The invariant that makes the new workflow safe in either direction is that step 2b (`composer
install`) always runs **before** step 2c (`up -d`). Don't reorder them.

To cut over by hand instead of waiting for a push, from `~/potatoaihub/docker`:

```bash
C="docker compose --env-file .env.production -f docker-compose.prod.yml"
cd ~/potatoaihub/backend && git fetch --prune origin master && git merge --ff-only origin/master
cd ~/potatoaihub/docker  && git fetch --prune origin master && git merge --ff-only origin/master

$C run --rm --no-deps app composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
test -f ~/potatoaihub/backend/vendor/autoload.php || echo "STOP — do not continue without vendor/"

$C up -d app queue scheduler websockets
for c in optimize:clear config:cache route:cache filament:optimize; do
  $C exec -T app php artisan $c < /dev/null
done
```

Rollback: `git checkout <prev-sha> -- docker-compose.prod.yml php/php.production.ini && $C up -d app queue scheduler websockets`.

## Persistent data — still named volumes (migration NOT yet applied)

`postgres_data`, `mongodb_data`, `mongodb_config`, `redis_data`, `caddy_data`, `caddy_config`,
`backend_storage`, `backend_cache` are Docker named volumes. They *are* on disk — at
`/var/lib/docker/volumes/docker_<name>/_data` — just not anywhere convenient to back up or grep.

The planned move to `~/potatoaihub/data/` is written up below. **It needs a maintenance window and
must not be half-applied:** if the compose change reaches the server before the copy, Postgres
starts on an empty directory and initialises a **brand-new empty database**, and Caddy re-issues
certificates from Let's Encrypt.

Target layout, and the mount each directory replaces:

| Host path under `~/potatoaihub/data/` | Container path | Replaces |
|---|---|---|
| `postgres/` | `/var/lib/postgresql/data` (`PGDATA` = `pgdata` inside) | `postgres_data` |
| `mongodb/db/` | `/data/db` | `mongodb_data` |
| `mongodb/configdb/` | `/data/configdb` | `mongodb_config` |
| `redis/` | `/data` | `redis_data` |
| `caddy/data/` | `/data` — **TLS certificates** | `caddy_data` |
| `caddy/config/` | `/config` | `caddy_config` |
| `backend/storage/` | `/var/www/backend/storage` | `backend_storage` |
| `backend/bootstrap-cache/` | `/var/www/backend/bootstrap/cache` | `backend_cache` |

`data/` sits outside both git checkouts deliberately: `git clean -xfd` deletes ignored files too, so
a database inside a checkout is one stray command from deletion.

Procedure, in a window:

```bash
cd ~/potatoaihub/docker
C="docker compose --env-file .env.production -f docker-compose.prod.yml"
D=~/potatoaihub/data

# Pre-flight — measured 2026-08-26, re-check before the window:
#   volume prefix : docker_   (all eight names confirmed)
#   sizes         : mongodb_data 511M, postgres_data 64M, redis_data 14.5M,
#                   backend_storage 2.5M, backend_cache 380K, caddy_* 152K  => 593M total
#   free disk     : 62G of 77G
#   baseline      : users 12, credit_ledger 62, chats 21, messages 64, redis dbsize 1
# At 593M the copy is seconds; the window is dominated by container stop/start (~2 min).
# `sudo du` needs a password on this box — measure through a container instead:
#   docker run --rm -v docker_<vol>:/v alpine du -sh /v

$C down

# Belt and braces: a logical dump, in case the file copy is wrong.
$C up -d postgres && sleep 5
docker exec potatoai_postgres pg_dumpall -U potatoai > ~/pg-preflight-$(date +%F).sql
$C down

# cp -a inside a helper container preserves NUMERIC uid/gid and modes, so we never
# need to know that alpine-postgres is uid 70 while mongo and redis are 999.
copyvol() { mkdir -p "$2"; docker run --rm -v "$1":/from -v "$2":/to alpine \
              sh -c 'cd /from && cp -a . /to/' && echo "OK $1 -> $2"; }
copyvol docker_postgres_data   $D/postgres
copyvol docker_mongodb_data    $D/mongodb/db
copyvol docker_mongodb_config  $D/mongodb/configdb
copyvol docker_redis_data      $D/redis
copyvol docker_caddy_data      $D/caddy/data
copyvol docker_caddy_config    $D/caddy/config
copyvol docker_backend_storage $D/backend/storage
copyvol docker_backend_cache   $D/backend/bootstrap-cache

# GUARD. Do not start anything until all three pass.
test -f $D/postgres/pgdata/PG_VERSION   || echo "ABORT: no PG_VERSION — Postgres would init empty"
ls $D/mongodb/db/WiredTiger             || echo "ABORT: no mongo data"
find $D/caddy/data -name '*.crt' | head -1 | grep . || echo "ABORT: no certs — Caddy would re-issue"

# Only now pull the compose change that swaps the volumes for these paths, then:
$C up -d
```

The copy only *reads* the named volumes, so rollback is `$C down`, revert
`docker-compose.prod.yml`, `$C up -d`. Keep the old volumes for at least a week before
`docker volume rm`.

Afterwards `~/potatoaihub/data/backend/storage/logs/laravel-<date>.log` is readable straight from
the host — no `docker exec` — and a full backup becomes
`tar -czf backup-$(date +%F).tgz -C ~/potatoaihub data`.

## EC2 Commands

From `~/potatoaihub/docker` on the server:

```bash
docker compose --env-file .env.production -f docker-compose.prod.yml up -d --build
docker compose --env-file .env.production -f docker-compose.prod.yml exec -T app php artisan migrate --force
docker compose --env-file .env.production -f docker-compose.prod.yml exec -T app php artisan db:seed --class=DatabaseSeeder --force
docker compose --env-file .env.production -f docker-compose.prod.yml exec -T app php artisan config:cache
docker compose --env-file .env.production -f docker-compose.prod.yml exec -T app php artisan route:cache
```

> `db:seed` above belongs to **first bring-up only**. Do not run it against a populated
> production database.

### Any deploy that adds a Composer package: run `package:discover`

`bootstrap/cache` is a **persisted named volume** (`backend_cache`), and
`Dockerfile.production` installs with `--no-scripts`. So `bootstrap/cache/packages.php` — the
auto-discovery manifest — survives the rebuild holding the *previous* deploy's package list, and
nothing in the image build regenerates it.

The new package's service provider is then never registered. Its routes simply do not exist, and
`php artisan optimize` caches that incomplete route table, cementing the failure. The symptom is a
**404 with `x-powered-by: PHP` present** — Laravel answering, not nginx.

`optimize` does **not** run `package:discover`. Run it explicitly, in this order:

```bash
$COMPOSE exec -T app php artisan optimize:clear
$COMPOSE exec -T app php artisan package:discover --ansi
$COMPOSE exec -T app php artisan optimize
```

Confirm the manifest actually picked the package up:

```bash
$COMPOSE exec -T app sh -c 'grep -c -i filament bootstrap/cache/packages.php'   # must be > 0
```

## Admin control panel (Filament) — `cpanel.potatoaihub.com`

Requires a DNS **A record** for `cpanel` pointing at the same IP as the apex, in place *before*
recreating `edge` — otherwise Caddy's ACME challenge fails and backs off.

`.env.production` needs these (names only; see `.env.production.example`):
`ADMIN_PANEL_DOMAIN=cpanel.potatoaihub.com`, `SESSION_SECURE_COOKIE=true`, and
`ADMIN_PANEL_IP_GATE` left **unset/false** on first deploy. Leave `SESSION_DOMAIN` unset so the
panel cookie stays scoped to `cpanel` and is never shared with `www`.

```bash
cd ~/potatoaihub/docker
git pull origin master
COMPOSE="docker compose --env-file .env.production -f docker-compose.prod.yml"

# Backend code + committed Filament assets. backend-nginx serves backend/public
# from the host checkout, so this pull is what publishes the panel's CSS/JS.
cd ~/potatoaihub/backend && git pull origin master && cd ~/potatoaihub/docker

$COMPOSE up -d --build app queue scheduler
$COMPOSE up -d --force-recreate backend-nginx edge

$COMPOSE exec -T app php artisan migrate --force

# Caches. package:discover is REQUIRED here — bootstrap/cache is a persisted
# volume, so the stale manifest would otherwise hide Filament and Livewire
# entirely and every panel URL would 404. See the section above.
$COMPOSE exec -T app php artisan optimize:clear
$COMPOSE exec -T app php artisan package:discover --ansi
$COMPOSE exec -T app php artisan optimize
$COMPOSE exec -T app php artisan filament:optimize

# First administrator. Use -it (not -T) so the password prompt is interactive
# and never lands in shell history.
$COMPOSE exec -it app php artisan admin:create you@example.com --role=super_admin
```

Verify:

```bash
curl -I https://cpanel.potatoaihub.com/livewire/livewire.min.js  # must be 200, not 404
#   .min.js, not .js — Livewire only registers the minified route when APP_DEBUG=false,
#   which is why the panel HTML asks for /livewire/livewire.min.js?id=…
curl -I https://cpanel.potatoaihub.com/admin/login            # 200
curl -I https://www.potatoaihub.com/                          # still the React SPA
```

**`ADMIN_PANEL_DOMAIN` is baked in by `route:cache`.** Changing it later needs
`$COMPOSE exec -T app php artisan route:clear && … route:cache`.

Before any redeploy: `$COMPOSE exec -T app php artisan filament:optimize-clear && … optimize:clear`.

## Frontend-Only Deployment

The React app should be built outside the production runtime and copied to:

```bash
~/potatoaihub/frontend-dist
```

Then restart the frontend container:

```bash
cd ~/potatoaihub/docker
git pull origin master
docker compose --env-file .env.production -f docker-compose.prod.yml up -d --force-recreate frontend edge
```

## Upload size limits (HTTP 413)

Multipart chat uploads (up to 5 × 10MB) need **64M** at every hop. Compose already mounts:

- `./Caddyfile` → edge (`request_body max_size 64MB`)
- `./nginx/frontend.prod.conf` → frontend (`client_max_body_size 64M`)
- `./nginx/backend.prod.conf` → backend-nginx (`client_max_body_size 64M`)

PHP limits live in the app image (`upload_max_filesize` / `post_max_size` = 64M).

If the live box still returns **413** with `nginx/…` via Caddy, the frontend container is almost certainly still on nginx’s default **1m**. After pulling updated docker configs:

```bash
cd ~/potatoaihub/docker
git pull origin master
COMPOSE="docker compose --env-file .env.production -f docker-compose.prod.yml"

# Confirm mounts point at the repo configs (not baked defaults)
$COMPOSE config | grep -E 'frontend.prod.conf|backend.prod.conf|Caddyfile'

# Recreate the proxies that enforce body size (no app rebuild needed)
$COMPOSE up -d --force-recreate frontend backend-nginx edge

# Verify 64M is active inside containers
$COMPOSE exec -T frontend nginx -T 2>/dev/null | grep client_max_body_size
$COMPOSE exec -T backend-nginx nginx -T 2>/dev/null | grep client_max_body_size
$COMPOSE exec -T edge caddy validate --config /etc/caddy/Caddyfile
```

No `.env.production` secret values need changing for this fix.

## Public Ports

Only expose these publicly in the EC2 security group:

- `22/tcp` from your IP only
- `80/tcp` from `0.0.0.0/0` and `::/0`
- `443/tcp` from `0.0.0.0/0` and `::/0`

Do not expose PostgreSQL, MongoDB, Redis, pgAdmin, Mongo Express, or Mailhog.

## Services

Production runs:

- Caddy edge proxy with automatic HTTPS
- React frontend served by Nginx
- Laravel PHP-FPM app
- Laravel backend Nginx
- PostgreSQL
- MongoDB
- Redis
- Laravel queue worker
- Laravel scheduler
- Laravel Reverb websocket worker
