# PotatoAI Production Deployment

Production uses separate Docker assets from local development:

- Local: `docker-compose.yml` plus optional `docker-compose.override.yml`
- Production: `docker-compose.prod.yml` with `.env.production`
- Frontend production runtime serves compiled files from `~/potatoaihub/frontend-dist`

Do not commit `.env.production`.
Do not put frontend `node_modules` or source builds inside Docker runtime containers.

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
curl -I https://cpanel.potatoaihub.com/livewire/livewire.js   # must be 200, not 404
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
