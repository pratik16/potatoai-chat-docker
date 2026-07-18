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
