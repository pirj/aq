#!/bin/bash

# alq - QEMU wrapper script
# Usage: alq [start|stop|new|ls] [args...]

alq_help() {
  cat <<HELP
    alq new <vm-name>
    alq console <vm-name>
    alq start <vm-name>
    alq stop <vm-name>
    alq rm <vm-name>
    alq ls
HELP
}

alq_new() {
  local VM_NAME=$1

# shuf -n 3 /usr/share/dict/words | tr '\n' '-'| sed 's/-$//'
# for random name generation

  if [ -z "$VM_NAME" ]; then
    read -p "Enter VM name: " VM_NAME
  fi

  echo "Creating new VM: $VM_NAME"
  touch $VM_NAME.qcow2
  echo "Basic VM created with disk image: $VM_NAME.qcow2"
}

alq_start() {
  local VM_NAME=$1

  if [ -z "$VM_NAME" ]; then
    echo "Error: VM name required for start command." >&2
    return 1
  fi

  QEMU_CMD="qemu-system-aarch64 -m 2048 -smp 2 -hda $VM_NAME.qcow2 -boot d -vga std"
  echo "Starting VM: $VM_NAME"
  eval $QEMU_CMD
}

alq_console() {
  local VM_NAME=$1

  if [ -z "$VM_NAME" ]; then
    echo "Error: VM name required for console command." >&2
    return 1
  fi

  QEMU_CMD="qemu-system-aarch64 -m 2048 -smp 2 -hda $VM_NAME.qcow2 -boot d -vga std"
  eval $QEMU_CMD
}

alq_stop() {
  local VM_NAME=$1

  if [ -z "$VM_NAME" ]; then
    echo "Error: VM name required for stop command." >&2
    return 1
  fi

  echo "Stopping VM: $VM_NAME"
  pkill -f "qemu-system-aarch64.*-hda $VM_NAME.qcow2"
}

alq_rm() {
  local VM_NAME=$1

  if [ -z "$VM_NAME" ]; then
    echo "Error: VM name required for rm command." >&2
    return 1
  fi

  echo "Removing VM: $VM_NAME"
}

alq_ls() {
  echo "Listing running VMs:"
  pgrep -f "qemu-system-aarch64" | awk '{print $1}'
}

COMMAND=$1
shift
case $COMMAND in
  new)
    alq_new "$*"
    ;;
  start)
    alq_start "$*"
    ;;
  stop)
    alq_stop "$*"
    ;;
  rm)
    alq_rm "$*"
    ;;
  ls)
    alq_ls
    ;;
  "" | "help" | "-h" | "--help")
    alq_help
    ;;
  *)
    echo "Error: Unknown command $COMMAND." >&2
    exit 1
    ;;
esac

exit 0
