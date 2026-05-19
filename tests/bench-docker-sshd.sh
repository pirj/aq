#!/usr/bin/env bash
# Micro-benchmark: time `docker run -d panubo/sshd` to the moment the
# container's sshd accepts a TCP connection on the forwarded host port.
# (The GitHub repo is panubo/docker-sshd; the Docker Hub image is named
# panubo/sshd — a panubo naming convention.)
#
# Usage:
#   tests/bench-docker-sshd.sh [-n RUNS] [-l LABEL]
#
# Methodology mirrors tests/bench-aq-start.sh:
#   - The image is assumed already pulled (cold pull is a separate concern,
#     equivalent to aq's one-time per-size base build).
#   - Each iteration runs a fresh container and probes 127.0.0.1:<host-port>
#     with `nc -z -w 1` at 100 ms cadence until it accepts.
#   - Container is stopped+removed after each iteration so we measure
#     cold-from-image, not "container already exists".
#
# Output is one TSV line per run + a summary line, exactly like
# bench-aq-start.sh, so the same downstream parser handles both.

set -eu
set -o pipefail

IMAGE="${IMAGE:-panubo/sshd}"
RUNS=5
LABEL="docker_sshd"
PROBE_INTERVAL="${AQ_SSH_PROBE_INTERVAL:-0.1}"

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
    docker rm -f "$cid" >/dev/null 2>&1
  done
}
trap 'stat=$?; cleanup; exit $stat' EXIT

# Pick a free high port for each run. We don't reuse the port across
# iterations because tearing down a container leaves TIME_WAIT entries
# that occasionally race the next bind.
pick_port() {
  local p
  while :; do
    p=$(shuf -i 49152-65535 -n 1)
    if ! nc -z -w 1 127.0.0.1 "$p" 2>/dev/null; then
      echo "$p"; return
    fi
  done
}

echo "# label=$LABEL runs=$RUNS image=$IMAGE probe=${PROBE_INTERVAL}s"

times_ms=()

for i in $(seq 1 "$RUNS"); do
  port=$(pick_port)

  start_ns=$(date +%s%N)
  cid=$(docker run -d --rm -p "127.0.0.1:${port}:22" "$IMAGE")
  CIDS+=("$cid")

  # Probe TCP-accept on the forwarded port. nc -z -w 1 returns 0 once
  # something accepts. This matches what `aq` waits for: connect() success.
  # No actual ssh handshake — the aq bench measures TCP+ssh-ready, but on
  # the panubo image the moment TCP accepts is the moment sshd is up
  # (it's the only listener on the published port).
  deadline=$(( $(date +%s) + 60 ))
  while ! nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "[docker-sshd] FAIL: ssh never came up on $port in 60s" >&2
      docker logs "$cid" >&2 || true
      exit 1
    fi
    sleep "$PROBE_INTERVAL"
  done
  end_ns=$(date +%s%N)
  ms=$(( (end_ns - start_ns) / 1000000 ))

  docker rm -f "$cid" >/dev/null 2>&1
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
