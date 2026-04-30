#!/usr/bin/env bash
# Smoke test for aq: full lifecycle.
# Exits non-zero on any failure. Cleans up VM on exit.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM_NAME="aq-smoke-$$"

cleanup() {
  set +e
  "$AQ" stop "$VM_NAME" 2>/dev/null
  "$AQ" rm "$VM_NAME" 2>/dev/null
}
trap cleanup EXIT

echo "[smoke] aq new"
"$AQ" new "$VM_NAME"

echo "[smoke] aq start"
"$AQ" start "$VM_NAME"

echo "[smoke] aq exec (arg form)"
output=$("$AQ" exec "$VM_NAME" echo hello)
if [ "$output" != "hello" ]; then
  echo "[smoke] FAIL: arg-form expected 'hello', got '$output'"
  exit 1
fi

echo "[smoke] aq exec (stdin form)"
output=$(echo 'echo from-stdin' | "$AQ" exec "$VM_NAME")
if [ "$output" != "from-stdin" ]; then
  echo "[smoke] FAIL: stdin-form expected 'from-stdin', got '$output'"
  exit 1
fi

echo "[smoke] aq stop"
"$AQ" stop "$VM_NAME"

echo "[smoke] aq rm"
"$AQ" rm "$VM_NAME"

echo "[smoke] PASSED"
