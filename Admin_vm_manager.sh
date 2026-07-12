#!/bin/bash
set -e

# =============================================
#  Pterodactyl Panel Only (No Cloudflare)
#  Ubuntu 22.04 / 24.04
# =============================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}       Pterodactyl Panel Installer             ${NC}"
echo -e "${GREEN}================================================${NC}"

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root.${NC}"
   exit 1
fi

# ---- Gather inputs ----
echo -e "\n${YELLOW}Please provide the following information:${NC}"

read -p "Domain (e.g., panel.yourdomain.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}❌ Domain is required.${NC}"
    exit 1
fi

read -p "Admin email (default: admin@$DOMAIN): " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

read -p "Admin username (default: admin): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

while true; do
    read -s -p "Admin password: " ADMIN_PASS
    echo
    read -s -p "Confirm admin password: " ADMIN_PASS_CONF
    echo
    if [[ -z "$ADMIN_PASS" ]]; then
        echo -e "${RED}❌ Password cannot be empty.${NC}"
    elif [[ "$ADMIN_PASS" == "$ADMIN_PASS_CONF" ]]; then
        break
    else
        echo -e "${RED}❌ Passwords do not match.${NC}"
    fi
done

read -s -p "Database password (press Enter to auto-generate): " DB_PASS
echo
if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-16)
    echo -e "${YELLOW}Auto-generated database password: $DB_PASS${NC}"
fi

echo -e "\n${GREEN}All inputs collected. Starting installation...${NC}"
sleep 2

# --------------------------------------------
# 1. Install base dependencies
# --------------------------------------------
echo -e "${GREEN}📦 Step 1: Installing system dependencies...${NC}"
apt update && apt upgrade -y
apt install -y curl wget git unzip software-properties-common \
    gnupg2 ca-certificates lsb-release apt-transport-https \
    zip unzip openssl

# --------------------------------------------
# 2. Install Pterodactyl Panel (auto, no prompts)
# --------------------------------------------
echo -e "${GREEN}🐧 Step 2: Installing Pterodactyl Panel...${NC}"
echo -e "${YELLOW}Using BoryaGames installer with environment variables.${NC}"

export PTERO_EMAIL="$ADMIN_EMAIL"
export PTERO_USERNAME="$ADMIN_USER"
export PTERO_PASSWORD="$ADMIN_PASS"
export PTERO_DB_PASSWORD="$DB_PASS"

# The 'panel' option installs only the panel (no Wings)
bash <(curl -s https://raw.githubusercontent.com/BoryaGames/pterodactyl-install/refs/heads/main/pterodactyl-install.sh) panel

# --------------------------------------------
# 3. Configure Panel for the domain
# --------------------------------------------
echo -e "${GREEN}🔧 Step 3: Configuring Panel for domain $DOMAIN...${NC}"
cd /var/www/pterodactyl || exit

# Update .env with the domain (HTTPS because Cloudflare provides SSL)
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env

# Update Nginx server_name
sed -i "s|server_name .*;|server_name $DOMAIN;|" /etc/nginx/sites-available/pterodactyl

# Restart Nginx
systemctl restart nginx

# --------------------------------------------
# 4. Show credentials
# --------------------------------------------
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✅ Installation complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "🔗 Panel URL:      ${BLUE}https://$DOMAIN${NC}"
echo -e "👤 Admin login:    ${BLUE}$ADMIN_USER${NC}"
echo -e "📧 Admin email:    ${BLUE}$ADMIN_EMAIL${NC}"
echo -e "🔑 Admin password: ${BLUE}$ADMIN_PASS${NC} (save this!)"
echo -e "🗄️  DB password:    ${BLUE}$DB_PASS${NC} (save this!)"
echo ""
echo -e "${YELLOW}💡 Next Steps:${NC}"
echo -e "  1. Visit your panel at ${BLUE}https://$DOMAIN${NC}"
echo -e "  2. Log in with the admin credentials above."
echo -e "  3. Configure your Wings nodes from the Admin area if needed."
echo ""
echo -e "${GREEN}Your panel is ready! 🎉${NC}"
