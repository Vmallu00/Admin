#!/bin/bash
set -e

# ================================================
#  Persistent Ubuntu VM with Screen Console
#  Auto-installs screen if missing
# ================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

VM_DIR="/root/my-vm"
DISK_FILE="$VM_DIR/disk.qcow2"
SCREEN_NAME="vm-console"

# ------------------- Install dependencies -------------------
install_deps() {
    if command -v apt &>/dev/null; then
        apt update
        apt install -y qemu-system-x86 qemu-utils curl genisoimage screen --no-install-recommends
    elif command -v apk &>/dev/null; then
        apk add --no-cache qemu-system-x86_64 qemu-img curl genisoimage screen
    else
        echo -e "${RED}❌ Unsupported package manager.${NC}"
        exit 1
    fi
}

# ------------------- Create VM (if not exists) -------------------
create_vm() {
    if [[ -f "$DISK_FILE" ]]; then
        echo -e "${YELLOW}VM already exists.${NC}"
        return 0
    fi

    echo -e "${GREEN}📦 Creating new VM...${NC}"
    mkdir -p "$VM_DIR"
    cd "$VM_DIR"

    # Detect resources
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    ram_mb=$(( total_ram * 80 / 100 ))
    if [[ $ram_mb -lt 1024 ]]; then ram_mb=1024; fi
    if [[ $ram_mb -gt 8192 ]]; then ram_mb=8192; fi

    cpu_cores=$(nproc)

    disk_free=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    disk_size=$(( disk_free * 80 / 100 ))
    if [[ $disk_size -lt 10 ]]; then disk_size=10; fi
    if [[ $disk_size -gt 50 ]]; then disk_size=50; fi

    echo -e "   RAM: ${BLUE}${ram_mb}MB${NC}"
    echo -e "   CPU: ${BLUE}${cpu_cores} cores${NC}"
    echo -e "   Disk: ${BLUE}${disk_size}GB${NC}"

    echo "$ram_mb" > config.ram
    echo "$cpu_cores" > config.cpu

    # Download Ubuntu cloud image
    IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    IMAGE_FILE="ubuntu-jammy-server-cloudimg-amd64.img"
    if [[ ! -f "$IMAGE_FILE" ]]; then
        echo -e "${GREEN}⬇️  Downloading Ubuntu 22.04 cloud image...${NC}"
        curl -L -o "$IMAGE_FILE.tmp" "$IMAGE_URL"
        mv "$IMAGE_FILE.tmp" "$IMAGE_FILE"
    fi

    # Create writable disk
    echo -e "${GREEN}📀 Creating writable disk (${disk_size}GB)...${NC}"
    qemu-img create -f qcow2 -b "$IMAGE_FILE" -F qcow2 "$DISK_FILE" "${disk_size}G"

    # Create cloud-init user-data
    echo -e "${GREEN}📝 Generating cloud-init user-data...${NC}"
    cat > user-data <<EOF
#cloud-config
hostname: base-vm
manage_etc_hosts: true
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $(echo "admin" | openssl passwd -6 -stdin)
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
EOF
    cat > meta-data <<EOF
instance-id: base-vm
local-hostname: base-vm
EOF

    echo -e "${GREEN}💿 Building cloud-init ISO...${NC}"
    genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data 2>/dev/null || mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data
}

# ------------------- Start VM inside a screen session -------------------
start_vm() {
    # Ensure screen is installed
    if ! command -v screen &>/dev/null; then
        echo -e "${YELLOW}Installing screen...${NC}"
        install_deps
    fi

    if screen -list | grep -q "$SCREEN_NAME"; then
        echo -e "${YELLOW}VM is already running in screen. Attach: screen -r $SCREEN_NAME${NC}"
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
        echo -e "${YELLOW}⚠️  Using software emulation (slower).${NC}"
    fi
    CMD+=" -drive file=${DISK_FILE},format=qcow2 -cdrom seed.iso -nic user,hostfwd=tcp::2222-:22 -nographic"

    echo -e "${GREEN}🚀 Starting VM in screen session '$SCREEN_NAME'...${NC}"
    echo -e "${YELLOW}   SSH: ssh -p 2222 admin@localhost (password: admin)${NC}"
    echo -e "${YELLOW}   Console will open. To detach: Ctrl+A then D${NC}"
    echo -e "${YELLOW}   To reattach later: screen -r $SCREEN_NAME${NC}"
    sleep 2

    screen -dmS "$SCREEN_NAME" bash -c "$CMD; exec bash"
    sleep 1
    screen -r "$SCREEN_NAME"
}

# ------------------- Stop VM -------------------
stop_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -S "$SCREEN_NAME" -X quit
        echo -e "${GREEN}✅ VM stopped.${NC}"
    else
        echo -e "${YELLOW}VM not running.${NC}"
    fi
}

# ------------------- Status -------------------
status_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo -e "${GREEN}✅ VM is running. Attach: screen -r $SCREEN_NAME${NC}"
    else
        echo -e "${RED}❌ VM is stopped.${NC}"
    fi
}

# ------------------- Attach to console -------------------
console_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -r "$SCREEN_NAME"
    else
        echo -e "${RED}❌ VM not running.${NC}"
    fi
}

# ------------------- Setup auto-start -------------------
setup_autostart() {
    echo -e "${GREEN}Setting up auto-start on container boot...${NC}"
    SCRIPT_PATH="$(realpath "$0")"
    if ! grep -q "$SCRIPT_PATH start" ~/.bashrc 2>/dev/null; then
        echo "($SCRIPT_PATH start) &" >> ~/.bashrc
        echo -e "${GREEN}✅ Added to ~/.bashrc${NC}"
    fi
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" ; echo "@reboot $SCRIPT_PATH start > /dev/null 2>&1") | crontab -
        echo -e "${GREEN}✅ Added cron @reboot job.${NC}"
    fi
}

# ------------------- Main menu -------------------
main_menu() {
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}   Persistent Ubuntu VM (Screen Console)     ${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo "  1) Create VM"
    echo "  2) Start VM (with console)"
    echo "  3) Stop VM"
    echo "  4) Status"
    echo "  5) Attach console"
    echo "  6) Auto-start setup"
    echo "  0) Exit"
    read -p "Choice: " choice
    case $choice in
        1) create_vm ;;
        2) start_vm ;;
        3) stop_vm ;;
        4) status_vm ;;
        5) console_vm ;;
        6) setup_autostart ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid choice.${NC}" ;;
    esac
}

# ------------------- Command-line args -------------------
case "$1" in
    start) create_vm; start_vm ;;
    stop) stop_vm ;;
    status) status_vm ;;
    console) console_vm ;;
    autostart) setup_autostart ;;
    *) main_menu ;;
esac
