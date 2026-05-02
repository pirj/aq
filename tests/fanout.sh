#!/usr/bin/env bash
# E2E test for aq fanout.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
SRC_VM="aq-fan-src-$$"
TAG="aq-fan-test-$$"
PREFIX="aq-fan-shard-$$"
N=4

cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" 2>/dev/null
  "$AQ" rm   "$SRC_VM" 2>/dev/null
  local i=0
  while [ $i -lt $N ]; do
    "$AQ" stop "$PREFIX-$i" 2>/dev/null
    "$AQ" rm   "$PREFIX-$i" 2>/dev/null
    "$AQ" stop "$PREFIX-fail-$i" 2>/dev/null
    "$AQ" rm   "$PREFIX-fail-$i" 2>/dev/null
    i=$((i + 1))
  done
  "$AQ" snapshot rm --force "$TAG" 2>/dev/null
}
trap cleanup EXIT

echo "[fan] aq new + provision $SRC_VM"
"$AQ" new "$SRC_VM"
"$AQ" start "$SRC_VM"
"$AQ" exec "$SRC_VM" 'echo provisioned > /root/state'

echo "[fan] aq snapshot create (live, so shards inherit running state)"
"$AQ" snapshot create "$SRC_VM" "$TAG"

echo "[fan] aq stop + rm $SRC_VM"
"$AQ" stop "$SRC_VM"
"$AQ" rm "$SRC_VM"

echo "[fan] aq fanout $TAG $N (success path)"
out=$("$AQ" fanout "$TAG" "$N" --prefix="$PREFIX" -- 'echo "I am $AQ_SHARD_INDEX of $AQ_SHARD_TOTAL"; cat /root/state' 2>&1)
echo "$out"

i=0
while [ $i -lt $N ]; do
  if ! echo "$out" | grep -q "\[$PREFIX-$i\] I am $i of $N"; then
    echo "[fan] FAIL: missing line for shard $i"
    exit 1
  fi
  i=$((i + 1))
done

if [ "$(echo "$out" | grep -c 'provisioned')" != "$N" ]; then
  echo "[fan] FAIL: expected $N occurrences of 'provisioned', got $(echo "$out" | grep -c 'provisioned')"
  exit 1
fi

if "$AQ" ls | grep -q "^$PREFIX-"; then
  echo "[fan] FAIL: shards not cleaned up after fanout"
  "$AQ" ls
  exit 1
fi

echo "[fan] aq fanout exit-code aggregation"
set +e
"$AQ" fanout "$TAG" "$N" --prefix="$PREFIX-fail" -- 'exit $AQ_SHARD_INDEX' >/dev/null 2>&1
fanout_exit=$?
set -e
if [ "$fanout_exit" != "3" ]; then
  echo "[fan] FAIL: expected fanout exit 3 (max of 0..3), got $fanout_exit"
  exit 1
fi

echo "[fan] PASSED"
