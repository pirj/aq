#!/usr/bin/env bash
# Verify guest-side cleanups applied during base build:
#   - /etc/motd carries the aq banner (replacing Alpine's setup-alpine hint)
#   - /root/setup.conf is absent
#   - /root/.ash_history is absent at first boot
#
# NOTE: a *cached* base built before v2.5.3 won't have these cleanups —
# the test then fails by design, telling the user to nuke the cache.
# CI builds the base from scratch each run, so this just works there.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM_NAME="aq-cleanup-$$"

cleanup() {
  set +e
  "$AQ" stop "$VM_NAME" 2>/dev/null
  "$AQ" rm "$VM_NAME" 2>/dev/null
}
trap cleanup EXIT

echo "[guest-cleanup] aq new"
"$AQ" new "$VM_NAME"

echo "[guest-cleanup] aq start"
"$AQ" start "$VM_NAME"

echo "[guest-cleanup] /etc/motd contains aq banner"
motd=$("$AQ" exec "$VM_NAME" cat /etc/motd 2>/dev/null || true)
case "$motd" in
  *"aq Alpine VM"*)
    echo "[guest-cleanup]   OK"
    ;;
  *)
    echo "[guest-cleanup]   FAIL: /etc/motd not the aq banner"
    echo "[guest-cleanup]   got:"
    printf '%s\n' "$motd" | sed 's/^/    /'
    echo "[guest-cleanup]   (if base was cached from an older version, delete the base and retry:"
    echo "[guest-cleanup]    rm ~/.local/share/aq/*/alpine-base-*.raw)"
    exit 1
    ;;
esac

echo "[guest-cleanup] /root/setup.conf is absent"
out=$("$AQ" exec "$VM_NAME" 'test -e /root/setup.conf && echo PRESENT || echo ABSENT')
if [ "$out" != "ABSENT" ]; then
  echo "[guest-cleanup]   FAIL: /root/setup.conf still present in the base"
  exit 1
fi
echo "[guest-cleanup]   OK"

echo "[guest-cleanup] /root/.ash_history is absent on first boot"
out=$("$AQ" exec "$VM_NAME" 'test -e /root/.ash_history && echo PRESENT || echo ABSENT')
if [ "$out" != "ABSENT" ]; then
  # Non-interactive ssh shouldn't write a history file, so seeing one here
  # means it was left over from the install session and not cleaned up.
  echo "[guest-cleanup]   FAIL: /root/.ash_history present at first boot"
  exit 1
fi
echo "[guest-cleanup]   OK"

echo "[guest-cleanup] PASSED"
