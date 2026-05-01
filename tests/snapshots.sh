#!/usr/bin/env bash
# E2E test for aq snapshots.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
SRC_VM="aq-snap-src-$$"
DST_VM="aq-snap-dst-$$"
TAG="aq-snap-test-$$"

cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" 2>/dev/null
  "$AQ" rm   "$SRC_VM" 2>/dev/null
  "$AQ" stop "$DST_VM" 2>/dev/null
  "$AQ" rm   "$DST_VM" 2>/dev/null
  "$AQ" snapshot rm --force "$TAG" 2>/dev/null
}
trap cleanup EXIT

echo "[snap] aq new $SRC_VM"
"$AQ" new "$SRC_VM"
"$AQ" start "$SRC_VM"

echo "[snap] mark inside VM"
"$AQ" exec "$SRC_VM" 'echo "marker-$(uname -m)" > /root/snapmarker'

echo "[snap] stop source VM"
"$AQ" stop "$SRC_VM"

echo "[snap] aq snapshot create $SRC_VM $TAG"
"$AQ" snapshot create "$SRC_VM" "$TAG"

echo "[snap] aq snapshot ls"
"$AQ" snapshot ls | grep -q "$TAG" || { echo "[snap] FAIL: $TAG not in ls"; exit 1; }

echo "[snap] aq rm $SRC_VM (source VM no longer needed)"
"$AQ" rm "$SRC_VM"

echo "[snap] aq new --from-snapshot=$TAG $DST_VM"
"$AQ" new --from-snapshot="$TAG" "$DST_VM"
"$AQ" start "$DST_VM"

echo "[snap] verify marker survived"
out=$("$AQ" exec "$DST_VM" 'cat /root/snapmarker')
if ! echo "$out" | grep -q '^marker-'; then
  echo "[snap] FAIL: expected marker-*, got '$out'"
  exit 1
fi

echo "[snap] verify refcount = 1"
refs=$("$AQ" snapshot ls | awk -v t="$TAG" '$1 == t { print $3 }')
if [ "$refs" != "1" ]; then
  echo "[snap] FAIL: expected refcount 1, got '$refs'"
  exit 1
fi

echo "[snap] aq rm $DST_VM"
"$AQ" rm "$DST_VM"

echo "[snap] verify refcount = 0 after dst removed"
refs=$("$AQ" snapshot ls | awk -v t="$TAG" '$1 == t { print $3 }')
if [ "$refs" != "0" ]; then
  echo "[snap] FAIL: expected refcount 0 after rm, got '$refs'"
  exit 1
fi

echo "[snap] aq snapshot rm $TAG"
"$AQ" snapshot rm "$TAG"

echo "[snap] PASSED"
