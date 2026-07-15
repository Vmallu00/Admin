#!/bin/bash
set -e

# ==============================================
#  Docker VM Container Manager (Ubuntu 24.04 + LXD)
#  Option 1: Build container (auto-detect)
#  Option 2: Start container (auto-enter terminal)
#  Option 3: Stop container
# ==============================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTAINER_NAME="vm-container"
IMAGE_NAME="vm-container"
VOLUME_NAME="vm-data"
VM_DIR="/home/vmmgr/my-vm"
SSH_PORT=2222
PANEL_PORT=8080

# ------------------- Check Docker -------------------
if ! command -v docker &>/dev/null; then
    echo -e "${RED}❌ Docker is not installed.${NC}"
    echo -e "${YELLOW}Install Docker: curl -fsSL https://get.docker.com | bash${NC}"
    exit 1
fi

# ------------------- Function: Build Container -------------------
build_container() {
    echo -e "${GREEN}🔍 Detecting system resources...${NC}"
    
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    ram_mb=$(( total_ram * 80 / 100 ))
    [[ $ram_mb -lt 2048 ]] && ram_mb=2048
    [[ $ram_mb -gt 8192 ]] && ram_mb=8192
    
    cpu_cores=$(nproc)
    
    disk_free=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    disk_size=$(( disk_free * 80 / 100 ))
    [[ $disk_size -lt 20 ]] && disk_size=20
    [[ $disk_size -gt 50 ]] && disk_size=50
    
    echo -e "   RAM: ${BLUE}${ram_mb}MB${NC}"
    echo -e "   CPU: ${BLUE}${cpu_cores} cores${NC}"
    echo -e "   Disk: ${BLUE}${disk_size}GB${NC}"
    
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        echo -e "${GREEN}✅ KVM available${NC}"
    else
        echo -e "${YELLOW}⚠️  KVM not available - using software emulation${NC}"
    fi
    
    echo -e "${GREEN}🐳 Building Docker image '${IMAGE_NAME}'...${NC}"
    
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    cat > Dockerfile <<'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    qemu-system-x86 \
    qemu-utils \
    curl \
    wget \
    git \
    screen \
    genisoimage \
    openssl \
    sudo \
    --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash -G sudo vmmgr && echo "vmmgr:password" | chpasswd

WORKDIR /home/vmmgr
COPY vm-manager.sh /home/vmmgr/vm-manager.sh
RUN chmod +x /home/vmmgr/vm-manager.sh

CMD ["/home/vmmgr/vm-manager.sh"]
EOF

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
    echo -e "   RAM: ${BLUE}${ram_mb}MB${NC}"
    echo -e "   CPU: ${BLUE}${cpu_cores} cores${NC}"
    echo -e "   Disk: ${BLUE}${disk_size}GB${NC}"
    echo "$ram_mb" > config.ram
    echo "$cpu_cores" > config.cpu

    # ---- Use Ubuntu 24.04 (Noble) cloud image ----
    IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    IMAGE_FILE="ubuntu-noble-server-cloudimg-amd64.img"
    if [[ ! -f "$IMAGE_FILE" ]]; then
        echo "Downloading Ubuntu 24.04 image..."
        curl -L -o "$IMAGE_FILE.tmp" "$IMAGE_URL"
        mv "$IMAGE_FILE.tmp" "$IMAGE_FILE"
    fi
    qemu-img create -f qcow2 -b "$IMAGE_FILE" -F qcow2 "$DISK_FILE" "${disk_size}G"

    # ---- Cloud-init: install LXD and basic tools ----
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
  - curl
  - wget
  - git
  - htop
  - net-tools
  - lxd
  - lxd-client
runcmd:
  - lxd init --auto
  - lxc network create lxdbr0 || true
  - echo "LXD installed and initialized."
USEREOF
    cat > meta-data <<METAEOF
instance-id: base-vm
local-hostname: base-vm
METAEOF
    genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data 2>/dev/null || mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data

    echo -e "${GREEN}✅ Ubuntu 24.04 VM created with LXD pre-installed.${NC}"
    echo -e "${YELLOW}You can manage LXD containers inside the VM.${NC}"
}

start_vm() {
    if ! command -v screen &>/dev/null; then install_deps; fi
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo -e "${YELLOW}VM already running. Attaching...${NC}"
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
        echo -e "${GREEN}✅ KVM acceleration enabled.${NC}"
    else
        echo -e "${YELLOW}⚠️  Using software emulation.${NC}"
    fi
    CMD+=" -drive file=${DISK_FILE},format=qcow2 -cdrom seed.iso -nic user,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${PANEL_PORT}-:80 -nographic"
    echo -e "${GREEN}🚀 Starting VM...${NC}"
    echo -e "   SSH: ${BLUE}ssh -p ${SSH_PORT} admin@localhost${NC} (password: admin)"
    echo -e "   Web port forwarded: ${BLUE}localhost:${PANEL_PORT} → VM:80${NC}"
    screen -dmS "$SCREEN_NAME" bash -c "$CMD; exec bash"
    sleep 2
    screen -r "$SCREEN_NAME"
}

stop_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -S "$SCREEN_NAME" -X quit
        echo -e "${GREEN}✅ VM stopped.${NC}"
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
        echo -e "${RED}❌ VM not running.${NC}"
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
        echo -e "${GREEN}   Ubuntu 24.04 VM with LXD                 ${NC}"
        echo -e "${GREEN}================================================${NC}"
        echo "  1) Create VM"
        echo "  2) Start VM (with console)"
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

    docker build -t "$IMAGE_NAME" . 2>&1 | grep -v "^#" || true

    if ! docker volume ls | grep -q "$VOLUME_NAME"; then
        echo -e "${GREEN}📀 Creating persistent volume '${VOLUME_NAME}'...${NC}"
        docker volume create "$VOLUME_NAME" >/dev/null
    fi

    echo -e "${GREEN}✅ Docker image built successfully.${NC}"
    echo -e "${GREEN}   Image: ${BLUE}${IMAGE_NAME}${NC}"
    echo -e "${GREEN}   Volume: ${BLUE}${VOLUME_NAME}${NC}"
    cd - >/dev/null
    rm -rf "$TEMP_DIR"
}

# ------------------- Function: Start Container -------------------
start_container() {
    echo -e "${GREEN}🚀 Starting Docker container...${NC}"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo -e "${YELLOW}Container is already running. Attaching...${NC}"
            docker attach "$CONTAINER_NAME"
            return 0
        else
            echo -e "${YELLOW}Container exists but is stopped. Starting...${NC}"
            docker start -ai "$CONTAINER_NAME"
            return 0
        fi
    fi
    
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        KVM_OPTION="--device /dev/kvm"
        echo -e "${GREEN}✅ KVM available${NC}"
    else
        KVM_OPTION=""
        echo -e "${YELLOW}⚠️  KVM not available - using software emulation${NC}"
    fi
    
    docker run --rm -it \
        --privileged \
        $KVM_OPTION \
        -v "${VOLUME_NAME}:${VM_DIR}" \
        -p ${SSH_PORT}:${SSH_PORT} \
        -p ${PANEL_PORT}:${PANEL_PORT} \
        --name "$CONTAINER_NAME" \
        "$IMAGE_NAME"
}

# ------------------- Function: Stop Container -------------------
stop_container() {
    echo -e "${RED}🛑 Stopping Docker container...${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME"
        echo -e "${GREEN}✅ Container stopped.${NC}"
    else
        echo -e "${YELLOW}Container is not running.${NC}"
    fi
}

# ------------------- Function: Status -------------------
status_container() {
    echo -e "${GREEN}📊 Container Status:${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "   Status: ${GREEN}Running${NC}"
        docker ps --filter "name=${CONTAINER_NAME}" --format "   ID: {{.ID}}\n   Image: {{.Image}}\n   Created: {{.CreatedAt}}\n   Ports: {{.Ports}}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "   Status: ${YELLOW}Stopped${NC}"
        docker ps -a --filter "name=${CONTAINER_NAME}" --format "   ID: {{.ID}}\n   Image: {{.Image}}\n   Created: {{.CreatedAt}}\n   Exited: {{.Status}}"
    else
        echo -e "   Status: ${RED}Not found${NC}"
    fi
}

# ------------------- Main Menu -------------------
main_menu() {
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  Docker VM Manager – Ubuntu 24.04 + LXD     ${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo "  1) 🐳 Build container (auto-detect resources)"
    echo "  2) 🚀 Start container (auto-enter terminal)"
    echo "  3) 🛑 Stop container"
    echo "  4) 📊 Status"
    echo "  0) 👋 Exit"
    echo ""
    read -p "Choice: " choice
    
    case $choice in
        1) build_container ;;
        2) start_container ;;
        3) stop_container ;;
        4) status_container ;;
        0) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid choice.${NC}" ;;
    esac
}

while true; do
    main_menu
    echo ""
    read -p "Press Enter to continue..."
done
