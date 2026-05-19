#!/usr/bin/env bash
# Verify the v2.5.1 stopped-VM guard: aq console / exec / scp against
# a created-but-not-started VM must fail fast with a clear error,
# not hang on a refused SSH connect.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM_NAME="aq-stopped-$$"

cleanup() {
  set +e
  "$AQ" stop "$VM_NAME" 2>/dev/null
  "$AQ" rm   "$VM_NAME" 2>/dev/null
}
trap cleanup EXIT

echo "[stopped] aq new (no start)"
"$AQ" new "$VM_NAME" >/dev/null

expect_fail() {
  local label=$1; shift
  local rc=0
  local out
  # 10 s grace; the guard should reject within ms. If it hangs we want
  # the test to fail visibly rather than block the suite.
  out=$( ( timeout 10 "$@" ) 2>&1 ) && rc=0 || rc=$?
  case "$out" in
    *"is not running"*)
      echo "[stopped] $label OK (rc=$rc; matched 'is not running')"
      ;;
    *)
      echo "[stopped] $label FAIL: expected 'is not running' in stderr"
      printf '  rc=%s\n  out=%s\n' "$rc" "$out"
      exit 1
      ;;
  esac
  if [ "$rc" = 0 ]; then
    echo "[stopped] $label FAIL: exit code should be non-zero"
    exit 1
  fi
}

expect_fail "console"        "$AQ" console "$VM_NAME"
expect_fail "exec (arg)"     "$AQ" exec    "$VM_NAME" echo hi
expect_fail "exec (stdin)"   bash -c "echo 'echo hi' | $AQ exec $VM_NAME"
echo "hi" > /tmp/aq-stopped-$$.src
expect_fail "scp host->vm"   "$AQ" scp /tmp/aq-stopped-$$.src "$VM_NAME":/tmp/x
rm -f /tmp/aq-stopped-$$.src

echo "[stopped] PASSED"
