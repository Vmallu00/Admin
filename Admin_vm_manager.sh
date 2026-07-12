#!/bin/bash
set -e

# --- Usage ---
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 --token TOKEN --domain DOMAIN [--tunnel NAME]"
    echo "  --token    Cloudflare Tunnel token (required)"
    echo "  --domain   Your domain (e.g., panel.example.com) (required)"
    echo "  --tunnel   Tunnel name (default: pterodactyl-panel)"
    exit 0
fi

# Parse arguments
TOKEN=""
DOMAIN=""
TUNNEL_NAME="pterodactyl-panel"

while [[ $# -gt 0 ]]; do
    case $1 in
        --token) TOKEN="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --tunnel) TUNNEL_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$TOKEN" || -z "$DOMAIN" ]]; then
    echo "❌ Both --token and --domain are required."
    exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Pterodactyl Panel + Cloudflare Tunnel (Auto) ${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Token: ${TOKEN:0:10}..."
echo "Domain: $DOMAIN"
echo "Tunnel: $TUNNEL_NAME"

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}"
   exit 1
fi

# --------------------------------------------
# 1. Install base deps
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
echo -e "${GREEN}Installing cloudflared service with provided token...${NC}"
cloudflared service install "$TOKEN"
systemctl enable --now cloudflared
sleep 2
if systemctl is-active --quiet cloudflared; then
    echo -e "${GREEN}✅ Cloudflared service is running.${NC}"
else
    echo -e "${YELLOW}⚠️  Cloudflared service failed to start. Check logs: journalctl -u cloudflared${NC}"
fi

# --------------------------------------------
# 3. Install Pterodactyl Panel (non-interactive)
# --------------------------------------------
echo -e "${GREEN}🐧 Step 3: Installing Pterodactyl Panel...${NC}"
echo -e "${YELLOW}Using the official installer. It will ask for database and admin credentials.${NC}"
echo -e "${YELLOW}We recommend: DB: pterodactyl, User: pterodactyl, Pass: a strong one.${NC}"
echo -e "${YELLOW}Admin: admin@$DOMAIN / your password.${NC}"
echo -e "${YELLOW}Press Enter to continue, or Ctrl+C to abort.${NC}"
read

# Use the official installer (panel only)
bash <(curl -s https://pterodactyl-installer.se) -panel

# --------------------------------------------
# 4. Configure Panel to use domain
# --------------------------------------------
echo -e "${GREEN}🔧 Step 4: Configuring Panel for domain $DOMAIN...${NC}"
cd /var/www/pterodactyl || exit
# Update .env
sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" .env
# Update Nginx server_name
sed -i "s|server_name .*;|server_name $DOMAIN;|" /etc/nginx/sites-available/pterodactyl
systemctl restart nginx

echo -e "${GREEN}Panel configured for https://$DOMAIN${NC}"

# --------------------------------------------
# 5. Set up Cloudflare Tunnel ingress
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

# Route DNS (assumes domain is already in Cloudflare)
cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" || echo -e "${YELLOW}⚠️  DNS route may already exist or DNS not in Cloudflare.${NC}"

# Restart tunnel
systemctl restart cloudflared

echo -e "${GREEN}✅ Tunnel configured for $DOMAIN${NC}"

# --------------------------------------------
# 6. Final message
# --------------------------------------------
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✅ Installation complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "🔗 Access your panel: ${BLUE}https://$DOMAIN${NC}"
echo -e "🔒 SSL is handled by Cloudflare (flexible mode)."
echo -e "👤 Admin login: The credentials you set during the installer."
echo ""
echo -e "${YELLOW}💡 Useful commands:${NC}"
echo -e "  - Tunnel status: ${BLUE}systemctl status cloudflared${NC}"
echo -e "  - Panel status:  ${BLUE}systemctl status nginx${NC}"
echo -e "  - Tunnel logs:   ${BLUE}journalctl -u cloudflared -f${NC}"
echo -e "  - Re-route DNS:  ${BLUE}cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN${NC}"
