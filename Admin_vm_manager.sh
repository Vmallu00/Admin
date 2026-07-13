#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----- VM container settings -----
VM_CONTAINER_NAME="vm-container"
VM_IMAGE_NAME="vm-container"
VM_VOLUME_NAME="vm-data"
VM_DIR="/home/vmmgr/my-vm"
VM_SSH_PORT=2222
VM_PANEL_PORT=8080

# ----- Bot container settings -----
BOT_CONTAINER_NAME="discord-vps-bot"
BOT_COMPOSE_FILE="docker-compose.yml"
BOT_DATA_DIR="data"
BOT_VOLUME_NAME="bot-data"

# ----- Helper: check Docker -----
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}❌ Docker is not installed.${NC}"
        echo -e "${YELLOW}Install Docker: curl -fsSL https://get.docker.com | bash${NC}"
        exit 1
    fi
}

# ----- Helper: check docker-compose -----
get_compose_cmd() {
    if command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    elif docker compose version &>/dev/null; then
        echo "docker compose"
    else
        echo ""
    fi
}

# ----- VM Container Functions -----
build_vm_container() {
    echo -e "${GREEN}🔍 Detecting system resources for VM...${NC}"
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    ram_mb=$(( total_ram * 80 / 100 ))
    [[ $ram_mb -lt 2048 ]] && ram_mb=2048
    [[ $ram_mb -gt 8192 ]] && ram_mb=8192
    cpu_cores=$(nproc)
    disk_free=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    disk_size=$(( disk_free * 80 / 100 ))
    [[ $disk_size -lt 20 ]] && disk_size=20
    [[ $disk_size -gt 50 ]] && disk_size=50
    echo -e "   RAM: ${BLUE}${ram_mb}MB${NC}   CPU: ${BLUE}${cpu_cores} cores${NC}   Disk: ${BLUE}${disk_size}GB${NC}"
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        echo -e "${GREEN}✅ KVM available${NC}"
    else
        echo -e "${YELLOW}⚠️  KVM not available - using software emulation${NC}"
    fi

    echo -e "${GREEN}🐳 Building VM Docker image...${NC}"
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y \
    qemu-system-x86 qemu-utils curl wget git screen genisoimage openssl sudo \
    --no-install-recommends && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash -G sudo vmmgr && echo "vmmgr:password" | chpasswd
WORKDIR /home/vmmgr
COPY vm-manager.sh /home/vmmgr/vm-manager.sh
RUN chmod +x /home/vmmgr/vm-manager.sh
CMD ["/home/vmmgr/vm-manager.sh"]
EOF
    # Embed the VM manager script (the internal one)
    cat > vm-manager.sh <<'EOF'
#!/bin/bash
set -e
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
VM_DIR="/home/vmmgr/my-vm"
DISK_FILE="$VM_DIR/disk.qcow2"
SCREEN_NAME="vm-console"
SSH_PORT=2222
PANEL_PORT=8080
install_deps() {
    if command -v apt &>/dev/null; then
        apt update && apt install -y qemu-system-x86 qemu-utils curl genisoimage screen --no-install-recommends 2>/dev/null || true
    fi
}
create_vm() {
    if [[ -f "$DISK_FILE" ]]; then
        echo -e "${YELLOW}VM already exists.${NC}"
        return 0
    fi
    mkdir -p "$VM_DIR"
    cd "$VM_DIR"
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    ram_mb=$(( total_ram * 80 / 100 ))
    [[ $ram_mb -lt 2048 ]] && ram_mb=2048
    [[ $ram_mb -gt 8192 ]] && ram_mb=8192
    cpu_cores=$(nproc)
    disk_free=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    disk_size=$(( disk_free * 80 / 100 ))
    [[ $disk_size -lt 20 ]] && disk_size=20
    [[ $disk_size -gt 50 ]] && disk_size=50
    echo -e "   RAM: ${BLUE}${ram_mb}MB${NC}   CPU: ${BLUE}${cpu_cores} cores${NC}   Disk: ${BLUE}${disk_size}GB${NC}"
    echo "$ram_mb" > config.ram
    echo "$cpu_cores" > config.cpu
    IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    IMAGE_FILE="ubuntu-jammy-server-cloudimg-amd64.img"
    if [[ ! -f "$IMAGE_FILE" ]]; then
        curl -L -o "$IMAGE_FILE.tmp" "$IMAGE_URL"
        mv "$IMAGE_FILE.tmp" "$IMAGE_FILE"
    fi
    qemu-img create -f qcow2 -b "$IMAGE_FILE" -F qcow2 "$DISK_FILE" "${disk_size}G"
    cat > user-data <<USEREOF
#cloud-config
hostname: base-vm
manage_etc_hosts: true
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: \$(echo "admin" | openssl passwd -6 -stdin)
ssh_pwauth: true
chpasswd:
  expire: false
package_update: true
package_upgrade: true
packages:
  - curl - wget - git - htop - net-tools
USEREOF
    cat > meta-data <<METAEOF
instance-id: base-vm
local-hostname: base-vm
METAEOF
    genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data 2>/dev/null || mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data
    echo -e "${GREEN}✅ VM created.${NC}"
}
start_vm() {
    if ! command -v screen &>/dev/null; then install_deps; fi
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -r "$SCREEN_NAME"
        return 0
    fi
    if [[ ! -f "$DISK_FILE" ]]; then
        echo -e "${RED}❌ VM disk not found. Run 'create' first.${NC}"
        return 1
    fi
    cd "$VM_DIR"
    ram_mb=$(cat config.ram 2>/dev/null || echo "2048")
    cpu_cores=$(cat config.cpu 2>/dev/null || echo "2")
    CMD="qemu-system-x86_64 -m ${ram_mb} -smp cores=${cpu_cores}"
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        CMD+=" -enable-kvm -cpu host"
        echo -e "${GREEN}✅ KVM enabled${NC}"
    else
        echo -e "${YELLOW}⚠️ Software emulation${NC}"
    fi
    CMD+=" -drive file=${DISK_FILE},format=qcow2 -cdrom seed.iso -nic user,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${PANEL_PORT}-:80 -nographic"
    echo -e "${GREEN}Starting VM...${NC}"
    screen -dmS "$SCREEN_NAME" bash -c "$CMD; exec bash"
    sleep 2
    screen -r "$SCREEN_NAME"
}
stop_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -S "$SCREEN_NAME" -X quit
        echo -e "${GREEN}VM stopped.${NC}"
    else
        echo -e "${YELLOW}VM not running.${NC}"
    fi
}
status_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo -e "${GREEN}✅ Running. Attach: screen -r $SCREEN_NAME${NC}"
    else
        echo -e "${RED}❌ Stopped.${NC}"
    fi
}
console_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -r "$SCREEN_NAME"
    else
        echo -e "${RED}❌ Not running.${NC}"
    fi
}
case "$1" in
    start) create_vm; start_vm ;;
    stop) stop_vm ;;
    status) status_vm ;;
    console) console_vm ;;
    *)
        echo ""
        echo -e "${GREEN}================================================${NC}"
        echo -e "${GREEN}   Ubuntu VM (inside container)              ${NC}"
        echo -e "${GREEN}================================================${NC}"
        echo "  1) Create VM"
        echo "  2) Start VM (console)"
        echo "  3) Stop VM"
        echo "  4) Status"
        echo "  5) Attach console"
        echo "  0) Exit"
        read -p "Choice: " choice
        case $choice in
            1) create_vm ;;
            2) start_vm ;;
            3) stop_vm ;;
            4) status_vm ;;
            5) console_vm ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
        ;;
esac
EOF
    docker build -t "$VM_IMAGE_NAME" . >/dev/null 2>&1
    if ! docker volume ls | grep -q "$VM_VOLUME_NAME"; then
        docker volume create "$VM_VOLUME_NAME" >/dev/null
    fi
    cd - >/dev/null
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✅ VM Docker image built. Volume: $VM_VOLUME_NAME${NC}"
}

start_vm_container() {
    echo -e "${GREEN}🚀 Starting VM container...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -q "^${VM_CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${VM_CONTAINER_NAME}$"; then
            echo -e "${YELLOW}Container already running. Attaching...${NC}"
            docker attach "$VM_CONTAINER_NAME"
            return 0
        else
            echo -e "${YELLOW}Container exists, starting...${NC}"
            docker start -ai "$VM_CONTAINER_NAME"
            return 0
        fi
    fi
    KVM_OPTION=""
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        KVM_OPTION="--device /dev/kvm"
    fi
    docker run --rm -it --privileged $KVM_OPTION \
        -v "${VM_VOLUME_NAME}:${VM_DIR}" \
        -p ${VM_SSH_PORT}:${VM_SSH_PORT} \
        -p ${VM_PANEL_PORT}:${VM_PANEL_PORT} \
        --name "$VM_CONTAINER_NAME" "$VM_IMAGE_NAME"
}

stop_vm_container() {
    echo -e "${RED}🛑 Stopping VM container...${NC}"
    docker stop "$VM_CONTAINER_NAME" 2>/dev/null && echo -e "${GREEN}✅ Stopped.${NC}" || echo -e "${YELLOW}Container not running.${NC}"
}

status_vm_container() {
    if docker ps --format '{{.Names}}' | grep -q "^${VM_CONTAINER_NAME}$"; then
        echo -e "${GREEN}✅ VM container is running.${NC}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${VM_CONTAINER_NAME}$"; then
        echo -e "${YELLOW}VM container exists but is stopped.${NC}"
    else
        echo -e "${RED}VM container not found.${NC}"
    fi
}

# ----- Discord Bot Functions -----
setup_bot() {
    echo -e "${GREEN}🤖 Setting up Discord Bot...${NC}"
    # Check if bot.py exists
    if [ ! -f "bot.py" ]; then
        echo -e "${RED}❌ bot.py not found in current directory.${NC}"
        return 1
    fi
    # Ask for token
    read -sp "Enter your Discord bot token: " TOKEN
    echo
    if [ -z "$TOKEN" ]; then
        echo -e "${RED}❌ Token required.${NC}"
        return 1
    fi
    # Create files
    cat > Dockerfile.bot <<'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bot.py .
COPY data /app/data
RUN useradd -m -u 1000 botuser && chown -R botuser:botuser /app
USER botuser
CMD ["python", "bot.py"]
EOF
    cat > requirements.txt <<'EOF'
discord.py==2.4.0
docker==7.1.0
python-dotenv==1.0.1
colorama==0.4.6
EOF
    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  discord-bot:
    build:
      context: .
      dockerfile: Dockerfile.bot
    container_name: ${BOT_CONTAINER_NAME}
    restart: unless-stopped
    environment:
      - TOKEN=${TOKEN}
      - SERVER_IP=${SERVER_IP:-138.68.79.95}
      - QR_IMAGE=${QR_IMAGE:-https://raw.githubusercontent.com/deadlauncherg/PUFFER-PANEL-IN-FIREBASE/main/qr.jpg}
      - IMAGE=${IMAGE:-jrei/systemd-ubuntu:22.04}
      - DEFAULT_RAM_GB=${DEFAULT_RAM_GB:-32}
      - DEFAULT_CPU=${DEFAULT_CPU:-6}
      - DEFAULT_DISK_GB=${DEFAULT_DISK_GB:-100}
      - POINTS_PER_DEPLOY=${POINTS_PER_DEPLOY:-4}
      - POINTS_RENEW_15=${POINTS_RENEW_15:-3}
      - POINTS_RENEW_30=${POINTS_RENEW_30:-5}
      - VPS_LIFETIME_DAYS=${VPS_LIFETIME_DAYS:-15}
      - GUILD_ID=${GUILD_ID:-1432390408184529084}
      - OWNER_ID=${OWNER_ID:-1447083500720230401}
    volumes:
      - ${BOT_VOLUME_NAME}:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - DOCKER_HOST=unix:///var/run/docker.sock
volumes:
  ${BOT_VOLUME_NAME}:
EOF
    mkdir -p data
    COMPOSE_CMD=$(get_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        echo -e "${RED}❌ docker-compose not available.${NC}"
        return 1
    fi
    $COMPOSE_CMD up -d --build
    echo -e "${GREEN}✅ Bot container started.${NC}"
}

start_bot() {
    COMPOSE_CMD=$(get_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        echo -e "${RED}❌ docker-compose not available.${NC}"
        return 1
    fi
    if [ ! -f "$BOT_COMPOSE_FILE" ]; then
        echo -e "${RED}❌ Bot not set up. Run option 5 first.${NC}"
        return 1
    fi
    echo -e "${GREEN}🚀 Starting bot container...${NC}"
    $COMPOSE_CMD up -d
    echo -e "${GREEN}✅ Bot started.${NC}"
}

stop_bot() {
    COMPOSE_CMD=$(get_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        echo -e "${RED}❌ docker-compose not available.${NC}"
        return 1
    fi
    if [ ! -f "$BOT_COMPOSE_FILE" ]; then
        echo -e "${RED}❌ Bot not set up.${NC}"
        return 1
    fi
    echo -e "${RED}🛑 Stopping bot container...${NC}"
    $COMPOSE_CMD down
    echo -e "${GREEN}✅ Bot stopped.${NC}"
}

status_bot() {
    if docker ps --format '{{.Names}}' | grep -q "^${BOT_CONTAINER_NAME}$"; then
        echo -e "${GREEN}✅ Bot container is running.${NC}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${BOT_CONTAINER_NAME}$"; then
        echo -e "${YELLOW}Bot container exists but is stopped.${NC}"
    else
        echo -e "${RED}Bot container not found.${NC}"
    fi
}

bot_logs() {
    COMPOSE_CMD=$(get_compose_cmd)
    if [ -z "$COMPOSE_CMD" ]; then
        echo -e "${RED}❌ docker-compose not available.${NC}"
        return 1
    fi
    if [ ! -f "$BOT_COMPOSE_FILE" ]; then
        echo -e "${RED}❌ Bot not set up.${NC}"
        return 1
    fi
    $COMPOSE_CMD logs -f
}

# ----- Main Menu -----
main_menu() {
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}   VM + Bot Manager                           ${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo -e "${YELLOW}------ VM Container ------${NC}"
    echo "  1) 🐳 Build VM container (auto-detect)"
    echo "  2) 🚀 Start VM container (enter terminal)"
    echo "  3) 🛑 Stop VM container"
    echo "  4) 📊 VM container status"
    echo ""
    echo -e "${YELLOW}------ Discord Bot ------${NC}"
    echo "  5) 🤖 Setup Discord Bot (first time)"
    echo "  6) ▶️  Start Discord Bot (background)"
    echo "  7) ⏹️  Stop Discord Bot"
    echo "  8) 📊 Bot status"
    echo "  9) 📜 Bot logs"
    echo ""
    echo "  0) 👋 Exit"
    echo ""
    read -p "Choice: " choice
    case $choice in
        1) build_vm_container ;;
        2) start_vm_container ;;
        3) stop_vm_container ;;
        4) status_vm_container ;;
        5) setup_bot ;;
        6) start_bot ;;
        7) stop_bot ;;
        8) status_bot ;;
        9) bot_logs ;;
        0) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid choice.${NC}" ;;
    esac
}

# ----- Start -----
check_docker
while true; do
    main_menu
    echo ""
    read -p "Press Enter to continue..."
done
