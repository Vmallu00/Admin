#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Fixing Redis & Panel Services               ${NC}"
echo -e "${GREEN}================================================${NC}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root.${NC}"
   exit 1
fi

# 1. Install Redis
echo -e "${GREEN}📦 Installing Redis...${NC}"
apt update
apt install -y redis-server

# 2. Start Redis and enable on boot
echo -e "${GREEN}🚀 Starting Redis...${NC}"
systemctl start redis-server
systemctl enable redis-server

# Verify Redis is running
if systemctl is-active --quiet redis-server; then
    echo -e "${GREEN}✅ Redis is running.${NC}"
else
    echo -e "${RED}❌ Redis failed to start. Check logs: journalctl -u redis-server${NC}"
    exit 1
fi

# 3. Configure Panel .env for Redis (if not already set)
echo -e "${GREEN}🔧 Checking Panel .env configuration...${NC}"
cd /var/www/pterodactyl || exit

# Set Redis host (should be localhost, default)
sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|" .env
sed -i "s|REDIS_PORT=.*|REDIS_PORT=6379|" .env
sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=null|" .env

# 4. Clear cache and restart services
echo -e "${GREEN}🔄 Clearing cache and restarting services...${NC}"
php artisan config:clear
php artisan cache:clear
php artisan view:clear
php artisan queue:restart

# 5. Restart Nginx and PHP-FPM
systemctl restart nginx
systemctl restart php8.1-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || systemctl restart php8.0-fpm 2>/dev/null || echo -e "${YELLOW}⚠️  Could not restart PHP-FPM – check PHP version.${NC}"

# 6. Check panel health
echo -e "${GREEN}✅ Fix complete. Testing panel...${NC}"
curl -s -o /dev/null -w "Panel HTTP status: %{http_code}\n" http://localhost

# 7. Final message
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✅ All fixed!${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "Try accessing your panel again at ${BLUE}https://your-domain${NC}"
echo -e "If you still see 502, restart Nginx manually: ${BLUE}systemctl restart nginx${NC}"
