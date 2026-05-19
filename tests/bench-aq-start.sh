#!/usr/bin/env bash
# Micro-benchmark for warm `aq start` wall time.
#
# Usage:
#   tests/bench-aq-start.sh [-n RUNS] [-l LABEL]
#
# Reads optional perf knobs from env so callers can A/B without editing
# the script:
#   AQ_DRIVE_EXTRA, AQ_QEMU_EXTRA_ARGS, AQ_MACHINE_OVERRIDE,
#   AQ_KERNEL_APPEND_EXTRA
# (See `aq_start` for what each one does.)
#
# Workflow per run:
#   1. aq new   <name>   (overlay create, <1 s)
#   2. aq start <name>   ← measured
#   3. aq stop  <name>
#   4. aq rm    <name>
#
# Emits one TSV line per run + a summary block. Output is suitable for
# pasting into a markdown table.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
RUNS=5
LABEL="default"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) RUNS=$2; shift 2 ;;
    -l) LABEL=$2; shift 2 ;;
    *) echo "Usage: $0 [-n RUNS] [-l LABEL]" >&2; exit 2 ;;
  esac
done

trap 'stat=$?; cleanup; exit $stat' EXIT

VMS=()
cleanup() {
  set +e
  local vm
  for vm in "${VMS[@]:-}"; do
    [ -n "$vm" ] || continue
    "$AQ" stop "$vm" >/dev/null 2>&1
    "$AQ" rm   "$vm" >/dev/null 2>&1
  done
}

# Pre-build the base on a throwaway VM so the timed runs measure
# warm-only start, not the one-shot ~30 s base build.
warmup_vm="aq-bench-warmup-$$"
"$AQ" new --size=2G "$warmup_vm" >/dev/null 2>&1
VMS+=("$warmup_vm")
"$AQ" start "$warmup_vm" >/dev/null 2>&1
"$AQ" stop  "$warmup_vm" >/dev/null 2>&1

echo "# label=$LABEL runs=$RUNS"
echo "# AQ_DRIVE_EXTRA=${AQ_DRIVE_EXTRA:-}"
echo "# AQ_QEMU_EXTRA_ARGS=${AQ_QEMU_EXTRA_ARGS:-}"
echo "# AQ_MACHINE_OVERRIDE=${AQ_MACHINE_OVERRIDE:-}"
echo "# AQ_KERNEL_APPEND_EXTRA=${AQ_KERNEL_APPEND_EXTRA:-}"

times_ms=()

for i in $(seq 1 "$RUNS"); do
  vm="aq-bench-${LABEL}-$$-$i"
  "$AQ" new --size=2G "$vm" >/dev/null 2>&1
  VMS+=("$vm")

  # bash $SECONDS is integer; use date +%s%N for ms precision. Both BSD
  # date (macOS) and GNU date (Linux) emit ns when given %N.
  start_ns=$(date +%s%N)
  "$AQ" start "$vm" >/dev/null 2>&1
  end_ns=$(date +%s%N)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  "$AQ" stop "$vm" >/dev/null 2>&1
  "$AQ" rm   "$vm" >/dev/null 2>&1

  times_ms+=("$ms")
  printf 'run\t%d\t%s\t%d\tms\n' "$i" "$LABEL" "$ms"
done

# Summary: min / median / max in ms
sorted=$(printf '%s\n' "${times_ms[@]}" | sort -n)
n=${#times_ms[@]}
min_ms=$(echo "$sorted" | head -1)
max_ms=$(echo "$sorted" | tail -1)
# median: middle element for odd N, lower-middle for even N (good enough
# for our sample sizes).
mid=$(( (n + 1) / 2 ))
median_ms=$(echo "$sorted" | sed -n "${mid}p")

printf 'summary\t%s\tmin=%dms median=%dms max=%dms n=%d\n' \
  "$LABEL" "$min_ms" "$median_ms" "$max_ms" "$n"
