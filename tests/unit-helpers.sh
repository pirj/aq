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

echo "All unit-helpers tests passed."
