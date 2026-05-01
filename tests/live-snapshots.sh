#!/usr/bin/env bash
# E2E test for live (memory-preserving) snapshots:
# - provision a VM
# - leave a marker in tmpfs (/dev/shm) — survives only if memory is restored
# - snapshot the running VM
# - derive a new VM, start it, verify the tmpfs marker is there

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
SRC_VM="aq-live-src-$$"
DST_VM="aq-live-dst-$$"
TAG="aq-live-test-$$"

cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" 2>/dev/null
  "$AQ" rm   "$SRC_VM" 2>/dev/null
  "$AQ" stop "$DST_VM" 2>/dev/null
  "$AQ" rm   "$DST_VM" 2>/dev/null
  "$AQ" snapshot rm --force "$TAG" 2>/dev/null
}
trap cleanup EXIT

ARCH=$(uname -m | sed 's/^arm64$/aarch64/')
SNAPSHOT_DIR="$HOME/.local/share/aq/snapshots/$ARCH/$TAG"

echo "[live] aq new $SRC_VM"
"$AQ" new "$SRC_VM"
"$AQ" start "$SRC_VM"

echo "[live] write tmpfs marker"
"$AQ" exec "$SRC_VM" 'echo "live-marker-'"$$"'" > /dev/shm/marker'

echo "[live] aq snapshot create on RUNNING $SRC_VM"
"$AQ" snapshot create "$SRC_VM" "$TAG"

echo "[live] verify meta.json reports has_memory: true"
if ! grep -q '"has_memory": true' "$SNAPSHOT_DIR/meta.json"; then
  echo "[live] FAIL: has_memory not true in $SNAPSHOT_DIR/meta.json"
  cat "$SNAPSHOT_DIR/meta.json"
  exit 1
fi

echo "[live] verify memory.bin exists and is non-empty"
if [ ! -s "$SNAPSHOT_DIR/memory.bin" ]; then
  echo "[live] FAIL: memory.bin missing or empty"
  ls -la "$SNAPSHOT_DIR"
  exit 1
fi

echo "[live] aq stop + rm $SRC_VM"
"$AQ" stop "$SRC_VM"
"$AQ" rm "$SRC_VM"

echo "[live] aq new --from-snapshot=$TAG $DST_VM"
"$AQ" new --from-snapshot="$TAG" "$DST_VM"

echo "[live] verify incoming-memory.bin staged"
if [ ! -s "$HOME/.local/share/aq/$DST_VM/incoming-memory.bin" ]; then
  echo "[live] FAIL: incoming-memory.bin missing in $DST_VM dir"
  ls -la "$HOME/.local/share/aq/$DST_VM/"
  exit 1
fi

echo "[live] aq start (should be fast — restores memory state)"
"$AQ" start "$DST_VM"

echo "[live] verify tmpfs marker survived"
out=$("$AQ" exec "$DST_VM" 'cat /dev/shm/marker')
if [ "$out" != "live-marker-$$" ]; then
  echo "[live] FAIL: expected 'live-marker-$$', got '$out'"
  exit 1
fi

echo "[live] verify incoming-memory.bin was consumed (removed) by aq start"
if [ -f "$HOME/.local/share/aq/$DST_VM/incoming-memory.bin" ]; then
  echo "[live] FAIL: incoming-memory.bin still present after start"
  exit 1
fi

echo "[live] PASSED"
