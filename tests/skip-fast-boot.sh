#!/usr/bin/env bash
# E2E: --skip-fast-boot exercises the legacy UEFI path.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM="aq-legacy-$$"

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
  "$AQ" stop "$VM" 2>/dev/null
  "$AQ" rm "$VM" 2>/dev/null
}
trap cleanup EXIT

echo "[legacy] aq new --skip-fast-boot"
run "$AQ" new --skip-fast-boot "$VM"
run "$AQ" start "$VM"

echo "[legacy] aq exec hello"
out=$(run "$AQ" exec "$VM" 'echo hello')
out=$(echo "$out" | tr -d '[:space:]')
[ "$out" = "hello" ] || { echo "[legacy] FAIL: '$out' != 'hello'"; exit 1; }

# Confirm the legacy path wrote the .boot_mode_uefi marker, not _direct.
ARCH=$(uname -m)
case "$ARCH" in arm64) ARCH=aarch64 ;; esac
VMDIR="${XDG_DATA_HOME:-$HOME/.local/share}/aq/$VM"
[ -f "$VMDIR/.boot_mode_uefi"   ] || { echo "[legacy] FAIL: missing .boot_mode_uefi marker"; exit 1; }
[ ! -f "$VMDIR/.boot_mode_direct" ] || { echo "[legacy] FAIL: unexpected .boot_mode_direct marker"; exit 1; }
echo "[legacy] markers OK (uefi only)"

echo "[legacy] OK"
