#!/usr/bin/env bash
# Micro-benchmark for `aq new --from-snapshot=<live-tag>` + `aq start`.
#
# What it measures: wall time from invoking the script's `aq start` until
# SSH accepts on the forwarded port. The source VM was already booted
# once, provisioned, snapshotted with memory, then torn down — so each
# iteration restores from `memory.bin` via QEMU `-incoming` rather than
# cold-booting the kernel. Roughly the equivalent of a sub-second
# "resume" instead of the ~5–7 s "boot".
#
# Methodology mirrors tests/bench-aq-start.sh:
#   - One-time prelude: build the size-2G base, create+start a source
#     VM, snapshot it live, rm it. The snapshot stays around for the
#     loop.
#   - Loop: aq new --from-snapshot=<tag> $vm-$i ; time aq start $vm-$i ;
#     aq stop + rm.
#   - Same env-var hooks (AQ_DRIVE_EXTRA, AQ_SSH_PROBE_INTERVAL) apply
#     during `aq start`, so the bench-vs-* workflow's 100 ms probe
#     setting carries through.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
RUNS=5
LABEL="aq_live_restore"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) RUNS=$2; shift 2 ;;
    -l) LABEL=$2; shift 2 ;;
    *) echo "Usage: $0 [-n RUNS] [-l LABEL]" >&2; exit 2 ;;
  esac
done

SRC_VM="aq-bench-live-src-$$"
TAG="aq-bench-live-$$"

DST_VMS=()
cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" >/dev/null 2>&1
  "$AQ" rm   "$SRC_VM" >/dev/null 2>&1
  local vm
  for vm in "${DST_VMS[@]:-}"; do
    [ -n "$vm" ] || continue
    "$AQ" stop "$vm" >/dev/null 2>&1
    "$AQ" rm   "$vm" >/dev/null 2>&1
  done
  "$AQ" snapshot rm --force "$TAG" >/dev/null 2>&1
}
trap 'stat=$?; cleanup; exit $stat' EXIT

echo "# label=$LABEL runs=$RUNS tag=$TAG"
echo "# AQ_SSH_PROBE_INTERVAL=${AQ_SSH_PROBE_INTERVAL:-(default 0.5)}"

echo "# [prelude] aq new + start + provision + snapshot create"
"$AQ" new --size=2G "$SRC_VM" >/dev/null 2>&1
"$AQ" start "$SRC_VM"          >/dev/null 2>&1
# A tiny marker in /dev/shm so a manual check would still see live state.
"$AQ" exec "$SRC_VM" 'echo bench-live > /dev/shm/aq-bench-marker' >/dev/null 2>&1
"$AQ" snapshot create "$SRC_VM" "$TAG" >/dev/null 2>&1
"$AQ" stop "$SRC_VM" >/dev/null 2>&1
"$AQ" rm   "$SRC_VM" >/dev/null 2>&1

times_ms=()
for i in $(seq 1 "$RUNS"); do
  vm="aq-bench-live-dst-$$-$i"
  "$AQ" new --from-snapshot="$TAG" "$vm" >/dev/null 2>&1
  DST_VMS+=("$vm")

  start_ns=$(date +%s%N)
  "$AQ" start "$vm" >/dev/null 2>&1
  end_ns=$(date +%s%N)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  "$AQ" stop "$vm" >/dev/null 2>&1
  "$AQ" rm   "$vm" >/dev/null 2>&1

  times_ms+=("$ms")
  printf 'run\t%d\t%s\t%d\tms\n' "$i" "$LABEL" "$ms"
done

sorted=$(printf '%s\n' "${times_ms[@]}" | sort -n)
n=${#times_ms[@]}
min_ms=$(echo "$sorted" | head -1)
max_ms=$(echo "$sorted" | tail -1)
mid=$(( (n + 1) / 2 ))
median_ms=$(echo "$sorted" | sed -n "${mid}p")

printf 'summary\t%s\tmin=%dms median=%dms max=%dms n=%d\n' \
  "$LABEL" "$min_ms" "$median_ms" "$max_ms" "$n"
