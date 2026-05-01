# Phase 2B — Live Memory Snapshots: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture a running VM's memory state alongside its disk so a derived VM can restore the exact running state in seconds (sub-second target on M2), skipping Alpine's cold boot entirely.

**Architecture:** Add a QMP (JSON monitor) socket to every running VM. `aq snapshot create` on a running VM pauses it via QMP `stop`, dumps memory state via QMP `human-monitor-command "migrate exec:cat > memory.bin"`, copies the disk image, then resumes via `cont`. `aq new --from-snapshot=<tag>` of a snapshot whose `meta.json` reports `has_memory: true` arranges for the next `aq start` to launch qemu with `-incoming "exec:cat memory.bin"` — qemu reads the saved migration stream and resumes at the snapshot point. Phase 2A's cold-snapshot path remains for stopped-VM snapshots.

**Tech Stack:** bash, qemu QMP protocol over unix socket, qemu migration framework (`migrate`/`-incoming`), socat for QMP wire transport, no jq dependency (grep/sed for JSON extraction).

**Reference:** `docs/specs/2026-04-30-aq-ci-snapshots-design.md` (Layer 2 — Snapshot create/restore semantics, Phase 2 success metric).

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `aq` | Modify | Add `-qmp` socket to every qemu invocation that creates a runtime VM (currently just `aq_start`). Add `qmp_hmp` helper. Extend `aq_snapshot_create` with a running-VM branch (pause + migrate + cp + cont). Extend `aq_new --from-snapshot` to copy `memory.bin` reference into the new VM dir. Extend `aq_start` to add `-incoming` when an incoming memory file is present. |
| `tests/live-snapshots.sh` | Create | E2E: provision a VM, leave a tmpfs marker, snapshot the running VM, derive a new VM, verify the tmpfs marker survives (proves memory was restored, not just cold-booted). |
| `tests/run.sh` | Modify | Add `bash tests/live-snapshots.sh` after the existing tests. |
| `README.md` | Modify | Update the Snapshots section to mention live snapshots. |
| `CHANGELOG.md` | Modify | 2.2.0 entry. |
| `aq` (VERSION) | Modify | `VERSION=2.2.0`. |

The `aq` script stays one file. Phase 2A code paths are preserved.

---

## CLI Surface (delta vs Phase 2A)

```
aq snapshot create <vm-name> <tag>
    Phase 2A behaviour preserved when VM is stopped.
    NEW: when VM is running, captures live memory + disk state. The VM
    is paused for a few seconds during capture, then resumes.

aq new --from-snapshot=<tag> [vm-name]
    Phase 2A behaviour preserved for cold snapshots.
    NEW: when the snapshot has memory state (meta.json: has_memory=true),
    the next `aq start` boots via -incoming and resumes at the snapshot
    point — no Alpine boot, no first_boot_setup.

aq start <vm-name>
    Picks up an `incoming-memory.bin` file in the VM dir and starts qemu
    with -incoming "exec:cat …". After a successful start, the file is
    removed (it's one-shot — qemu consumes the migration stream).
```

---

## meta.json Schema (Phase 2B additions)

`has_memory` flips to `true` when memory was captured. No new fields.

```json
{
  "tag": "rails-running",
  "parent": "rails-deps",
  "arch": "x86_64",
  "base_image": "alpine-base-3.22.2-x86_64.raw",
  "created": "2026-05-01T18:30:00Z",
  "last_used": "2026-05-01T18:30:00Z",
  "source_vm": "myrails",
  "has_memory": true
}
```

The memory state itself lives at `snapshots/<arch>/<tag>/memory.bin`.

---

## Cache Layout (Phase 2B addition)

```
~/.local/share/aq/snapshots/<arch>/<tag>/
├── disk.qcow2
├── memory.bin     # NEW (only if has_memory=true)
├── meta.json      # has_memory: true
└── (no refcount — see 2.1.1 release notes)
```

VM-side, when a snapshot with memory is restored:

```
~/.local/share/aq/<vm-name>/
├── storage.qcow2
├── uefi-vars.{json,fd}
├── hostfwd.conf
├── ssh-port.conf
├── .from_snapshot
└── incoming-memory.bin   # NEW: hard-linked to the snapshot's memory.bin;
                          # consumed and removed by the first aq_start.
```

We hard-link instead of copy to avoid duplicating hundreds of MB on every `aq new --from-snapshot`. Hard links work inside the same filesystem; if it fails (rare — different mounts), fall back to copy.

---

## Task 0: Branch and baseline

**Files:** none changed.

- [ ] **Step 1: Branch from main**

```bash
git checkout main
git pull --ff-only
git checkout -b phase-2b-live-snapshots
```

- [ ] **Step 2: Baseline tests on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED` and `[snap] PASSED`. Confirms Phase 2A is intact.

---

## Task 1: QMP socket on running VMs

A second monitor socket on the JSON QMP protocol, alongside the existing readline HMP `control.sock`. The HMP socket stays for `add_ssh_forward` and `quit`; QMP is used for the new structured operations (`stop`, `cont`, `migrate`).

**Files:**
- Modify: `aq` (add helper near other socket helpers; extend `aq_start` qemu invocation)

- [ ] **Step 1: Add qmp_hmp helper**

Insert into `aq` near `add_ssh_forward` (around line 600 in the post-2.1.1 file):

```bash
# Run an HMP command via the QMP wrapper. Returns when the HMP command
# completes. The QMP wire format is JSON; we send qmp_capabilities then the
# wrapped HMP command in a single connection. socat -t300 keeps the socket
# open long enough for slow operations like `migrate` of a 1 GB memory image
# (typical cap on aq VMs).
qmp_hmp() {
  local sock=$1
  local hmp_cmd=$2
  # Escape backslashes and double quotes in the HMP command for JSON.
  local escaped
  escaped=$(printf '%s' "$hmp_cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"execute":"qmp_capabilities"}\n{"execute":"human-monitor-command","arguments":{"command-line":"%s"}}\n' \
    "$escaped" \
    | socat -t300 - "UNIX-CONNECT:$sock" 2>/dev/null
}
```

- [ ] **Step 2: Extend aq_start qemu invocation with `-qmp`**

Find the qemu invocation in `aq_start`. Add a `-qmp unix:...,server=on,wait=off` line to the existing argument list. The existing line near `-mon chardev=mon0,...` is the right place.

Old (one block of arguments inside `aq_start`):
```bash
    -mon chardev=mon0,mode=readline -chardev socket,id=mon0,path=$BASE_DIR/$VM_NAME/control.sock,server=on,wait=off \
    -daemonize -pidfile $BASE_DIR/$VM_NAME/process.pid \
```

New:
```bash
    -mon chardev=mon0,mode=readline -chardev socket,id=mon0,path=$BASE_DIR/$VM_NAME/control.sock,server=on,wait=off \
    -qmp unix:$BASE_DIR/$VM_NAME/qmp.sock,server=on,wait=off \
    -daemonize -pidfile $BASE_DIR/$VM_NAME/process.pid \
```

Note: bootstrap_base_image's qemu invocation does not get `-qmp`. It's a one-shot install path that doesn't snapshot its state.

- [ ] **Step 3: Smoke test on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED` and `[snap] PASSED`. The new -qmp arg shouldn't affect existing flows.

- [ ] **Step 4: Manual QMP sanity check**

```bash
VM=qmp-probe-$$
./aq new "$VM"
./aq start "$VM"
ls -la ~/.local/share/aq/$VM/qmp.sock
qmp_response=$(./aq qmp_hmp_test "$VM" 'info status' 2>/dev/null) || true
# Quick inline probe: send qmp_capabilities + info status, expect a JSON response.
printf '{"execute":"qmp_capabilities"}\n{"execute":"human-monitor-command","arguments":{"command-line":"info status"}}\n' \
  | socat -t5 - UNIX-CONNECT:"$HOME/.local/share/aq/$VM/qmp.sock"
./aq rm "$VM"
```

Expected: socket file exists; the socat invocation prints something like:
```
{"QMP": {"version": ..., "capabilities": []}}
{"return": {}}
{"return": "VM status: running\r\n"}
```

The `"VM status: running"` line is what we'll parse later.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Add QMP socket and qmp_hmp helper to running VMs"
```

---

## Task 2: Live snapshot path in `aq_snapshot_create`

Branch on `is_vm_running`. If running, capture memory; if stopped, the existing Phase 2A flow.

**Files:**
- Modify: `aq` (`aq_snapshot_create`)

- [ ] **Step 1: Replace aq_snapshot_create body**

Find `aq_snapshot_create` (added in Phase 2A). Replace it with:

```bash
aq_snapshot_create() {
  local vm_name=${1:-}
  local tag=${2:-}
  [ -z "$vm_name" ] && stderr 'Error: VM name required: `aq snapshot create <vm-name> <tag>`.' && exit 1
  [ -z "$tag" ]     && stderr 'Error: tag required: `aq snapshot create <vm-name> <tag>`.' && exit 1
  ! vm_exists "$vm_name" && stderr "Error: VM '$vm_name' does not exist." && exit 1
  if snapshot_exists "$tag"; then
    stderr "Error: snapshot '$tag' already exists. Pick a new tag or remove the existing one with: aq snapshot rm $tag"
    exit 1
  fi

  local source_disk="$BASE_DIR/$vm_name/storage.qcow2"
  [ -f "$source_disk" ] || { stderr "Error: source disk not found: $source_disk"; exit 1; }

  # Determine parent: read the qcow2 backing-file basename.
  local backing
  backing=$(qemu-img info --output=json "$source_disk" 2>/dev/null \
            | grep -E '"backing-filename":' \
            | sed -E 's/.*"backing-filename": "([^"]*)".*/\1/' \
            | head -1)
  local parent="base"
  if [ -n "$backing" ]; then
    case "$backing" in
      *"$LATEST_ALPINE_BASE") parent="base" ;;
      *snapshots/*/disk.qcow2)
        parent=$(echo "$backing" | sed -E 's|.*/snapshots/[^/]+/([^/]+)/disk.qcow2|\1|')
        ;;
      *)
        parent="unknown"
        ;;
    esac
  fi

  local snap_dir
  snap_dir=$(snapshot_path "$tag")
  mkdir -p "$snap_dir"

  local has_memory=false
  if is_vm_running "$vm_name"; then
    # Live snapshot: pause, dump memory, copy disk, resume.
    local qmp_sock="$BASE_DIR/$vm_name/qmp.sock"
    [ -S "$qmp_sock" ] || { stderr "Error: QMP socket missing for running VM '$vm_name'. Restart the VM with this version of aq first."; rm -rf "$snap_dir"; exit 1; }

    stderr "Live snapshot: pausing VM..."
    vm_ssh "$vm_name" 'sync && sync' 2>/dev/null || true
    qmp_hmp "$qmp_sock" 'stop' >/dev/null

    stderr "Live snapshot: capturing memory state..."
    # Note the >file redirection is interpreted by qemu's exec: URI handler,
    # which spawns sh -c. Quote the path to handle spaces in VM dirs.
    qmp_hmp "$qmp_sock" "migrate exec:cat > '$snap_dir/memory.bin'" >/dev/null

    stderr "Live snapshot: copying disk..."
    cp "$source_disk" "$snap_dir/disk.qcow2"

    stderr "Live snapshot: resuming VM..."
    qmp_hmp "$qmp_sock" 'cont' >/dev/null

    has_memory=true
  else
    # Cold snapshot (Phase 2A behaviour).
    cp "$source_disk" "$snap_dir/disk.qcow2"
  fi

  write_meta "$tag" "$parent" "$vm_name" "$has_memory"

  if [ "$has_memory" = true ]; then
    stderr "Snapshot created: $tag (parent: $parent, with memory)"
  else
    stderr "Snapshot created: $tag (parent: $parent)"
  fi
}
```

- [ ] **Step 2: Update write_meta to take has_memory arg**

Find `write_meta` in `aq` and replace it:

```bash
# Atomically write meta.json. Args: <tag> <parent> <source_vm> <has_memory>.
# has_memory must be the literal string "true" or "false".
write_meta() {
  local tag=$1 parent=$2 source_vm=$3 has_memory=${4:-false}
  local dir
  dir=$(snapshot_path "$tag")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{\n' > "$dir/meta.json.tmp"
  printf '  "tag": "%s",\n'         "$tag"                   >> "$dir/meta.json.tmp"
  printf '  "parent": "%s",\n'      "$parent"                >> "$dir/meta.json.tmp"
  printf '  "arch": "%s",\n'        "$ARCH"                  >> "$dir/meta.json.tmp"
  printf '  "base_image": "%s",\n'  "$LATEST_ALPINE_BASE"    >> "$dir/meta.json.tmp"
  printf '  "created": "%s",\n'     "$now"                   >> "$dir/meta.json.tmp"
  printf '  "last_used": "%s",\n'   "$now"                   >> "$dir/meta.json.tmp"
  printf '  "source_vm": "%s",\n'   "$source_vm"             >> "$dir/meta.json.tmp"
  printf '  "has_memory": %s\n'     "$has_memory"            >> "$dir/meta.json.tmp"
  printf '}\n'                                               >> "$dir/meta.json.tmp"
  mv "$dir/meta.json.tmp" "$dir/meta.json"
}
```

- [ ] **Step 3: Run smoke + Phase 2A snapshot tests**

Run: `bash tests/run.sh`
Expected: both `[smoke] PASSED` and `[snap] PASSED`. Phase 2A flow still works because we pass `has_memory=false` in the cold branch.

- [ ] **Step 4: Manual live-snapshot probe**

```bash
VM=live-probe-$$
./aq new "$VM"
./aq start "$VM"
./aq exec "$VM" 'echo "tmpfs marker $(date +%s)" > /dev/shm/marker'
./aq snapshot create "$VM" live-test-$$
ls -la ~/.local/share/aq/snapshots/*/live-test-*/
cat ~/.local/share/aq/snapshots/*/live-test-*/meta.json
./aq rm "$VM"
./aq snapshot rm --force "$(ls ~/.local/share/aq/snapshots/*/ | grep '^live-test-')"
```

Expected: snapshot dir contains `disk.qcow2`, `meta.json` (with `has_memory: true`), and `memory.bin` (typically 50-300 MB).

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Implement live snapshot capture (running VM via QMP migrate)"
```

---

## Task 3: Restore plumbing in `aq_new --from-snapshot`

Hard-link `memory.bin` into the new VM dir as `incoming-memory.bin`, so the next `aq start` knows to use `-incoming`.

**Files:**
- Modify: `aq` (`aq_new`)

- [ ] **Step 1: Extend the snapshot-derived branch of aq_new**

Find the trailing block in `aq_new` that handles `--from-snapshot`:

Old:
```bash
  if [ -n "$from_snapshot" ]; then
    local resolved
    resolved=$(resolve_tag "$from_snapshot")
    # Marker tells aq_rm and get_refcount which snapshot this VM derives from.
    echo "$resolved" > "$BASE_DIR/$VM_NAME/.from_snapshot"
  fi
```

New:
```bash
  if [ -n "$from_snapshot" ]; then
    local resolved
    resolved=$(resolve_tag "$from_snapshot")
    # Marker tells aq_rm and get_refcount which snapshot this VM derives from.
    echo "$resolved" > "$BASE_DIR/$VM_NAME/.from_snapshot"

    # If the snapshot has memory state, stage it for the next aq_start.
    # Hard link first (instant, no copy); fall back to cp on EXDEV (cross-fs).
    local has_memory
    has_memory=$(read_meta "$resolved" has_memory 2>/dev/null || echo false)
    if [ "$has_memory" = "true" ]; then
      local src="$(snapshot_path "$resolved")/memory.bin"
      local dst="$BASE_DIR/$VM_NAME/incoming-memory.bin"
      ln "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
    fi
  fi
```

- [ ] **Step 2: Smoke + snapshot tests**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`, `[snap] PASSED`. Cold path unchanged.

- [ ] **Step 3: Commit**

```bash
git add aq
git commit -m "Stage incoming-memory.bin on aq new --from-snapshot for live restore"
```

---

## Task 4: `-incoming` in `aq_start`

When `incoming-memory.bin` is present in the VM dir, qemu starts in incoming-migration mode. After it's running, the file is removed (one-shot).

**Files:**
- Modify: `aq` (`aq_start`)

- [ ] **Step 1: Add -incoming and post-start cleanup**

Find `aq_start`. Just before the `$QEMU_BIN \` line, add a block that sets `incoming_arg`. After the qemu daemonize line, add cleanup.

Old (snippet):
```bash
  HOST_FORWARDS="$(hostfwd $VM_NAME)"

  $QEMU_BIN \
    -machine $MACHINE_OPTS -accel $ACCEL -cpu host -m 1G \
    -drive file=$UEFI_CODE,format=raw,if=pflash,readonly=on,unit=0 \
    $(uefi_vars_args $BASE_DIR/$VM_NAME) \
    -drive if=virtio,file=$BASE_DIR/$VM_NAME/storage.qcow2 \
    -boot order=d \
    -nic user,model=virtio-net-pci,$HOST_FORWARDS \
    -rtc base=utc,clock=host \
    -serial unix:$BASE_DIR/$VM_NAME/command.sock,server=on,wait=off,nodelay=on \
    -mon chardev=mon0,mode=readline -chardev socket,id=mon0,path=$BASE_DIR/$VM_NAME/control.sock,server=on,wait=off \
    -qmp unix:$BASE_DIR/$VM_NAME/qmp.sock,server=on,wait=off \
    -daemonize -pidfile $BASE_DIR/$VM_NAME/process.pid \
    -name $VM_NAME \
    -display none \
    -parallel none \
    -monitor none
```

New:
```bash
  HOST_FORWARDS="$(hostfwd $VM_NAME)"

  local incoming_arg=""
  local incoming_file="$BASE_DIR/$VM_NAME/incoming-memory.bin"
  if [ -f "$incoming_file" ]; then
    incoming_arg="-incoming exec:cat '$incoming_file'"
  fi

  # Use eval so the quoted exec: argument is parsed as one token.
  eval $QEMU_BIN \
    -machine $MACHINE_OPTS -accel $ACCEL -cpu host -m 1G \
    -drive file=$UEFI_CODE,format=raw,if=pflash,readonly=on,unit=0 \
    $(uefi_vars_args $BASE_DIR/$VM_NAME) \
    -drive if=virtio,file=$BASE_DIR/$VM_NAME/storage.qcow2 \
    -boot order=d \
    -nic user,model=virtio-net-pci,$HOST_FORWARDS \
    -rtc base=utc,clock=host \
    -serial unix:$BASE_DIR/$VM_NAME/command.sock,server=on,wait=off,nodelay=on \
    -mon chardev=mon0,mode=readline -chardev socket,id=mon0,path=$BASE_DIR/$VM_NAME/control.sock,server=on,wait=off \
    -qmp unix:$BASE_DIR/$VM_NAME/qmp.sock,server=on,wait=off \
    -daemonize -pidfile $BASE_DIR/$VM_NAME/process.pid \
    -name $VM_NAME \
    -display none \
    -parallel none \
    -monitor none \
    $incoming_arg

  # Incoming migration is one-shot — qemu consumes it and the file becomes
  # meaningless after this start. Remove it so subsequent `aq start` boots
  # cold from the qcow2 (which now reflects the migrated state).
  if [ -n "$incoming_arg" ]; then
    rm -f "$incoming_file"
  fi
```

- [ ] **Step 2: Smoke + snapshot tests**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`, `[snap] PASSED`. Cold path: `incoming_arg` empty, behaviour unchanged.

- [ ] **Step 3: Manual live restore probe**

```bash
SRC=live-src-$$
./aq new "$SRC"
./aq start "$SRC"
./aq exec "$SRC" 'echo "tmpfs marker" > /dev/shm/marker'
./aq snapshot create "$SRC" live-test-tag
./aq stop "$SRC"
./aq rm "$SRC"

DST=live-dst-$$
./aq new --from-snapshot=live-test-tag "$DST"
./aq start "$DST"
./aq exec "$DST" 'cat /dev/shm/marker'
./aq rm "$DST"
./aq snapshot rm live-test-tag
```

Expected: `cat /dev/shm/marker` outputs `tmpfs marker`. tmpfs lives in RAM only — its contents survive **only** if memory was restored. If you see `cat: can't open ...: No such file or directory`, restore didn't work.

Also expect: `aq start "$DST"` is noticeably faster than the cold `aq start "$SRC"` (the hint message "First boot detected" should NOT appear, and SSH should be reachable in 1-3 seconds vs 10-12 seconds).

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Restore live snapshots via qemu -incoming"
```

---

## Task 5: e2e live snapshot test

**Files:**
- Create: `tests/live-snapshots.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Create tests/live-snapshots.sh**

```bash
#!/usr/bin/env bash
# E2E test for live (memory-preserving) snapshots:
# - provision a VM
# - leave a marker in tmpfs (/dev/shm) — survives only if memory is restored
# - snapshot the running VM
# - derive a new VM, start it, verify the tmpfs marker is there

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
SRC_VM="aq-live-src-$$"
DST_VM="aq-live-dst-$$"
TAG="aq-live-test-$$"

cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" 2>/dev/null
  "$AQ" rm   "$SRC_VM" 2>/dev/null
  "$AQ" stop "$DST_VM" 2>/dev/null
  "$AQ" rm   "$DST_VM" 2>/dev/null
  "$AQ" snapshot rm --force "$TAG" 2>/dev/null
}
trap cleanup EXIT

echo "[live] aq new $SRC_VM"
"$AQ" new "$SRC_VM"
"$AQ" start "$SRC_VM"

echo "[live] write tmpfs marker"
"$AQ" exec "$SRC_VM" 'echo "live-marker-'"$$"'" > /dev/shm/marker'

echo "[live] aq snapshot create on RUNNING $SRC_VM"
"$AQ" snapshot create "$SRC_VM" "$TAG"

echo "[live] verify meta.json reports has_memory: true"
meta=~/.local/share/aq/snapshots/$(uname -m | sed 's/^arm64$/aarch64/')/$TAG/meta.json
if ! grep -q '"has_memory": true' "$meta"; then
  echo "[live] FAIL: has_memory not true in $meta"
  cat "$meta"
  exit 1
fi

echo "[live] verify memory.bin exists"
if [ ! -s "$(dirname "$meta")/memory.bin" ]; then
  echo "[live] FAIL: memory.bin missing or empty"
  ls -la "$(dirname "$meta")"
  exit 1
fi

echo "[live] aq stop + rm $SRC_VM"
"$AQ" stop "$SRC_VM"
"$AQ" rm "$SRC_VM"

echo "[live] aq new --from-snapshot=$TAG $DST_VM"
"$AQ" new --from-snapshot="$TAG" "$DST_VM"

echo "[live] verify incoming-memory.bin staged"
if [ ! -s ~/.local/share/aq/$DST_VM/incoming-memory.bin ]; then
  echo "[live] FAIL: incoming-memory.bin missing in $DST_VM dir"
  ls -la ~/.local/share/aq/$DST_VM/
  exit 1
fi

echo "[live] aq start (should be fast, no first_boot_setup)"
"$AQ" start "$DST_VM"

echo "[live] verify tmpfs marker survived"
out=$("$AQ" exec "$DST_VM" 'cat /dev/shm/marker')
if [ "$out" != "live-marker-$$" ]; then
  echo "[live] FAIL: expected 'live-marker-$$', got '$out'"
  exit 1
fi

echo "[live] verify incoming-memory.bin was consumed (removed) by aq start"
if [ -f ~/.local/share/aq/$DST_VM/incoming-memory.bin ]; then
  echo "[live] FAIL: incoming-memory.bin still present after start"
  exit 1
fi

echo "[live] PASSED"
```

- [ ] **Step 2: Make executable, add to runner**

```bash
chmod +x tests/live-snapshots.sh
```

Edit `tests/run.sh`:

Old:
```bash
#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
bash tests/smoke.sh
bash tests/snapshots.sh
```

New:
```bash
#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
bash tests/smoke.sh
bash tests/snapshots.sh
bash tests/live-snapshots.sh
```

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`, `[snap] PASSED`, `[live] PASSED`. Total wall-clock on macOS: ~2 minutes.

- [ ] **Step 4: Commit**

```bash
git add tests/live-snapshots.sh tests/run.sh
git commit -m "Add e2e test for live (memory-preserving) snapshots"
```

---

## Task 6: README, CHANGELOG, version bump

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `aq` (VERSION)

- [ ] **Step 1: Extend the Snapshots section in README.md**

Find the existing "Snapshots" section (added in Phase 2A). Add a paragraph at the end:

```markdown
**Live snapshots** — when you snapshot a *running* VM (instead of stopping it
first), aq also captures the live memory state. Restoring such a snapshot
skips Alpine's boot entirely: the kernel, processes, network connections,
and tmpfs contents come back as they were at the snapshot moment.

    aq new myrails
    aq start myrails
    # provision, run a server, do work...
    aq snapshot create myrails myrails-running   # VM stays running
    aq new --from-snapshot=myrails-running fresh-shard
    aq start fresh-shard                          # SSH ready in ~2s, not 12s
```

- [ ] **Step 2: Add a 2.2.0 entry to CHANGELOG.md**

Replace the `## Unreleased` line:

```markdown
## Unreleased

## 2.2.0 "Resume" 2026-05-XX

### New Features

- `aq snapshot create` on a *running* VM now also captures live memory state
  via QMP `migrate`. The VM is paused for a few seconds during capture, then
  resumes. `meta.json` records `has_memory: true` and `memory.bin` lives next
  to `disk.qcow2` in the snapshot dir.
- `aq new --from-snapshot=<tag>` of a memory-bearing snapshot stages the
  memory file in the new VM dir as `incoming-memory.bin` (hard-linked, no
  copy on the same filesystem).
- `aq start` of a VM with `incoming-memory.bin` launches qemu with
  `-incoming "exec:cat ..."` and resumes at the snapshot point. SSH is
  reachable in ~1-3 s vs ~10-12 s for a cold boot. The incoming file is
  consumed and removed by qemu; subsequent `aq start` boots cold from the
  now-up-to-date `storage.qcow2`.

### Internal

- Every running VM now exposes a QMP socket at `<vm-dir>/qmp.sock` alongside
  the existing readline HMP `control.sock`. New `qmp_hmp` helper sends an
  HMP command via the QMP wrapper for synchronous control.

### Limitations / Notes

- After live restore, the guest clock has rewound to the snapshot moment.
  Programs sensitive to wall-clock time may misbehave until NTP catches up.
- Memory.bin can be large (50-300 MB on a freshly-booted Alpine; up to the
  full RAM size on a heavily-used VM). Storage planning is the operator's
  responsibility for now.
- `migrate` over `exec:` URI is not encrypted — fine for local-only aq use,
  but don't aim it at a network destination.
```

- [ ] **Step 3: Bump VERSION**

```bash
sed -i.bak 's/^VERSION=2\.1\.1/VERSION=2.2.0/' aq && rm aq.bak
grep '^VERSION=' aq
```

Expected: `VERSION=2.2.0`.

- [ ] **Step 4: Final test pass**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`, `[snap] PASSED`, `[live] PASSED`.

- [ ] **Step 5: Commit**

```bash
git add aq README.md CHANGELOG.md
git commit -m "Release 2.2.0 \"Resume\" — live memory snapshots"
```

---

## Task 7: Push, CI, merge, tag, release

**Files:** none (operational).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin phase-2b-live-snapshots
```

- [ ] **Step 2: Wait for CI**

Run: `gh run list --branch phase-2b-live-snapshots --limit 1`
Wait until the most recent run is `success`. The new live-snapshots test exercises QMP, migrate, -incoming on Linux x86_64.

If CI fails, expected categories of issues:
- **QMP socket timing**: socat `-t300` insufficient on slow CI. Bump to `-t600`.
- **migrate exec quoting**: shell quoting inside the QMP JSON via `human-monitor-command` may need escaping different across qemu versions. Inspect via `gh api repos/pirj/aq/actions/jobs/<id>/logs`.
- **memory.bin size on tmpfs**: CI runners have limited tmpfs; if memory.bin is ~200 MB on x86_64, consider checking disk space rather than tmpfs.
- **`-incoming` on x86_64 + KVM**: should work identically to aarch64+HVF; no known difference.

Iterate by editing, committing, pushing.

- [ ] **Step 3: Merge to main**

After CI is green:

```bash
git checkout main
git pull --ff-only
git merge --ff-only phase-2b-live-snapshots
git push origin main
git branch -d phase-2b-live-snapshots
git push origin --delete phase-2b-live-snapshots
```

- [ ] **Step 4: Tag and release**

```bash
git tag -a v2.2.0 -m 'aq 2.2.0 "Resume" — live memory snapshots'
git push origin v2.2.0
gh release create v2.2.0 --title 'aq 2.2.0 "Resume"' \
  --notes "Live memory snapshots: aq snapshot create on a running VM now captures memory state. aq start of a derived VM uses qemu -incoming to resume at the snapshot point in seconds, skipping Alpine boot. See CHANGELOG.md."
```

---

## Self-Review Checklist

- **Spec coverage:**
  - Live snapshot create (running VM) → Task 2 ✓
  - Memory.bin in snapshot dir → Task 2 ✓
  - has_memory in meta.json → Task 2 ✓
  - aq new --from-snapshot stages memory for live restore → Task 3 ✓
  - aq start uses -incoming → Task 4 ✓
  - <500ms / <1s restore target → measured indirectly via the e2e test (no first_boot_setup, fast SSH). Hard timing assertions deferred — Phase 2A's <500 ms is aspirational, depends on memory size.
  - **Phase 3 (fan-out, --count, aq fanout)** → out of scope, deferred. ✓
- **Placeholder scan:** none — every step contains the actual code or command.
- **Type / name consistency:**
  - `qmp_hmp` is referenced in Tasks 1, 2 (and only there).
  - `incoming-memory.bin` filename is identical in Tasks 3, 4, 5.
  - `memory.bin` filename is identical in Tasks 2, 3, 5.
  - `has_memory` field name and the literal `true`/`false` values are consistent across `write_meta`, `read_meta` (in 2.1.1), Task 2, 3, 5.
  - `qmp.sock` path is identical in Task 1 (qemu invocation) and Tasks 2, 4 (callers).

## Out of Scope (Phase 3 and beyond)

- **Fan-out** (`aq new --count=N --from-snapshot`, `aq fanout <tag> <N> -- <cmd>`). Phase 3.
- **Shared memory mmap** for fan-out (deduplicate memory pages across N restored VMs via KSM/copy-on-write). Phase 3.
- **OCI artifact push/pull** for snapshots. Phase 5.
- **Live snapshot of a paused VM that was never running on this version of aq** — requires migration over QMP, but VM doesn't have qmp.sock. Document the upgrade path: stop the VM, restart it under the new aq, then snapshot.
- **Auto NTP after restore** to fix clock skew. Phase 5 if it surfaces in feedback.
