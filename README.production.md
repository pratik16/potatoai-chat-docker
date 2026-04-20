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
