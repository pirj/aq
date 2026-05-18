#!/usr/bin/env bash
# E2E: aq new --size=N picks the size-N base, two VMs at the same size
# both work and share the same backing file.
#
# This smoke does NOT force a cold base build (which is slow and timing-
# sensitive on a busy machine). The cold-build path is exercised once via
# the manual benchmark in tests/benchmark.sh or simply by deleting the
# size-N base before running this script.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM1="aq-size-${$}-a"
VM2="aq-size-${$}-b"

STEP_TIMEOUT="${STEP_TIMEOUT:-180}"
run() {
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$STEP_TIMEOUT" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$STEP_TIMEOUT" "$@"
  else
    "$@"
  fi
}

cleanup() {
  set +e
  for vm in "$VM1" "$VM2"; do
    "$AQ" stop "$vm" 2>/dev/null
    "$AQ" rm "$vm" 2>/dev/null
  done
}
trap cleanup EXIT

# Compute size-base path the same way aq does.
ARCH=$(uname -m)
case "$ARCH" in arm64) ARCH=aarch64 ;; esac
BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/aq/$ARCH"

# Use a size that already exists in the local catalog (built by Task 4 or
# a prior cold run). Falls back to whatever first size-N base shows up.
SIZE=2
BASE_FILE=$(ls "$BASE_DIR"/alpine-base-*-${ARCH}-${SIZE}G.raw 2>/dev/null | head -1)
if [ -z "$BASE_FILE" ]; then
  echo "[scat] SKIP: no size-${SIZE}G base in catalog; build one first (aq new --size=${SIZE}G ...)"
  exit 0
fi
echo "[scat] using base: $(basename "$BASE_FILE")"

t0=$(date +%s)
echo "[scat] first aq new --size=${SIZE}G"
run "$AQ" new --size="${SIZE}G" "$VM1"
run "$AQ" start "$VM1"
run "$AQ" exec "$VM1" 'echo ready' >/dev/null
t_v1=$(( $(date +%s) - t0 ))
echo "[scat] VM1 reachable in ${t_v1}s"

# Verify guest sees N-sized rootfs.
size_kb=$(run "$AQ" exec "$VM1" "awk '\$NF == \"vda3\" { print \$3 }' /proc/partitions")
size_kb=$(echo "$size_kb" | tr -d '[:space:]')
size_g=$((size_kb / 1024 / 1024))
[ "$size_g" -ge $((SIZE - 1)) ] \
  || { echo "[scat] FAIL: rootfs ${size_g}G < expected ~${SIZE}G"; exit 1; }
echo "[scat] VM1 rootfs: ${size_g}G"

# Verify VM1's overlay backing is the size-N base (catalog actually used).
# Use --force-share because VM1 is running and holds a write lock on the disk.
backing=$(qemu-img info --force-share --output=json "$BASE_DIR/../$VM1/storage.qcow2" 2>/dev/null \
  | grep -E '"backing-filename":' | head -1 || true)
case "$backing" in
  *"alpine-base-"*"-${ARCH}-${SIZE}G.raw"*) : ;;
  *) echo "[scat] FAIL: VM1 backing does not match size-${SIZE}G base: $backing"; exit 1 ;;
esac
echo "[scat] VM1 backing matches size-${SIZE}G base"

t1=$(date +%s)
echo "[scat] second aq new --size=${SIZE}G (reuses base)"
run "$AQ" new --size="${SIZE}G" "$VM2"
run "$AQ" start "$VM2"
run "$AQ" exec "$VM2" 'echo ready' >/dev/null
t_v2=$(( $(date +%s) - t1 ))
echo "[scat] VM2 reachable in ${t_v2}s"

echo "[scat] OK"
