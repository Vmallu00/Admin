#!/bin/bash
set -e

# =============================================
#  Pterodactyl Panel + Cloudflare Tunnel
#  Ubuntu 22.04 / 24.04
# =============================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Pterodactyl Panel + Cloudflare Tunnel (Full) ${NC}"
echo -e "${GREEN}================================================${NC}"

# Root check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root.${NC}"
   exit 1
fi

# ---- Prompt for all required data ----
echo -e "\n${YELLOW}Please provide the following information:${NC}"

# 1. Cloudflare Tunnel token (ONLY the token string, not the whole command)
while true; do
    read -p "Cloudflare Tunnel token (paste only the token string): " TOKEN
    if [[ -z "$TOKEN" ]]; then
        echo -e "${RED}❌ Token is required.${NC}"
        continue
    fi
    # Validate token length & base64 (approx)
    if [[ ${#TOKEN} -lt 50 ]]; then
        echo -e "${RED}❌ Token seems too short. Please copy the full token.${NC}"
        continue
    fi
    break
done

# 2. Domain
while true; do
    read -p "Domain (e.g., panel.yourdomain.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}❌ Domain is required.${NC}"
        continue
    fi
    break
done

# 3. Tunnel name
read -p "Tunnel name (default: pterodactyl-panel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-pterodactyl-panel}

# 4. Admin email
read -p "Admin email (default: admin@$DOMAIN): " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

# 5. Admin username
read -p "Admin username (default: admin): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

# 6. Admin password (with confirmation)
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

# 7. Database password (auto‑generate if empty)
read -s -p "Database password (press Enter to auto-generate): " DB_PASS
echo
if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-16)
    echo -e "${YELLOW}Auto-generated database password: $DB_PASS${NC}"
fi

echo -e "\n${GREEN}All inputs collected. Starting installation...${NC}"
sleep 2

# --------------------------------------------
# 1. Update system & install base packages
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

# Install service with the provided token
cloudflared service install "$TOKEN"
systemctl enable --now cloudflared

# Wait a moment and check status
sleep 3
if systemctl is-active --quiet cloudflared; then
    echo -e "${GREEN}✅ Cloudflared service is running.${NC}"
else
    echo -e "${RED}❌ Cloudflared failed to start. Check logs with: journalctl -u cloudflared${NC}"
    exit 1
fi

# --------------------------------------------
# 3. Install Pterodactyl Panel (fully automated)
# --------------------------------------------
echo -e "${GREEN}🐧 Step 3: Installing Pterodactyl Panel...${NC}"
echo -e "${YELLOW}Using BoryaGames installer with environment variables.${NC}"

export PTERO_EMAIL="$ADMIN_EMAIL"
export PTERO_USERNAME="$ADMIN_USER"
export PTERO_PASSWORD="$ADMIN_PASS"
export PTERO_DB_PASSWORD="$DB_PASS"

bash <(curl -s https://raw.githubusercontent.com/BoryaGames/pterodactyl-install/refs/heads/main/pterodactyl-install.sh) full

# --------------------------------------------
# 4. Configure Panel to use the domain
# --------------------------------------------
echo -e "${GREEN}🔧 Step 4: Configuring Panel for domain $DOMAIN...${NC}"
cd /var/www/pterodactyl || exit

# Update APP_URL
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env

# Update Nginx server_name
sed -i "s|server_name .*;|server_name $DOMAIN;|" /etc/nginx/sites-available/pterodactyl

# Restart Nginx
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

# Create DNS route (requires domain in Cloudflare)
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" || echo -e "${YELLOW}⚠️  DNS route failed – ensure your domain is in Cloudflare DNS.${NC}"

# Restart tunnel to pick up new config
systemctl restart cloudflared

# --------------------------------------------
# 6. Finalise and show credentials
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
echo -e "${YELLOW}💡 Useful commands:${NC}"
echo -e "  Check tunnel: ${BLUE}systemctl status cloudflared${NC}"
echo -e "  Check panel:  ${BLUE}systemctl status nginx${NC}"
echo -e "  View tunnel logs: ${BLUE}journalctl -u cloudflared -f${NC}"
echo ""
echo -e "${YELLOW}⚠️  If the tunnel doesn't work, ensure your domain's DNS is managed in Cloudflare.${NC}"
