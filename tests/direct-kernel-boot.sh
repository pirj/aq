#!/usr/bin/env bash
# E2E: aq new (default direct kernel boot) works.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM="aq-dkb-$$"

cleanup() { set +e; "$AQ" stop "$VM" 2>/dev/null; "$AQ" rm "$VM" 2>/dev/null; }
trap cleanup EXIT

echo "[dkb] aq new (default size, direct kernel boot)"
"$AQ" new "$VM"
"$AQ" start "$VM"

echo "[dkb] aq exec uname"
out=$("$AQ" exec "$VM" uname -r)
[ -n "$out" ] || { echo "[dkb] FAIL: empty kernel version"; exit 1; }
echo "[dkb] kernel: $out"

echo "[dkb] df -h /"
"$AQ" exec "$VM" df -h /

echo "[dkb] confirm no resize2fs ran on this boot"
ranges=$("$AQ" exec "$VM" 'dmesg | grep -ic resize2fs || true')
ranges=$(echo "$ranges" | tr -d '[:space:]')
[ "$ranges" = "0" ] || { echo "[dkb] FAIL: resize2fs ran ($ranges hits)"; exit 1; }

echo "[dkb] confirm /dev/vda3 is the rootfs source"
src=$("$AQ" exec "$VM" 'awk "\$2 == \"/\" { print \$1 }" /proc/mounts')
src=$(echo "$src" | tr -d '[:space:]')
[ "$src" = "/dev/vda3" ] || { echo "[dkb] FAIL: rootfs is $src, expected /dev/vda3"; exit 1; }

echo "[dkb] aq stop"
"$AQ" stop "$VM"
echo "[dkb] OK"
