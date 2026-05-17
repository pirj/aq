#!/usr/bin/env bash
# Unit tests for pure-logic helpers in aq.
set -eu
set -o pipefail

AQ_PATH="${AQ:-./aq}"

# Source the aq script but skip its main dispatch by setting the guard.
# DEBUG must be defined because aq does `[ -z "$DEBUG" ]` under `set -u`.
__AQ_SOURCED_ONLY=1 DEBUG="" source "$AQ_PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# parse_size_arg
[ "$(parse_size_arg 8G)" = "8" ]      || fail "parse_size_arg 8G -> 8"
[ "$(parse_size_arg 16G)" = "16" ]    || fail "parse_size_arg 16G -> 16"
[ "$(parse_size_arg 2G)" = "2" ]      || fail "parse_size_arg 2G -> 2"
parse_size_arg 8 2>/dev/null          && fail "parse_size_arg 8 (no suffix) should error"
parse_size_arg 8M 2>/dev/null         && fail "parse_size_arg 8M (wrong unit) should error"
parse_size_arg garbage 2>/dev/null    && fail "parse_size_arg garbage should error"
parse_size_arg 0G 2>/dev/null         && fail "parse_size_arg 0G should error"
pass "parse_size_arg"

# compute_base_filename
[ "$(compute_base_filename 3.22.4 aarch64 8)" = "alpine-base-3.22.4-aarch64-8G.raw" ] \
  || fail "compute_base_filename 3.22.4 aarch64 8"
[ "$(compute_base_filename 3.22.4 x86_64 16)" = "alpine-base-3.22.4-x86_64-16G.raw" ] \
  || fail "compute_base_filename 3.22.4 x86_64 16"
pass "compute_base_filename"

# parse_new_args
parse_new_args --size=8G dummy-vm
[ "$NEW_SIZE" = "8" ] || fail "parse_new_args --size=8G -> NEW_SIZE=8 (got '$NEW_SIZE')"
[ "$VM_NAME"  = "dummy-vm" ] || fail "parse_new_args dummy-vm -> VM_NAME (got '$VM_NAME')"
[ "$SKIP_FAST_BOOT" = "0" ] || fail "default SKIP_FAST_BOOT=0 (got '$SKIP_FAST_BOOT')"

parse_new_args --skip-fast-boot --size 16G --from-snapshot=foo bar
[ "$NEW_SIZE" = "16" ] || fail "parse_new_args --size 16G -> NEW_SIZE=16 (got '$NEW_SIZE')"
[ "$SKIP_FAST_BOOT" = "1" ] || fail "parse_new_args --skip-fast-boot -> 1"
[ "$FROM_SNAPSHOT" = "foo" ] || fail "parse_new_args --from-snapshot=foo (got '$FROM_SNAPSHOT')"
[ "$VM_NAME" = "bar" ] || fail "parse_new_args ... bar (got '$VM_NAME')"

parse_new_args
[ "$NEW_SIZE" = "2" ] || fail "default NEW_SIZE=2 (got '$NEW_SIZE')"
[ "$VM_NAME" = "" ] || fail "default VM_NAME empty (got '$VM_NAME')"
[ "$COUNT" = "1" ] || fail "default COUNT=1 (got '$COUNT')"

pass "parse_new_args"

echo "All unit-helpers tests passed."
