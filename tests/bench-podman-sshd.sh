#!/usr/bin/env bash
# Micro-benchmark: time `podman run -d panubo/sshd` to TCP-accept on the
# forwarded host port. Mirrors tests/bench-docker-sshd.sh so the two
# numbers are directly comparable on the same runner.

set -eu
set -o pipefail

IMAGE="${IMAGE:-panubo/sshd}"
RUNS=5
LABEL="podman_sshd"
PROBE_INTERVAL="${AQ_SSH_PROBE_INTERVAL:-0.1}"
PODMAN="${PODMAN:-podman}"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) RUNS=$2; shift 2 ;;
    -l) LABEL=$2; shift 2 ;;
    *) echo "Usage: $0 [-n RUNS] [-l LABEL]" >&2; exit 2 ;;
  esac
done

CIDS=()
cleanup() {
  set +e
  local cid
  for cid in "${CIDS[@]:-}"; do
    [ -n "$cid" ] || continue
    "$PODMAN" rm -f "$cid" >/dev/null 2>&1
  done
}
trap 'stat=$?; cleanup; exit $stat' EXIT

pick_port() {
  local p
  while :; do
    p=$(shuf -i 49152-65535 -n 1)
    if ! nc -z -w 1 127.0.0.1 "$p" 2>/dev/null; then
      echo "$p"; return
    fi
  done
}

echo "# label=$LABEL runs=$RUNS image=$IMAGE probe=${PROBE_INTERVAL}s podman=$($PODMAN --version 2>&1 | head -1)"

times_ms=()
for i in $(seq 1 "$RUNS"); do
  port=$(pick_port)

  start_ns=$(date +%s%N)
  cid=$("$PODMAN" run -d --rm -p "127.0.0.1:${port}:22" "$IMAGE")
  CIDS+=("$cid")

  deadline=$(( $(date +%s) + 60 ))
  while ! nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "[podman-sshd] FAIL: ssh never came up on $port in 60s" >&2
      "$PODMAN" logs "$cid" >&2 || true
      exit 1
    fi
    sleep "$PROBE_INTERVAL"
  done
  end_ns=$(date +%s%N)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  "$PODMAN" rm -f "$cid" >/dev/null 2>&1
  CIDS=()

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
