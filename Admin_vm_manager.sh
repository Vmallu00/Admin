#!/usr/bin/env bash
# =====================================================
#  Docker → VM Manager (Admin)
#  Create, Start, Stop, Console a VM with Wings pre‑installed
#  Usage: bash <(curl -fsSL https://raw.githubusercontent.com/Vmallu00/pterodactyl/master/admin_vm_manager.sh)
# =====================================================

set -e

VM_DIR="${HOME}/docker-vms"
PID_FILE="${VM_DIR}/vm.pid"
CONSOLE_TYPE="serial"   # or "vnc"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- Detect if running inside a container ----------
check_container() {
    if [ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo -e "${YELLOW}⚠️  You are running inside a Docker container.${NC}"
        echo -e "${YELLOW}   Building a VM inside a container often fails due to overlay mount limitations.${NC}"
        echo -e "${YELLOW}   It is strongly recommended to run this script on the host machine.${NC}"
        echo
        read -p "Press Enter to continue anyway, or Ctrl+C to abort..."
    fi
}

# ---------- Trim input ----------
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

# ---------- Check dependencies ----------
check_deps() {
    echo -e "${CYAN}Checking dependencies...${NC}"
    local missing=()
    for dep in docker qemu-system-x86_64 qemu-img screen; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if ! command -v d2vm &>/dev/null; then
        echo -e "${RED}Missing: d2vm${NC}"
        echo "Install d2vm from: https://github.com/linka-cloud/d2vm"
        echo "Quick install:"
        echo '  VERSION=$(curl -s https://api.github.com/repos/linka-cloud/d2vm/releases/latest | grep tag_name | cut -d '"'"'"'"'"'"'"'"' -f 4)'
        echo '  curl -sL "https://github.com/linka-cloud/d2vm/releases/download/${VERSION}/d2vm_${VERSION}_$(uname -s | tr "[:upper:]" "[:lower:]")_$( [ "$(uname -m)" = "x86_64" ] && echo "amd64" || echo "arm64" ).tar.gz" | tar -xvz d2vm'
        echo '  sudo mv d2vm /usr/local/bin/'
        exit 1
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing: ${missing[*]}${NC}"
        echo "Install: sudo apt install ${missing[*]}"
        exit 1
    fi
    echo -e "${GREEN}✓ All dependencies installed${NC}"
}

# ---------- Docker build (handles missing --progress flag) ----------
docker_build() {
    local tag="$1"
    local dockerfile="$2"
    local context_dir="$(dirname "$dockerfile")"

    if [ ! -f "${context_dir}/.dockerignore" ]; then
        echo "*" > "${context_dir}/.dockerignore"
    fi

    if docker build --help 2>&1 | grep -q progress; then
        DOCKER_BUILDKIT=1 docker build --progress=plain -t "$tag" -f "$dockerfile" "$context_dir"
    else
        docker build -t "$tag" -f "$dockerfile" "$context_dir"
    fi
}

# ---------- Create VM ----------
create_vm() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}       CREATE NEW VM${NC}"
    echo -e "${CYAN}=========================================${NC}"

    read -p "Docker image (e.g., ubuntu:22.04): " raw_image
    DOCKER_IMAGE=$(trim "$raw_image")
    while [ -z "$DOCKER_IMAGE" ]; do
        echo -e "${RED}Image name cannot be empty.${NC}"
        read -p "Docker image (e.g., ubuntu:22.04): " raw_image
        DOCKER_IMAGE=$(trim "$raw_image")
    done

    read -p "VM name: " raw_name
    VM_NAME=$(trim "$raw_name")
    while [ -z "$VM_NAME" ]; do
        echo -e "${RED}VM name cannot be empty.${NC}"
        read -p "VM name: " raw_name
        VM_NAME=$(trim "$raw_name")
    done

    read -p "Disk size (e.g., 20G): " raw_disk
    DISK_SIZE=$(trim "$raw_disk")
    [[ -z "$DISK_SIZE" ]] && DISK_SIZE="20G"

    read -p "CPU cores: " raw_cpu
    CPU_CORES=$(trim "$raw_cpu")
    [[ -z "$CPU_CORES" ]] && CPU_CORES="2"

    read -p "RAM (MB): " raw_ram
    RAM_MB=$(trim "$raw_ram")
    [[ -z "$RAM_MB" ]] && RAM_MB="2048"

    read -p "Username: " raw_user
    VM_USER=$(trim "$raw_user")
    while [ -z "$VM_USER" ]; do
        echo -e "${RED}Username cannot be empty.${NC}"
        read -p "Username: " raw_user
        VM_USER=$(trim "$raw_user")
    done
    if [ "$VM_USER" = "root" ]; then
        echo -e "${YELLOW}Warning: 'root' already exists. Creating 'admin' instead.${NC}"
        VM_USER="admin"
    fi

    read -s -p "Password: " raw_pass; echo
    VM_PASS=$(trim "$raw_pass")
    while [ -z "$VM_PASS" ]; do
        echo -e "${RED}Password cannot be empty.${NC}"
        read -s -p "Password: " raw_pass; echo
        VM_PASS=$(trim "$raw_pass")
    done

    read -p "Enable SSH? (y/n): " raw_ssh
    ENABLE_SSH=$(trim "$raw_ssh")
    [[ -z "$ENABLE_SSH" ]] && ENABLE_SSH="n"

    OUTPUT_IMAGE="${VM_DIR}/${VM_NAME}.qcow2"
    mkdir -p "$VM_DIR"

    cat > "${VM_DIR}/${VM_NAME}.conf" << EOF
VM_NAME=$VM_NAME
DISK_SIZE=$DISK_SIZE
CPU_CORES=$CPU_CORES
RAM_MB=$RAM_MB
VM_USER=$VM_USER
VM_PASS=$VM_PASS
OUTPUT_IMAGE=$OUTPUT_IMAGE
ENABLE_SSH=$ENABLE_SSH
EOF

    echo -e "${YELLOW}[1/4] Building Docker image with Wings + user...${NC}"
    cat > "${VM_DIR}/Dockerfile.wings" << EOF
FROM ${DOCKER_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \\
    curl docker.io systemd openssh-server sudo \\
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash ${VM_USER} \\
    && echo "${VM_USER}:${VM_PASS}" | chpasswd \\
    && usermod -aG sudo ${VM_USER} \\
    && echo "${VM_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN curl -L -o /usr/local/bin/wings \\
    https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 \\
    && chmod +x /usr/local/bin/wings
RUN mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
RUN systemctl enable wings || true
RUN if [ "${ENABLE_SSH}" = "y" ]; then systemctl enable ssh || true; fi
EXPOSE 8080 443 22
EOF

    docker_build "${VM_NAME}-with-wings" "${VM_DIR}/Dockerfile.wings"

    echo -e "${YELLOW}[2/4] Converting to VM disk image (this may take a while)...${NC}"
    # ✅ FIX: removed --format, it's inferred from .qcow2 extension
    sudo d2vm convert "${VM_NAME}-with-wings" \
        --output "$OUTPUT_IMAGE" \
        --size "$DISK_SIZE" \
        --verbose

    if command -v virt-customize &>/dev/null; then
        echo -e "${YELLOW}[3/4] Hardening password with virt-customize...${NC}"
        sudo virt-customize -a "$OUTPUT_IMAGE" \
            --run-command "echo '${VM_USER}:${VM_PASS}' | chpasswd" \
            --run-command "systemctl enable ssh" 2>/dev/null || true
    else
        echo -e "${YELLOW}[3/4] Skipping virt-customize (not installed)${NC}"
    fi

    echo "$VM_NAME" > "${VM_DIR}/current_vm.name"
    echo "$OUTPUT_IMAGE" > "${VM_DIR}/current_vm.image"

    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}✅ VM CREATED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "  Image: ${CYAN}$OUTPUT_IMAGE${NC}"
    echo -e "  Disk:  ${CYAN}$DISK_SIZE${NC}"
    echo -e "  CPU:   ${CYAN}$CPU_CORES cores${NC}"
    echo -e "  RAM:   ${CYAN}$RAM_MB MB${NC}"
    echo -e "  User:  ${CYAN}$VM_USER${NC}"
    echo -e "  SSH:   ${CYAN}$ENABLE_SSH${NC}"
    echo -e "${GREEN}=========================================${NC}"
}

# ---------- Start / Stop / Console (unchanged) ----------
start_vm() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}VM is already running (PID $(cat "$PID_FILE")).${NC}"
        return
    fi
    VM_NAME=$(cat "${VM_DIR}/current_vm.name" 2>/dev/null)
    if [ -z "$VM_NAME" ]; then
        echo -e "${RED}No VM found. Create one first (Option 1).${NC}"
        return
    fi
    source "${VM_DIR}/${VM_NAME}.conf"
    if [ ! -f "$OUTPUT_IMAGE" ]; then
        echo -e "${RED}Image file not found: $OUTPUT_IMAGE${NC}"
        return
    fi
    echo -e "${GREEN}Starting $VM_NAME with ${CPU_CORES} cores, ${RAM_MB}MB RAM...${NC}"
    QEMU_OPTS="-m $RAM_MB -smp cores=$CPU_CORES -drive file=$OUTPUT_IMAGE,format=qcow2 -netdev user,id=net0 -device virtio-net-pci,netdev=net0"
    if [ "$CONSOLE_TYPE" = "vnc" ]; then
        qemu-system-x86_64 $QEMU_OPTS -vnc :0 -daemonize
        echo $! > "$PID_FILE"
        echo -e "${GREEN}Started on VNC display :0${NC}"
    else
        screen -dmS docker-vm qemu-system-x86_64 $QEMU_OPTS -nographic -serial mon:stdio
        echo "screen" > "$PID_FILE"
        echo -e "${GREEN}Started in screen session 'docker-vm'${NC}"
        echo -e "  Attach: ${CYAN}screen -r docker-vm${NC}"
        echo -e "  Detach: ${CYAN}Ctrl+A D${NC}"
    fi
}

stop_vm() {
    if [ ! -f "$PID_FILE" ]; then
        echo -e "${YELLOW}No VM is running.${NC}"
        return
    fi
    PID=$(cat "$PID_FILE")
    if [ "$PID" = "screen" ]; then
        screen -S docker-vm -X quit 2>/dev/null && echo -e "${GREEN}VM stopped.${NC}" || echo -e "${YELLOW}Already stopped.${NC}"
        rm -f "$PID_FILE"
    else
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" && echo -e "${GREEN}VM stopped.${NC}"
            rm -f "$PID_FILE"
        else
            echo -e "${YELLOW}Stale PID file. Removing.${NC}"
            rm -f "$PID_FILE"
        fi
    fi
}

console_vm() {
    if [ "$CONSOLE_TYPE" = "vnc" ]; then
        if command -v vncviewer &>/dev/null; then
            vncviewer localhost:0
        else
            echo -e "${RED}vncviewer not installed. Install tigervnc-viewer.${NC}"
        fi
    else
        if screen -list | grep -q docker-vm; then
            screen -r docker-vm
        else
            echo -e "${RED}No screen session found. VM may not be running.${NC}"
        fi
    fi
}

show_menu() {
    clear
    echo "========================================="
    echo "   ADMIN VM MANAGER (Docker → VM)"
    echo "========================================="
    echo " 1. Create VM (with Wings)"
    echo " 2. Start VM"
    echo " 3. Stop VM"
    echo " 4. Console (serial/VNC)"
    echo " 5. Exit"
    echo "========================================="
    read -p "Choose option [1-5]: " opt
    case $opt in
        1) create_vm ;;
        2) start_vm ;;
        3) stop_vm ;;
        4) console_vm ;;
        5) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
    read -p "Press Enter to continue..."
}

# ---------- Main ----------
check_container
check_deps
mkdir -p "$VM_DIR"
while true; do show_menu; done
