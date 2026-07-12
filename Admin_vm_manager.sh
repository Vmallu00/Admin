#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Pterodactyl Panel + Cloudflare Tunnel (Full) ${NC}"
echo -e "${GREEN}================================================${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}"
   exit 1
fi

# ---- Gather all inputs ----
echo -e "\n${YELLOW}Please provide the following information:${NC}"

read -p "Cloudflare Tunnel token: " TOKEN
if [[ -z "$TOKEN" ]]; then
    echo -e "${RED}❌ Token is required.${NC}"
    exit 1
fi

read -p "Domain (e.g., panel.yourdomain.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}❌ Domain is required.${NC}"
    exit 1
fi

read -p "Tunnel name (default: pterodactyl-panel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-pterodactyl-panel}

read -p "Admin email (default: admin@$DOMAIN): " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

read -p "Admin username (default: admin): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

while true; do
    read -s -p "Admin password: " ADMIN_PASS
    echo
    read -s -p "Confirm admin password: " ADMIN_PASS_CONF
    echo
    if [[ "$ADMIN_PASS" == "$ADMIN_PASS_CONF" && -n "$ADMIN_PASS" ]]; then
        break
    else
        echo -e "${RED}Passwords do not match or are empty. Try again.${NC}"
    fi
done

# Generate a random database password if not provided
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
# 2. Install cloudflared
# --------------------------------------------
echo -e "${GREEN}🌐 Step 2: Installing Cloudflare Tunnel...${NC}"
wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared-linux-amd64
mv cloudflared-linux-amd64 /usr/local/bin/cloudflared
cloudflared --version

# Install service with token
cloudflared service install "$TOKEN"
systemctl enable --now cloudflared
sleep 2

# --------------------------------------------
# 3. Install Pterodactyl Panel (non-interactive)
# --------------------------------------------
echo -e "${GREEN}🐧 Step 3: Installing Pterodactyl Panel (fully automated)...${NC}"
echo -e "${YELLOW}Using BoryaGames installer with environment variables.${NC}"

export PTERO_EMAIL="$ADMIN_EMAIL"
export PTERO_USERNAME="$ADMIN_USER"
export PTERO_PASSWORD="$ADMIN_PASS"
export PTERO_DB_PASSWORD="$DB_PASS"

bash <(curl -s https://raw.githubusercontent.com/BoryaGames/pterodactyl-install/refs/heads/main/pterodactyl-install.sh) full

# --------------------------------------------
# 4. Configure Panel for the domain
# --------------------------------------------
echo -e "${GREEN}🔧 Step 4: Configuring Panel for domain $DOMAIN...${NC}"
cd /var/www/pterodactyl || exit
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env
sed -i "s|server_name .*;|server_name $DOMAIN;|" /etc/nginx/sites-available/pterodactyl
systemctl restart nginx

# --------------------------------------------
# 5. Configure Cloudflare Tunnel ingress
# --------------------------------------------
echo -e "${GREEN}🌐 Step 5: Configuring Cloudflare Tunnel for $DOMAIN...${NC}"
mkdir -p /root/.cloudflared
cat > /root/.cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
credentials-file: /root/.cloudflared/credentials.json
ingress:
  - hostname: $DOMAIN
    service: http://localhost:80
  - service: http_status:404
EOF

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" || echo -e "${YELLOW}⚠️  DNS route may already exist or DNS not in Cloudflare.${NC}"
systemctl restart cloudflared

# --------------------------------------------
# 6. Done
# --------------------------------------------
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✅ Installation complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "🔗 Access your panel: ${BLUE}https://$DOMAIN${NC}"
echo -e "🔒 SSL is provided by Cloudflare (flexible mode)."
echo -e "👤 Admin login: ${BLUE}$ADMIN_USER${NC} / your password."
echo -e "📧 Admin email: ${BLUE}$ADMIN_EMAIL${NC}"
echo -e "🗄️  Database password: ${BLUE}$DB_PASS${NC} (save this!)"
echo ""
echo -e "${YELLOW}💡 Useful commands:${NC}"
echo -e "  - Tunnel status: ${BLUE}systemctl status cloudflared${NC}"
echo -e "  - Panel status:  ${BLUE}systemctl status nginx${NC}"
echo -e "  - Tunnel logs:   ${BLUE}journalctl -u cloudflared -f${NC}"
