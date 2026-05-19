#!/usr/bin/env bash
# Micro-benchmark for macpine: time `alpine start <vm>` to SSH-accept.
#
# Prelude (untimed):
#   - `alpine launch` creates and starts a new instance (this includes
#     image download for the first run; that's a one-time per-image cost,
#     analogous to aq's per-size base build).
#   - Wait once for SSH so we know it's fully provisioned, then `alpine
#     stop` so the timed loop starts from a stopped state.
#
# Loop (timed):
#   - `alpine start <vm>` then probe TCP-accept on the forwarded host
#     SSH port at the same cadence as the other benches (100 ms).
#   - `alpine stop` before the next iteration.

set -eu
set -o pipefail

MACPINE="${MACPINE:-alpine}"
RUNS=5
LABEL="macpine_start"
PROBE_INTERVAL="${AQ_SSH_PROBE_INTERVAL:-0.1}"
IMAGE="${MACPINE_IMAGE:-alpine_3.20.3}"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) RUNS=$2; shift 2 ;;
    -l) LABEL=$2; shift 2 ;;
    *) echo "Usage: $0 [-n RUNS] [-l LABEL]" >&2; exit 2 ;;
  esac
done

# Pick a free high port for SSH forwarding once; same VM across all runs.
pick_port() {
  local p
  while :; do
    p=$(shuf -i 49152-65535 -n 1)
    if ! nc -z -w 1 127.0.0.1 "$p" 2>/dev/null; then
      echo "$p"; return
    fi
  done
}
SSH_PORT=$(pick_port)
VM="mpbench-$$"

cleanup() {
  set +e
  "$MACPINE" stop "$VM" >/dev/null 2>&1
  "$MACPINE" delete "$VM" --force >/dev/null 2>&1 || "$MACPINE" delete "$VM" >/dev/null 2>&1
}
trap 'stat=$?; cleanup; exit $stat' EXIT

echo "# label=$LABEL runs=$RUNS image=$IMAGE port=$SSH_PORT probe=${PROBE_INTERVAL}s macpine=$($MACPINE help 2>&1 | head -1)"

# Prelude: launch and wait for SSH once, then stop.
echo "# [prelude] launch + first-boot wait"
"$MACPINE" launch -n "$VM" -d 2G -m 1024 -i "$IMAGE" -s "$SSH_PORT" >/dev/null 2>&1

prelude_deadline=$(( $(date +%s) + 120 ))
while ! nc -z -w 1 127.0.0.1 "$SSH_PORT" 2>/dev/null; do
  if [ "$(date +%s)" -gt "$prelude_deadline" ]; then
    echo "[macpine] FAIL: SSH never came up on $SSH_PORT during prelude" >&2
    exit 1
  fi
  sleep 0.2
done

"$MACPINE" stop "$VM" >/dev/null 2>&1
# Belt-and-suspenders: wait for the port to actually close.
while nc -z -w 1 127.0.0.1 "$SSH_PORT" 2>/dev/null; do sleep 0.2; done

times_ms=()
for i in $(seq 1 "$RUNS"); do
  start_ns=$(date +%s%N)
  "$MACPINE" start "$VM" >/dev/null 2>&1

  deadline=$(( $(date +%s) + 120 ))
  while ! nc -z -w 1 127.0.0.1 "$SSH_PORT" 2>/dev/null; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "[macpine] FAIL: SSH never came up on $SSH_PORT in 120s (run $i)" >&2
      exit 1
    fi
    sleep "$PROBE_INTERVAL"
  done
  end_ns=$(date +%s%N)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  "$MACPINE" stop "$VM" >/dev/null 2>&1
  while nc -z -w 1 127.0.0.1 "$SSH_PORT" 2>/dev/null; do sleep 0.2; done

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
