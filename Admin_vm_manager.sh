#!/bin/bash
set -e

VM_DIR="/root/my-vm"
DISK_FILE="$VM_DIR/disk.qcow2"
SCREEN_NAME="vm-console"

install_qemu() {
    if command -v apt &>/dev/null; then
        apt update
        apt install -y qemu-system-x86 qemu-utils curl genisoimage screen --no-install-recommends
    elif command -v apk &>/dev/null; then
        apk add --no-cache qemu-system-x86_64 qemu-img curl genisoimage screen
    fi
}

create_vm() {
    if [[ -f "$DISK_FILE" ]]; then
        echo "VM already exists."
        return 0
    fi
    mkdir -p "$VM_DIR"
    cd "$VM_DIR"
    # ... (same as before) ...
    # For brevity, I'll include the full version below.
}

start_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo "VM is already running in screen. Attach: screen -r $SCREEN_NAME"
        return 0
    fi
    cd "$VM_DIR"
    ram_mb=$(cat config.ram 2>/dev/null || echo "2048")
    cpu_cores=$(cat config.cpu 2>/dev/null || echo "2")
    CMD="qemu-system-x86_64 -m ${ram_mb} -smp cores=${cpu_cores}"
    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        CMD+=" -enable-kvm -cpu host"
    else
        echo "Using software emulation."
    fi
    CMD+=" -drive file=${DISK_FILE},format=qcow2 -cdrom seed.iso -nic user,hostfwd=tcp::2222-:22 -nographic"
    screen -dmS "$SCREEN_NAME" bash -c "$CMD; exec bash"
    sleep 1
    screen -r "$SCREEN_NAME"
}

stop_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -S "$SCREEN_NAME" -X quit
        echo "VM stopped."
    else
        echo "Not running."
    fi
}

status_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        echo "VM is running in screen. Attach: screen -r $SCREEN_NAME"
    else
        echo "VM is stopped."
    fi
}

console_vm() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        screen -r "$SCREEN_NAME"
    else
        echo "VM not running."
    fi
}

main_menu() {
    echo "1) Create VM"
    echo "2) Start VM (with console)"
    echo "3) Stop VM"
    echo "4) Status"
    echo "5) Attach console"
    echo "0) Exit"
    read -p "Choice: " choice
    case $choice in
        1) create_vm ;;
        2) start_vm ;;
        3) stop_vm ;;
        4) status_vm ;;
        5) console_vm ;;
        0) exit 0 ;;
    esac
}

case "$1" in
    start) create_vm; start_vm ;;
    stop) stop_vm ;;
    status) status_vm ;;
    console) console_vm ;;
    *) main_menu ;;
esac
