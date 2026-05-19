#!/usr/bin/env bash
# Verify the live-restore patch end-to-end:
#   1. boot a source VM, capture memory to file
#   2. start a destination QEMU with -incoming, attach QMP
#   3. expect: status == "paused" (post-migrate, NOT "paused (inmigrate)")
#   4. send `cont`, expect: status == "running"
#   5. quit cleanly
#
# Exit code:
#   0 — restore + resume worked, no assertion
#   1 — assertion or migrate failure or unexpected status

set -eu
set -o pipefail

WORKDIR=${WORKDIR:-/tmp/qemu-livesave-repro}
KERNEL=${KERNEL:-$HOME/.local/share/aq/aarch64/vmlinuz-virt}
INITRD=${INITRD:-$HOME/.local/share/aq/aarch64/initramfs-virt}
QEMU=${QEMU:-qemu-system-aarch64}
MEMORY=${MEMORY:-256M}

mkdir -p "$WORKDIR"
cd "$WORKDIR"
rm -f memory.bin qmp1.sock qmp2.sock pid1 pid2 incoming.log save.log

echo "== qemu under test =="
"$QEMU" --version | head -1

cleanup() {
  set +e
  for pf in pid1 pid2; do
    [ -f $pf ] && kill "$(cat $pf)" 2>/dev/null
  done
  rm -f qmp1.sock qmp2.sock pid1 pid2
}
trap cleanup EXIT

# --- source VM ---
"$QEMU" \
  -machine virt,highmem=on -accel hvf -cpu host -m "$MEMORY" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append 'console=ttyAMA0 quiet rdinit=/sbin/init' \
  -nographic -serial null \
  -qmp unix:qmp1.sock,server=on,wait=off \
  -daemonize -pidfile pid1 \
  -display none -parallel none -monitor none

sleep 3
export WORKDIR
python3 - <<PY
import json, os, socket, sys, time
WORKDIR = "$WORKDIR"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.path.join(WORKDIR, 'qmp1.sock'))
f = s.makefile('rwb', buffering=0)

def send(cmd): f.write((json.dumps(cmd)+'\n').encode())
def recv(): return json.loads(f.readline())

recv()
send({"execute":"qmp_capabilities"}); recv()
send({"execute":"stop"}); recv()
send({"execute":"migrate","arguments":{"uri":f"file:{WORKDIR}/memory.bin"}}); recv()
for _ in range(300):
    send({"execute":"query-migrate"}); r = recv()
    if r.get('return',{}).get('status') == 'completed': break
    if r.get('return',{}).get('status') == 'failed': sys.exit(2)
    time.sleep(0.2)
else:
    sys.exit(3)
send({"execute":"quit"})
PY

sleep 1
rm -f qmp1.sock pid1
echo "== source captured: $(ls -l memory.bin | awk '{print $5}') bytes =="

# --- destination VM ---
echo "== starting destination with -incoming =="
set +e
"$QEMU" \
  -machine virt,highmem=on -accel hvf -cpu host -m "$MEMORY" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append 'console=ttyAMA0 quiet rdinit=/sbin/init' \
  -nographic -serial null \
  -qmp unix:qmp2.sock,server=on,wait=off \
  -daemonize -pidfile pid2 \
  -display none -parallel none -monitor none \
  -incoming file:memory.bin \
  2>incoming.log
rc=$?
set -e

if [ $rc -ne 0 ]; then
  echo "FAIL: qemu exited $rc"; tail incoming.log; exit 1
fi
if grep -q 'assertion failed' incoming.log; then
  echo "FAIL: assertion fired:"; cat incoming.log; exit 1
fi

# Wait for the destination's QMP socket to exist (qemu daemonized).
for _ in $(seq 1 50); do [ -S qmp2.sock ] && break; sleep 0.1; done

python3 - <<PY
import json, os, socket, sys, time
WORKDIR = "$WORKDIR"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.path.join(WORKDIR, 'qmp2.sock'))
f = s.makefile('rwb', buffering=0)

def send(cmd): f.write((json.dumps(cmd)+'\n').encode())
def recv(): return json.loads(f.readline())

recv()
send({"execute":"qmp_capabilities"}); recv()

# Poll until incoming migration finishes. Expect 'paused' (not 'inmigrate')
for _ in range(300):
    send({"execute":"query-status"}); r = recv()
    st = r['return'].get('status'); running = r['return'].get('running')
    if st == 'paused' and not running:
        break
    if st == 'inmigrate':
        time.sleep(0.1); continue
    print('unexpected pre-cont status:', r); sys.exit(2)
else:
    print('migration did not finish to paused'); sys.exit(3)
print('post-migrate status:', st, 'running=', running)

# Send cont; expect running=True
send({"execute":"cont"}); recv()
for _ in range(50):
    send({"execute":"query-status"}); r = recv()
    if r['return'].get('running') is True and r['return'].get('status') == 'running':
        print('post-cont status: running'); break
    time.sleep(0.1)
else:
    print('did not transition to running'); sys.exit(4)

send({"execute":"quit"})
PY

echo "== PASS: restore + resume worked, no assertion =="
exit 0
