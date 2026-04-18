@echo off
echo ========================================
echo  PotatoAI Docker Setup
echo ========================================
echo.

REM Step 1: Copy environment file
echo [1/6] Setting up environment...
if not exist "..\backend\.env" (
    copy /Y .env.example ..\backend\.env >nul
    echo      Copied .env.example to backend\.env
    echo      IMPORTANT: Open backend\.env and fill in APP_KEY and any missing secrets before continuing.
    pause
) else (
    echo      backend\.env already exists, skipping copy.
)

REM Step 2: Build Docker images
echo.
echo [2/6] Building Docker images (this may take a few minutes)...
docker compose -f docker-compose.yml build
if %ERRORLEVEL% neq 0 (
    echo ERROR: Docker build failed. Is Docker Desktop running?
    pause
    exit /b 1
)

REM Step 3: Start infrastructure services first
echo.
echo [3/6] Starting infrastructure services (postgres, mongodb, redis)...
docker compose -f docker-compose.yml up -d postgres mongodb redis mailhog
echo      Waiting for databases to become healthy...
timeout /t 15 /nobreak >nul

REM Step 4: Start all remaining services
echo.
echo [4/6] Starting all services...
docker compose -f docker-compose.yml up -d

REM Step 5: Install Composer dependencies and generate key
echo.
echo [5/6] Installing Composer dependencies...
docker compose -f docker-compose.yml run --rm app composer install --no-interaction
docker compose -f docker-compose.yml exec app php artisan key:generate

REM Step 6: Run migrations
echo.
echo [6/6] Running migrations...
docker compose -f docker-compose.yml exec app php artisan migrate --force

echo.
echo ========================================
echo  Setup Complete!
echo ========================================
echo.
echo Services:
echo   Angular Frontend:  http://localhost:4200
echo   Laravel Backend:   http://localhost:8000
echo   WebSockets:        ws://localhost:6001
echo   Mailhog UI:        http://localhost:8025
echo   pgAdmin:           http://localhost:8080  (admin@admin.com / admin)
echo   Mongo Express:     http://localhost:8081  (admin / admin)
echo.
echo Useful commands:
echo   docker compose -f docker\docker-compose.yml logs -f          View logs
echo   docker compose -f docker\docker-compose.yml exec app bash    Shell into app
echo   docker compose -f docker\docker-compose.yml down             Stop all
echo.
pause
