#!/bin/bash
set -e

# ================================================
#  Auto‑Create & Run Persistent Ubuntu VM
#  Works inside Docker / Daytona sandboxes
# ================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

VM_DIR="/root/my-vm"
DISK_FILE="$VM_DIR/disk.qcow2"
PID_FILE="$VM_DIR/vm.pid"
LOG_FILE="$VM_DIR/vm.log"
SEED_ISO="$VM_DIR/seed.iso"

# ------------------- Helper functions -------------------
vm_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" >/dev/null 2>&1; then
            return 0
        fi
    fi
    # Also check by process name
    if pgrep -f "qemu-system-x86_64.*$DISK_FILE" >/dev/null; then
        return 0
    fi
    return 1
}

get_vm_pid() {
    if [[ -f "$PID_FILE" ]]; then
        cat "$PID_FILE"
    else
        pgrep -f "qemu-system-x86_64.*$DISK_FILE" | head -1
    fi
}

# ------------------- Install dependencies -------------------
install_qemu() {
    if command -v apt &>/dev/null; then
        apt update
        apt install -y qemu-system-x86 qemu-utils curl genisoimage --no-install-recommends
    elif command -v apk &>/dev/null; then
        apk add --no-cache qemu-system-x86_64 qemu-img curl genisoimage
    else
        echo -e "${RED}❌ Unsupported package manager.${NC}"
        exit 1
    fi
}

# ------------------- Create VM (if not exists) -------------------
create_vm() {
    if [[ -f "$DISK_FILE" ]]; then
        echo -e "${YELLOW}VM already exists at $DISK_FILE${NC}"
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

    # Install QEMU if missing
    install_qemu

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

# ------------------- Start VM in background -------------------
start_vm() {
    if vm_running; then
        echo -e "${YELLOW}VM is already running (PID: $(get_vm_pid))${NC}"
        return 0
    fi

    # Ensure VM exists
    if [[ ! -f "$DISK_FILE" ]]; then
        echo -e "${RED}❌ VM disk not found. Run 'create' first.${NC}"
        return 1
    fi

    cd "$VM_DIR"

    # Build QEMU command
    ram_mb=$(cat config.ram 2>/dev/null || echo "2048")
    cpu_cores=$(cat config.cpu 2>/dev/null || echo "2")

    CMD="qemu-system-x86_64"
    CMD+=" -m ${ram_mb} -smp cores=${cpu_cores}"

    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        CMD+=" -enable-kvm -cpu host"
        echo -e "${GREEN}✅ KVM acceleration enabled.${NC}"
    else
        echo -e "${YELLOW}⚠️  Using software emulation (slower).${NC}"
    fi

    CMD+=" -drive file=${DISK_FILE},format=qcow2"
    CMD+=" -cdrom seed.iso"
    CMD+=" -nic user,hostfwd=tcp::2222-:22"
    CMD+=" -nographic"

    echo -e "${GREEN}🚀 Starting VM in background...${NC}"
    echo -e "${YELLOW}   SSH: ssh -p 2222 admin@localhost (password: admin)${NC}"
    echo -e "${YELLOW}   Logs: tail -f $LOG_FILE${NC}"

    nohup $CMD > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"

    sleep 2
    if vm_running; then
        echo -e "${GREEN}✅ VM started (PID: $pid)${NC}"
    else
        echo -e "${RED}❌ VM failed to start. Check $LOG_FILE${NC}"
    fi
}

# ------------------- Stop VM -------------------
stop_vm() {
    if ! vm_running; then
        echo -e "${YELLOW}VM is not running.${NC}"
        return 0
    fi
    local pid=$(get_vm_pid)
    echo -e "${RED}🛑 Stopping VM (PID: $pid)...${NC}"
    kill "$pid" 2>/dev/null || true
    sleep 2
    if vm_running; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo -e "${GREEN}✅ VM stopped.${NC}"
}

# ------------------- Status -------------------
status_vm() {
    if vm_running; then
        echo -e "${GREEN}✅ VM is running (PID: $(get_vm_pid))${NC}"
        echo -e "   SSH: ssh -p 2222 admin@localhost (password: admin)"
    else
        echo -e "${RED}❌ VM is stopped.${NC}"
    fi
}

# ------------------- Console -------------------
console_vm() {
    if ! vm_running; then
        echo -e "${RED}❌ VM is not running. Start it first.${NC}"
        return 1
    fi
    echo -e "${YELLOW}Attaching to VM console. Press Ctrl+A then X to detach (does not stop VM).${NC}"
    sleep 2
    # Use socat to connect to the serial? We can't easily attach to an existing nohup process's stdin/out.
    # Instead, we can suggest using `screen` to run the VM in the first place.
    # For simplicity, we'll just tell them to use `tail -f` on the log or SSH.
    echo -e "${YELLOW}To see console output: tail -f $LOG_FILE${NC}"
    echo -e "${YELLOW}To interact: SSH into the VM using port 2222${NC}"
}

# ------------------- Auto-start setup -------------------
setup_autostart() {
    echo -e "${GREEN}Setting up auto-start on container boot...${NC}"
    SCRIPT_PATH="$(realpath "$0")"
    # Add to .bashrc (runs when shell starts)
    if ! grep -q "start-vm" ~/.bashrc; then
        echo "($SCRIPT_PATH start) &" >> ~/.bashrc
        echo -e "${GREEN}✅ Added to ~/.bashrc (will start on shell login)${NC}"
    else
        echo -e "${YELLOW}Already in ~/.bashrc${NC}"
    fi
    # Alternatively, use cron @reboot if available
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" ; echo "@reboot $SCRIPT_PATH start > /dev/null 2>&1") | crontab -
        echo -e "${GREEN}✅ Added cron @reboot job.${NC}"
    else
        echo -e "${YELLOW}⚠️  cron not installed – auto-start may not work on container restart.${NC}"
        echo -e "${YELLOW}   Install cron: apt install -y cron && systemctl enable cron${NC}"
    fi
}

# ------------------- Main menu -------------------
main_menu() {
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}   Persistent Ubuntu VM Manager              ${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo "  1) Create VM (if not exists)"
    echo "  2) Start VM (background)"
    echo "  3) Stop VM"
    echo "  4) VM Status"
    echo "  5) Attach to console (logs/SSH info)"
    echo "  6) Setup auto-start on boot"
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

# ------------------- Command-line arguments -------------------
case "$1" in
    start)
        create_vm
        start_vm
        ;;
    stop)
        stop_vm
        ;;
    status)
        status_vm
        ;;
    console)
        console_vm
        ;;
    autostart)
        setup_autostart
        ;;
    *)
        main_menu
        ;;
esac
