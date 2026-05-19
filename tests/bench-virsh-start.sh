#!/usr/bin/env bash
# Micro-benchmark for libvirt/virsh: time `virsh start` from shutdown to
# SSH-accept on the guest's NAT'd IP.
#
# Prelude (untimed):
#   - Download the Alpine x86_64 cloud qcow2 to /tmp.
#   - Generate a NoCloud cloud-init seed.iso that injects the host's SSH
#     pubkey into root@guest.
#   - virt-install --import to define the domain on libvirt's default
#     NAT network, with the seed.iso attached as a CD-ROM.
#   - Wait for SSH on the DHCP-assigned guest IP. First boot runs
#     cloud-init which is slow; we don't time it.
#   - virsh shutdown.
#
# Loop (timed):
#   - virsh start; poll TCP-accept on the recorded guest IP at the same
#     cadence as the other benches (100 ms).
#   - virsh shutdown; wait for it to go down before the next start.
#
# Notes:
#   - Uses default libvirt network (192.168.122.0/24, NAT + dnsmasq).
#   - Guest IP is read once after the first start via `virsh domifaddr`
#     and reused for all timed runs (DHCP leases are sticky per-MAC).

set -eu
set -o pipefail

RUNS=5
LABEL="virsh_start"
PROBE_INTERVAL="${AQ_SSH_PROBE_INTERVAL:-0.1}"
WORKDIR="${WORKDIR:-$HOME/aq-virsh-bench-$$}"
VM_NAME="aq-virsh-bench-$$"
ALPINE_VERSION="${ALPINE_VERSION:-3.20.3}"
ALPINE_IMG_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/cloud/nocloud_alpine-${ALPINE_VERSION}-x86_64-bios-cloudinit-r0.qcow2"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) RUNS=$2; shift 2 ;;
    -l) LABEL=$2; shift 2 ;;
    *) echo "Usage: $0 [-n RUNS] [-l LABEL]" >&2; exit 2 ;;
  esac
done

cleanup() {
  set +e
  sudo virsh shutdown "$VM_NAME" >/dev/null 2>&1
  # Force-off after a moment if shutdown is ignored.
  sleep 2
  sudo virsh destroy "$VM_NAME" >/dev/null 2>&1
  sudo virsh undefine --remove-all-storage "$VM_NAME" >/dev/null 2>&1
  rm -rf "$WORKDIR"
}
trap 'stat=$?; cleanup; exit $stat' EXIT

echo "# label=$LABEL runs=$RUNS image=$ALPINE_IMG_URL probe=${PROBE_INTERVAL}s virsh=$(virsh --version 2>&1 | head -1)"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "# [prelude] download cloud image"
wget -q -O alpine.qcow2 "$ALPINE_IMG_URL"

echo "# [prelude] build NoCloud seed.iso with host SSH pubkey"
SSH_PUB="$(cat ~/.ssh/id_ed25519.pub)"
cat > user-data <<EOF
#cloud-config
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - $SSH_PUB
EOF
cat > meta-data <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF
cloud-localds seed.iso user-data meta-data

echo "# [prelude] virt-install --import (defines + starts the domain)"
sudo cp alpine.qcow2 /var/lib/libvirt/images/$VM_NAME.qcow2
sudo cp seed.iso     /var/lib/libvirt/images/$VM_NAME-seed.iso
sudo virt-install \
  --name "$VM_NAME" \
  --memory 1024 --vcpus 1 \
  --disk path=/var/lib/libvirt/images/$VM_NAME.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/$VM_NAME-seed.iso,device=cdrom \
  --os-variant=alpinelinux3.18 \
  --network network=default,model=virtio \
  --import --noautoconsole --graphics none \
  >/dev/null

echo "# [prelude] wait for DHCP lease + SSH (first boot includes cloud-init)"
GUEST_IP=""
deadline=$(( $(date +%s) + 180 ))
while [ -z "$GUEST_IP" ]; do
  GUEST_IP=$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null \
             | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')
  [ -n "$GUEST_IP" ] && break
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "[virsh] FAIL: VM did not get a DHCP lease in 3 min" >&2
    exit 1
  fi
  sleep 1
done
echo "# guest IP: $GUEST_IP"

while ! nc -z -w 1 "$GUEST_IP" 22 2>/dev/null; do
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "[virsh] FAIL: SSH never came up on $GUEST_IP:22 during prelude" >&2
    exit 1
  fi
  sleep 0.5
done

echo "# [prelude] shutdown so the timed loop starts from a stopped state"
sudo virsh shutdown "$VM_NAME" >/dev/null
while [ "$(sudo virsh domstate "$VM_NAME")" != "shut off" ]; do sleep 0.5; done

times_ms=()
for i in $(seq 1 "$RUNS"); do
  start_ns=$(date +%s%N)
  sudo virsh start "$VM_NAME" >/dev/null

  deadline=$(( $(date +%s) + 120 ))
  while ! nc -z -w 1 "$GUEST_IP" 22 2>/dev/null; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "[virsh] FAIL: SSH never came up on $GUEST_IP:22 in 120s (run $i)" >&2
      exit 1
    fi
    sleep "$PROBE_INTERVAL"
  done
  end_ns=$(date +%s%N)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  sudo virsh shutdown "$VM_NAME" >/dev/null
  while [ "$(sudo virsh domstate "$VM_NAME")" != "shut off" ]; do sleep 0.5; done

  times_ms+=("$ms")
  printf 'run\t%d\t%s\t%d\tms\n' "$i" "$LABEL" "$ms"
done

sorted=$(printf '%s\n' "${times_ms[@]}" | sort -n)
n=${#times_ms[@]}
min_ms=$(echo "$sorted" | head -1)
max_ms=$(echo "$sorted" | tail -1)
mid=$(( (n + 1) / 2 ))
median_ms=$(echo "$sorted" | sed -n "${mid}p")

printf 'summary\t%s\tmin=%dms median=%dms max=%dms n=%d\n' \
  "$LABEL" "$min_ms" "$median_ms" "$max_ms" "$n"
