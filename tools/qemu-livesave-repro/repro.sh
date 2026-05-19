#!/usr/bin/env bash
# Minimal repro of the QEMU ARM HVF live-restore assertion.
#
#   ERROR:target/arm/machine.c:1045:cpu_pre_load:
#     assertion failed: (!cpu->cpreg_vmstate_indexes)
#
# Procedure:
#   1. boot a tiny aarch64 guest under HVF (Alpine kernel + initramfs is enough)
#   2. capture memory state via QMP migrate file:...
#   3. spawn a fresh qemu with -incoming file:... pointing at the saved file
#   4. observe the assert in step 3's qemu
#
# No aq, no disk image, no special args beyond what QEMU itself needs.

set -eu
set -o pipefail

WORKDIR=${WORKDIR:-/tmp/qemu-livesave-repro}
KERNEL=${KERNEL:-$HOME/.local/share/aq/aarch64/vmlinuz-virt}
INITRD=${INITRD:-$HOME/.local/share/aq/aarch64/initramfs-virt}
QEMU=${QEMU:-qemu-system-aarch64}
MEMORY=${MEMORY:-256M}

mkdir -p "$WORKDIR"
cd "$WORKDIR"
rm -f memory.bin qmp1.sock pid1 incoming.log save.log

echo "== qemu version =="
"$QEMU" --version | head -1

cleanup() {
  set +e
  [ -f pid1 ] && kill "$(cat pid1)" 2>/dev/null
  rm -f qmp1.sock pid1
}
trap cleanup EXIT

echo "== step 1: boot source VM =="
"$QEMU" \
  -machine virt,highmem=on -accel hvf -cpu host -m "$MEMORY" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append 'console=ttyAMA0 quiet rdinit=/sbin/init' \
  -nographic -serial null \
  -qmp unix:qmp1.sock,server=on,wait=off \
  -daemonize -pidfile pid1 \
  -display none -parallel none -monitor none \
  2>save.log

# Wait a moment for the guest to be CPU-running (any uptime is fine for the
# repro — we don't need userspace to be ready).
sleep 3

echo "== step 2: migrate memory to file via QMP =="
export WORKDIR
python3 - <<PY > save.log 2>&1 || true
import json, os, socket, sys, time
WORKDIR = "$WORKDIR"
sock_path = os.path.join(WORKDIR, 'qmp1.sock')
out       = os.path.join(WORKDIR, 'memory.bin')

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
f = s.makefile('rwb', buffering=0)

def send(cmd):
    f.write((json.dumps(cmd)+'\n').encode())
def recv():
    line = f.readline()
    return json.loads(line) if line else None

# Banner
recv()
send({"execute":"qmp_capabilities"})
recv()

# Pause the guest
send({"execute":"stop"})
recv()

# Save memory to file via the file: migration URI
send({"execute":"migrate","arguments":{"uri":f"file:{out}"}})
recv()

# Poll until completion
for _ in range(300):
    send({"execute":"query-migrate"})
    r = recv()
    status = r.get('return',{}).get('status','?')
    print('migrate status:', status)
    if status == 'completed':
        break
    if status == 'failed':
        print('migrate failed:', r)
        sys.exit(2)
    time.sleep(0.2)
else:
    print('migrate did not complete in 60s')
    sys.exit(3)

# Quit the source VM cleanly
send({"execute":"quit"})
PY

ls -l memory.bin
sleep 1
[ -f pid1 ] && kill "$(cat pid1)" 2>/dev/null
rm -f pid1 qmp1.sock

echo "== step 3: start fresh qemu with -incoming file: =="
# Foreground, no -daemonize, capture stderr — that's where the assert lands.
set +e
"$QEMU" \
  -machine virt,highmem=on -accel hvf -cpu host -m "$MEMORY" \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append 'console=ttyAMA0 quiet rdinit=/sbin/init' \
  -nographic -serial null \
  -display none -parallel none -monitor none \
  -incoming file:memory.bin 2>&1 | tee incoming.log &
INCOMING_PID=$!
sleep 5
kill $INCOMING_PID 2>/dev/null
wait $INCOMING_PID 2>/dev/null
rc=$?
set -e

echo "== incoming exit rc=$rc =="
echo "== tail of incoming.log =="
tail -10 incoming.log

if grep -q 'cpu_pre_load.*assertion failed' incoming.log; then
  echo
  echo "== REPRO CONFIRMED: $(grep cpu_pre_load incoming.log | head -1) =="
  exit 0
fi
echo
echo "== assertion did NOT fire; behavior different from prior reports =="
exit 1
