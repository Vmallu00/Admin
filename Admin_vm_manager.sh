#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Fix & Start Pterodactyl Panel Services      ${NC}"
echo -e "${GREEN}================================================${NC}"

# 1. Create necessary directories for PHP-FPM
echo -e "${GREEN}📁 Creating /run/php directory...${NC}"
mkdir -p /run/php
chown -R www-data:www-data /run/php

# 2. Start Redis (if not running)
echo -e "${GREEN}🔴 Starting Redis...${NC}"
if pgrep -x "redis-server" > /dev/null; then
    echo -e "${YELLOW}Redis is already running.${NC}"
else
    redis-server --daemonize yes
    sleep 1
    if pgrep -x "redis-server" > /dev/null; then
        echo -e "${GREEN}✅ Redis started.${NC}"
    else
        echo -e "${RED}❌ Redis failed to start.${NC}"
    fi
fi

# 3. Detect PHP version and start PHP-FPM
echo -e "${GREEN}🐘 Starting PHP-FPM...${NC}"
PHP_FPM=""
for version in 8.3 8.2 8.1 8.0; do
    if command -v php-fpm$version > /dev/null; then
        PHP_FPM="php-fpm$version"
        break
    fi
done
if [[ -z "$PHP_FPM" ]]; then
    if command -v php-fpm > /dev/null; then
        PHP_FPM="php-fpm"
    fi
fi

if [[ -n "$PHP_FPM" ]]; then
    if pgrep -f "$PHP_FPM" > /dev/null; then
        echo -e "${YELLOW}PHP-FPM is already running.${NC}"
    else
        # Ensure the socket directory exists before starting
        mkdir -p /run/php
        $PHP_FPM -D
        sleep 2
        if pgrep -f "$PHP_FPM" > /dev/null; then
            echo -e "${GREEN}✅ PHP-FPM started ($PHP_FPM).${NC}"
        else
            echo -e "${RED}❌ PHP-FPM failed to start. Check logs: tail -f /var/log/php*-fpm.log${NC}"
        fi
    fi
else
    echo -e "${RED}❌ No PHP-FPM found.${NC}"
fi

# 4. Start Nginx
echo -e "${GREEN}🌐 Starting Nginx...${NC}"
if pgrep -x "nginx" > /dev/null; then
    echo -e "${YELLOW}Nginx is already running.${NC}"
else
    nginx -g "daemon off;" &
    sleep 2
    if pgrep -x "nginx" > /dev/null; then
        echo -e "${GREEN}✅ Nginx started.${NC}"
    else
        echo -e "${RED}❌ Nginx failed to start.${NC}"
    fi
fi

# 5. Ensure panel .env has correct Redis config
echo -e "${GREEN}🔧 Configuring Panel .env for Redis...${NC}"
if [[ -d /var/www/pterodactyl ]]; then
    cd /var/www/pterodactyl || exit
    sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env
    sed -i "s|REDIS_PORT=.*|REDIS_PORT=6379|" .env
    sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=null|" .env
else
    echo -e "${RED}❌ Pterodactyl panel not found in /var/www/pterodactyl${NC}"
fi

# 6. Clear cache and run migrations
echo -e "${GREEN}🗑️  Clearing cache...${NC}"
php artisan config:clear
php artisan cache:clear
php artisan view:clear

echo -e "${GREEN}📦 Running migrations...${NC}"
php artisan migrate --force

# 7. Restart queue worker
echo -e "${GREEN}🔄 Restarting queue worker...${NC}"
php artisan queue:restart

# 8. Check services
echo -e "${GREEN}✅ Services started.${NC}"
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Panel should now be accessible               ${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "Try visiting your domain: ${BLUE}https://your-domain${NC}"
echo ""
echo -e "${YELLOW}💡 To keep services running:${NC}"
echo -e "   Use 'screen' or 'tmux' to run this script in the background."
echo ""
echo -e "${YELLOW}💡 Check service status:${NC}"
echo -e "   Redis:   ${BLUE}ps aux | grep redis${NC}"
echo -e "   PHP-FPM: ${BLUE}ps aux | grep php-fpm${NC}"
echo -e "   Nginx:   ${BLUE}ps aux | grep nginx${NC}"
