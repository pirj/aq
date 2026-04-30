# Phase 1 — Linux Host Support: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `aq` run on Linux x86_64 with KVM acceleration, with the same CLI as on macOS, while preserving all existing macOS behavior.

**Architecture:** Single `aq` script with runtime host detection. A new `detect_host()` function sets ~7 variables (`HOST_OS`, `ARCH`, `ACCEL`, `QEMU_BIN`, `MACHINE_OPTS`, `UEFI_CODE`, `UEFI_VARS_FLAVOR`); existing call sites use these variables instead of hard-coded macOS values. Per-arch subdirectories for base image, ISO, and UEFI vars (`$BASE_DIR/$ARCH/...`). VM directories remain flat (`$BASE_DIR/<vm-name>`) since they reference the per-arch base. Linux uses split OVMF pflash; macOS retains its current `uefi-vars-sysbus` JSON path.

**Tech Stack:** bash, qemu (qemu-system-aarch64 on macOS via HVF, qemu-system-x86_64 on Linux via KVM), Alpine Linux 3.22.2 (per-arch ISOs), OVMF/edk2 firmware, GitHub Actions for CI.

**Reference:** docs/specs/2026-04-30-aq-ci-snapshots-design.md (Layer 1).

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `aq` | Modify | Add `detect_host()` (top of script). Replace hard-coded macOS values throughout `bootstrap_base_image`, `aq_new`, `aq_start`. Change `BASE_DIR` references to arch-aware paths. Add KVM availability check. |
| `tests/smoke.sh` | Create | E2E smoke test: `new` → `start` → `exec` → `stop` → `rm`. Asserts output. Used as the reference test for every change. |
| `tests/run.sh` | Create | Test runner (just `bash tests/smoke.sh` for v1, but a stable entry point for future tests). |
| `.github/workflows/ci-linux.yml` | Create | Runs smoke test on `ubuntu-latest`. Installs qemu/tio/socat/ovmf. Validates Linux support. |
| `.github/workflows/ci-macos.yml` | Create | Runs smoke test on `macos-latest` (or `macos-14` for arm). Validates macOS not broken. |
| `README.md` | Modify | Dependency matrix (brew vs apt). Linux quickstart. KVM permissions note. |
| `CHANGELOG.md` | Modify | 2.0 entry: Linux host support. |
| `aq` (VERSION) | Modify | `VERSION=2.0.0` |

The `aq` script stays a single file. Splitting into modules is out of scope for Phase 1.

---

## Task 0: Smoke test foundation

Establish the test we will use to validate every subsequent change. Must pass on macOS *before* any host-detection refactor.

**Files:**
- Create: `tests/smoke.sh`
- Create: `tests/run.sh`

- [ ] **Step 1: Create `tests/smoke.sh`**

```bash
#!/usr/bin/env bash
# Smoke test for aq: full lifecycle.
# Exits non-zero on any failure. Cleans up VM on exit.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM_NAME="aq-smoke-$$"

cleanup() {
  set +e
  "$AQ" stop "$VM_NAME" 2>/dev/null
  "$AQ" rm "$VM_NAME" 2>/dev/null
}
trap cleanup EXIT

echo "[smoke] aq new"
"$AQ" new "$VM_NAME"

echo "[smoke] aq start"
"$AQ" start "$VM_NAME"

echo "[smoke] aq exec (arg form)"
output=$("$AQ" exec "$VM_NAME" echo hello)
if [ "$output" != "hello" ]; then
  echo "[smoke] FAIL: arg-form expected 'hello', got '$output'"
  exit 1
fi

echo "[smoke] aq exec (stdin form)"
output=$(echo 'echo from-stdin' | "$AQ" exec "$VM_NAME")
if [ "$output" != "from-stdin" ]; then
  echo "[smoke] FAIL: stdin-form expected 'from-stdin', got '$output'"
  exit 1
fi

echo "[smoke] aq stop"
"$AQ" stop "$VM_NAME"

echo "[smoke] aq rm"
"$AQ" rm "$VM_NAME"

echo "[smoke] PASSED"
```

- [ ] **Step 2: Create `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Test entry point. Add new test scripts as we grow the suite.
set -eu
cd "$(dirname "$0")/.."
bash tests/smoke.sh
```

- [ ] **Step 3: Make tests executable**

Run: `chmod +x tests/smoke.sh tests/run.sh`

- [ ] **Step 4: Run on macOS to verify baseline**

Run: `bash tests/run.sh`
Expected: ends with `[smoke] PASSED`. Wall-clock time: ~30-60s on first run (downloads ISO, bootstraps base), ~15-25s on subsequent runs.

If this fails on a clean macOS, fix the failure before continuing; we need a green baseline.

- [ ] **Step 5: Commit**

```bash
git add tests/smoke.sh tests/run.sh
git commit -m "Add e2e smoke test for aq lifecycle"
```

---

## Task 1: Add `detect_host()` function

Introduce host-detection logic without changing any actual behavior yet. Variables get set, but existing code still uses hard-coded values. This is a pure refactor preparing the ground.

**Files:**
- Modify: `aq` (insert function around line 41, just before `VERSION=...`; add invocation right after VERSION block, around line 50)

- [ ] **Step 1: Add `detect_host()` function**

Insert this function in `aq`, immediately after the `random_vm_name` function (around line 40, before `VERSION=1.6.0`):

```bash
detect_host() {
  case "$(uname -s)" in
    Darwin)
      HOST_OS=darwin
      ARCH=aarch64
      ACCEL=hvf
      QEMU_BIN=qemu-system-aarch64
      MACHINE_OPTS="virt,highmem=on"
      UEFI_CODE="$(brew --prefix qemu 2>/dev/null)/share/qemu/edk2-aarch64-code.fd"
      UEFI_VARS_FLAVOR=sysbus_json   # uefi-vars-sysbus device with .json file
      ;;
    Linux)
      HOST_OS=linux
      ARCH=x86_64
      ACCEL=kvm
      QEMU_BIN=qemu-system-x86_64
      MACHINE_OPTS="q35"
      UEFI_CODE="/usr/share/OVMF/OVMF_CODE.fd"
      UEFI_VARS_FLAVOR=pflash_fd     # second pflash drive with .fd file
      ;;
    *)
      stderr "Error: unsupported host OS: $(uname -s). aq supports macOS (Darwin) and Linux."
      exit 1
      ;;
  esac
}
```

- [ ] **Step 2: Invoke `detect_host` once at startup**

Add this line right after `VERSION=1.6.0` (around line 41):

```bash
detect_host
```

- [ ] **Step 3: Run smoke test**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. No regression because variables are set but not yet consumed.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Add detect_host() for runtime OS detection"
```

---

## Task 2: Add per-arch subdirectories for base assets

Move base image, ISO, and UEFI vars under `$BASE_DIR/$ARCH/`. VM directories remain at `$BASE_DIR/<vm-name>` (they're inherently arch-tied via their backing). This is the storage-layout change; behavior should be identical.

**Files:**
- Modify: `aq` (constants around lines 43-48; references throughout `bootstrap_base_image` and `aq_new` / `aq_start`)

- [ ] **Step 1: Add migration helper**

Add this function in `aq`, after `detect_host()`:

```bash
migrate_base_dir_to_arch() {
  # One-time migration: ~/.local/share/aq/{alpine-base*.raw,alpine-virt*.iso,uefi-vars.json}
  # → ~/.local/share/aq/<arch>/...
  local arch_dir="$BASE_DIR/$ARCH"
  [ -d "$arch_dir" ] && return 0
  [ ! -d "$BASE_DIR" ] && return 0

  local found=0
  for f in "$BASE_DIR"/alpine-base-*.raw "$BASE_DIR"/alpine-virt-*.iso* "$BASE_DIR"/uefi-vars.json; do
    [ -e "$f" ] && found=1 && break
  done
  [ "$found" = 0 ] && return 0

  mkdir -p "$arch_dir"
  for pattern in 'alpine-base-*.raw' 'alpine-virt-*.iso' 'alpine-virt-*.iso.asc' 'uefi-vars.json'; do
    for f in "$BASE_DIR"/$pattern; do
      [ -e "$f" ] && mv "$f" "$arch_dir/"
    done
  done
  stderr "aq: migrated base assets to $arch_dir"
}
```

- [ ] **Step 2: Invoke migration after `detect_host`**

In `aq`, just after `detect_host` invocation, add (note `BASE_DIR` is set just below — we move the migration *after* `BASE_DIR=...`):

Adjust ordering. The final layout after this task:

```bash
detect_host

VERSION=1.6.0

BASE_DIR=~/.local/share/aq
LATEST_ALPINE_VERSION=3.22.2
LATEST_ALPINE_MAJOR_MINOR=3.22
LATEST_ALPINE_ISO=alpine-virt-$LATEST_ALPINE_VERSION-$ARCH.iso
LATEST_ALPINE_BASE=alpine-base-$LATEST_ALPINE_VERSION-$ARCH.raw

migrate_base_dir_to_arch
```

Note the change: `LATEST_ALPINE_ISO` and `LATEST_ALPINE_BASE` now use `$ARCH` instead of hard-coded `aarch64`. On macOS this still resolves to the same filename. On Linux it becomes `x86_64`.

- [ ] **Step 3: Replace `$BASE_DIR/$LATEST_ALPINE_*` references with arch-aware paths**

There are several call sites in `aq` that reference the base image, ISO, or uefi-vars. Replace each as follows:

In `download_alpine_iso` (around lines 50-65):

Old:
```bash
cd $BASE_DIR
if [ ! -f $LATEST_ALPINE_ISO ]; then
  wget https://dl-cdn.alpinelinux.org/alpine/v$LATEST_ALPINE_MAJOR_MINOR/releases/aarch64/$LATEST_ALPINE_ISO
  wget https://dl-cdn.alpinelinux.org/alpine/v$LATEST_ALPINE_MAJOR_MINOR/releases/aarch64/$LATEST_ALPINE_ISO.asc
```

New:
```bash
mkdir -p $BASE_DIR/$ARCH
cd $BASE_DIR/$ARCH
if [ ! -f $LATEST_ALPINE_ISO ]; then
  wget https://dl-cdn.alpinelinux.org/alpine/v$LATEST_ALPINE_MAJOR_MINOR/releases/$ARCH/$LATEST_ALPINE_ISO
  wget https://dl-cdn.alpinelinux.org/alpine/v$LATEST_ALPINE_MAJOR_MINOR/releases/$ARCH/$LATEST_ALPINE_ISO.asc
```

In `ensure_base_image` (line 84):

Old:
```bash
[ -f $BASE_DIR/$LATEST_ALPINE_BASE ] || bootstrap_base_image
```

New:
```bash
[ -f $BASE_DIR/$ARCH/$LATEST_ALPINE_BASE ] || bootstrap_base_image
```

In `bootstrap_base_image` (line 90, the `cd`):

Old:
```bash
cd $BASE_DIR
```

New:
```bash
mkdir -p $BASE_DIR/$ARCH
cd $BASE_DIR/$ARCH
```

In `bootstrap_base_image` qemu invocation (lines 100-112), change the `-device uefi-vars-sysbus,jsonfile=...`:

Old:
```bash
-device uefi-vars-sysbus,jsonfile=$BASE_DIR/uefi-vars.json \
```

New:
```bash
-device uefi-vars-sysbus,jsonfile=$BASE_DIR/$ARCH/uefi-vars.json \
```

(Other refs to `$LATEST_ALPINE_BASE` / `$LATEST_ALPINE_ISO` inside `bootstrap_base_image` are *relative* — `cd` already moved us, so `wip-$LATEST_ALPINE_BASE` resolves correctly.)

In `bootstrap_base_image` finalisation (around line 196):

Old:
```bash
mv $BASE_DIR/{wip-,}$LATEST_ALPINE_BASE
chmod -w $BASE_DIR/$LATEST_ALPINE_BASE
```

New:
```bash
mv $BASE_DIR/$ARCH/{wip-,}$LATEST_ALPINE_BASE
chmod -w $BASE_DIR/$ARCH/$LATEST_ALPINE_BASE
```

In `aq_new` (around line 230):

Old:
```bash
qemu-img create -b $BASE_DIR/$LATEST_ALPINE_BASE -F raw -f qcow2 storage.qcow2 2G 1>/dev/null

cp ../uefi-vars.json .
```

New:
```bash
qemu-img create -b $BASE_DIR/$ARCH/$LATEST_ALPINE_BASE -F raw -f qcow2 storage.qcow2 2G 1>/dev/null

cp $BASE_DIR/$ARCH/uefi-vars.json .
```

In `aq_start` (line 357), the qemu-system-aarch64 line still uses `$BASE_DIR/$VM_NAME/uefi-vars.json` — this is correct (per-VM copy). No change here.

But the `-drive file=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd,...` line on line 357 references the macOS-specific firmware. Leave it for now — Task 4 will replace it.

- [ ] **Step 4: Run smoke test**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. Migration runs once; subsequent runs skip migration.

If you have an existing `~/.local/share/aq/alpine-base-3.22.2-aarch64.raw`, the migration moves it to `~/.local/share/aq/aarch64/`. If something gets confused, blow away `~/.local/share/aq/` and let it rebootstrap.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Move base image, ISO, and UEFI vars under per-arch subdirectory"
```

---

## Task 3: Parameterise qemu binary, machine, and accel in `aq_start`

Replace hard-coded `qemu-system-aarch64`, `virt,highmem=on`, `hvf` in `aq_start` with the `detect_host` variables.

**Files:**
- Modify: `aq` (around lines 355-369)

- [ ] **Step 1: Update `aq_start` qemu invocation**

In `aq` `aq_start`, find the qemu invocation at line 355:

Old:
```bash
qemu-system-aarch64 \
  -machine virt,highmem=on -accel hvf -cpu host -m 1G \
  -drive file=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd,format=raw,if=pflash,readonly=on,unit=0 \
  -device uefi-vars-sysbus,jsonfile=$BASE_DIR/$VM_NAME/uefi-vars.json \
  -drive if=virtio,file=$BASE_DIR/$VM_NAME/storage.qcow2 \
  -boot order=d \
```

New:
```bash
$QEMU_BIN \
  -machine $MACHINE_OPTS -accel $ACCEL -cpu host -m 1G \
  -drive file=$UEFI_CODE,format=raw,if=pflash,readonly=on,unit=0 \
  $(uefi_vars_args $BASE_DIR/$VM_NAME) \
  -drive if=virtio,file=$BASE_DIR/$VM_NAME/storage.qcow2 \
  -boot order=d \
```

- [ ] **Step 2: Add `uefi_vars_args` helper**

Add this function in `aq`, after `detect_host`:

```bash
# Emit qemu CLI fragment for UEFI variable storage, depending on host firmware flavor.
# Arg: directory containing the per-VM (or shared base) UEFI vars file.
uefi_vars_args() {
  local dir=$1
  case "$UEFI_VARS_FLAVOR" in
    sysbus_json)
      echo "-device uefi-vars-sysbus,jsonfile=$dir/uefi-vars.json"
      ;;
    pflash_fd)
      echo "-drive file=$dir/uefi-vars.fd,format=raw,if=pflash,unit=1"
      ;;
    *)
      stderr "Error: unknown UEFI_VARS_FLAVOR: $UEFI_VARS_FLAVOR"
      exit 1
      ;;
  esac
}
```

- [ ] **Step 3: Run smoke test on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. macOS uses `sysbus_json` branch; behavior is identical to before.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Parameterise qemu binary, machine, accel, and UEFI in aq_start"
```

---

## Task 4: Parameterise the same in `bootstrap_base_image`

Same treatment for the bootstrap path so Linux can build its base image.

**Files:**
- Modify: `aq` `bootstrap_base_image` (lines 98-112)

- [ ] **Step 1: Replace qemu invocation**

In `bootstrap_base_image`, find:

Old:
```bash
qemu-system-aarch64 \
  -machine virt,highmem=on -accel hvf -cpu host -m 1G \
  -drive file=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd,format=raw,if=pflash,readonly=on,unit=0 \
  -device uefi-vars-sysbus,jsonfile=$BASE_DIR/$ARCH/uefi-vars.json \
  -drive if=virtio,file=$BASE_DIR/$ARCH/wip-$LATEST_ALPINE_BASE,format=raw,cache=none \
```

New:
```bash
$QEMU_BIN \
  -machine $MACHINE_OPTS -accel $ACCEL -cpu host -m 1G \
  -drive file=$UEFI_CODE,format=raw,if=pflash,readonly=on,unit=0 \
  $(uefi_vars_args $BASE_DIR/$ARCH) \
  -drive if=virtio,file=$BASE_DIR/$ARCH/wip-$LATEST_ALPINE_BASE,format=raw,cache=none \
```

- [ ] **Step 2: Initialise UEFI vars file before bootstrap (Linux only)**

For `pflash_fd` flavor, qemu requires the vars file to exist (it's a writable pflash). For `sysbus_json`, qemu creates the JSON on first run.

Add a helper near `uefi_vars_args`:

```bash
# Ensure UEFI vars storage exists for the given dir.
ensure_uefi_vars() {
  local dir=$1
  case "$UEFI_VARS_FLAVOR" in
    sysbus_json)
      :  # qemu creates the JSON automatically
      ;;
    pflash_fd)
      if [ ! -f "$dir/uefi-vars.fd" ]; then
        local src=/usr/share/OVMF/OVMF_VARS.fd
        [ -f "$src" ] || { stderr "Error: $src not found. Install package 'ovmf'."; exit 1; }
        cp "$src" "$dir/uefi-vars.fd"
        chmod +w "$dir/uefi-vars.fd"
      fi
      ;;
  esac
}
```

In `bootstrap_base_image`, just before the qemu invocation, add:

```bash
ensure_uefi_vars $BASE_DIR/$ARCH
```

In `aq_new` (around line 232 in current code, just before `cp ../uefi-vars.json .` — which we replaced in Task 2 with `cp $BASE_DIR/$ARCH/uefi-vars.json .`), replace the cp logic:

Old (post-Task-2):
```bash
cp $BASE_DIR/$ARCH/uefi-vars.json .
chmod +w uefi-vars.json
```

New:
```bash
case "$UEFI_VARS_FLAVOR" in
  sysbus_json)
    cp $BASE_DIR/$ARCH/uefi-vars.json .
    chmod +w uefi-vars.json
    ;;
  pflash_fd)
    cp $BASE_DIR/$ARCH/uefi-vars.fd .
    chmod +w uefi-vars.fd
    ;;
esac
```

- [ ] **Step 3: Update finalisation `chmod -w` in `bootstrap_base_image`**

Old (line 195):
```bash
chmod -w uefi-vars.json
```

New:
```bash
case "$UEFI_VARS_FLAVOR" in
  sysbus_json) chmod -w uefi-vars.json ;;
  pflash_fd)   chmod -w uefi-vars.fd ;;
esac
```

- [ ] **Step 4: Run smoke test on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. macOS still uses JSON path; bootstrap reuses the existing per-arch base if already built.

If you want to fully exercise the bootstrap path on macOS, blow away the base image: `rm ~/.local/share/aq/aarch64/alpine-base-*.raw` and re-run.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Parameterise qemu and UEFI vars handling for cross-arch base bootstrap"
```

---

## Task 5: KVM availability check

On Linux, fail fast with a clear message if `/dev/kvm` is unreadable. Helps users diagnose missing groups or unsupported runners.

**Files:**
- Modify: `aq` (`detect_host` function from Task 1)

- [ ] **Step 1: Extend `detect_host` with a KVM check on Linux**

Replace the Linux branch of `detect_host`:

Old:
```bash
Linux)
  HOST_OS=linux
  ARCH=x86_64
  ACCEL=kvm
  QEMU_BIN=qemu-system-x86_64
  MACHINE_OPTS="q35"
  UEFI_CODE="/usr/share/OVMF/OVMF_CODE.fd"
  UEFI_VARS_FLAVOR=pflash_fd
  ;;
```

New:
```bash
Linux)
  HOST_OS=linux
  ARCH=x86_64
  QEMU_BIN=qemu-system-x86_64
  MACHINE_OPTS="q35"
  UEFI_CODE="/usr/share/OVMF/OVMF_CODE.fd"
  UEFI_VARS_FLAVOR=pflash_fd
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL=kvm
  else
    if [ -e /dev/kvm ]; then
      stderr "Error: /dev/kvm exists but is not accessible."
      stderr "Hint: add your user to the 'kvm' group, then log out and back in:"
      stderr "  sudo usermod -aG kvm \$USER"
      exit 1
    else
      stderr "Error: /dev/kvm not found. KVM is required for aq on Linux."
      stderr "Hint: ensure your host supports virtualization (Intel VT-x / AMD-V),"
      stderr "      and that the kvm kernel modules are loaded:"
      stderr "  lsmod | grep kvm"
      exit 1
    fi
  fi
  ;;
```

- [ ] **Step 2: Run smoke test on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. KVM branch is not hit on macOS.

- [ ] **Step 3: Commit**

```bash
git add aq
git commit -m "Fail fast when /dev/kvm is missing or inaccessible on Linux"
```

---

## Task 6: GitHub Actions workflow for Linux

This is where Linux gets exercised for real. The first push will likely surface bugs that we couldn't catch on macOS.

**Files:**
- Create: `.github/workflows/ci-linux.yml`

- [ ] **Step 1: Create `.github/workflows/ci-linux.yml`**

```yaml
name: CI (Linux)

on:
  push:
    branches: [main]
  pull_request:

jobs:
  smoke:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Verify KVM availability
        run: |
          ls -l /dev/kvm
          [ -r /dev/kvm ] && [ -w /dev/kvm ] || {
            echo "::error::/dev/kvm is not accessible on this runner"
            exit 1
          }

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            qemu-system-x86 qemu-utils \
            tio socat \
            ovmf \
            wget gpg \
            coreutils

      - name: Add SSH key for guest provisioning
        run: |
          mkdir -p ~/.ssh
          ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519

      - name: Run smoke test
        run: bash tests/run.sh
```

- [ ] **Step 2: Push and observe**

```bash
git add .github/workflows/ci-linux.yml
git commit -m "Add GitHub Actions workflow for Linux smoke test"
git push
```

Open the Actions tab on GitHub and observe the first run. **Almost certainly it will fail** — common reasons:
- `wget` writes to wrong dir (path issue)
- Alpine x86_64 ISO download path differs subtly from aarch64
- OVMF_CODE.fd is at `/usr/share/OVMF/OVMF_CODE_4M.fd` on newer Ubuntu (not `OVMF_CODE.fd`)
- Bootstrap interactive serial expects different login banner on x86_64 (unlikely — Alpine setup is uniform — but verify)
- `qemu-img create -F raw` may need `-F qcow2` for the `.fd` file

Iterate: read logs, fix, push, repeat. Each fix gets its own commit.

- [ ] **Step 3: Iterate to green**

For each CI failure:
1. Read the failure in the GitHub Actions log.
2. Reproduce or reason about it.
3. Apply minimal fix to `aq` or workflow.
4. Commit with descriptive message (`Fix OVMF_CODE path on Ubuntu 24.04`, `Use 4M OVMF variant`, etc.).
5. Push and re-run.

Common fixes likely needed:
- **OVMF path**: `/usr/share/OVMF/OVMF_CODE_4M.fd` and `OVMF_VARS_4M.fd` on Ubuntu 22+. Update `UEFI_CODE` and `ensure_uefi_vars` to detect.
- **`-cpu host` with KVM**: usually fine, but if issues, fall back to `-cpu max`.
- **Serial console login prompt**: Alpine should print `localhost login:` on both arches; if x86_64 uses `ttyS0` differently, may need explicit `-serial mon:stdio` adjustments.
- **First-boot `setup-alpine` differences**: x86_64 Alpine setup uses `/dev/sda` historically vs `/dev/vda` for virtio — but our `setup.conf` says `/dev/vda` which is virtio-correct on both. Should be fine.

Stop iterating when CI run goes green.

- [ ] **Step 4: Final commit**

After CI is green, ensure the last commit message is clean and descriptive. No squash needed; the iteration trail is useful history.

---

## Task 7: GitHub Actions workflow for macOS

Make sure Linux changes haven't regressed macOS behavior.

**Files:**
- Create: `.github/workflows/ci-macos.yml`

- [ ] **Step 1: Create `.github/workflows/ci-macos.yml`**

```yaml
name: CI (macOS)

on:
  push:
    branches: [main]
  pull_request:

jobs:
  smoke:
    runs-on: macos-14
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          brew install qemu tio socat

      - name: Add SSH key for guest provisioning
        run: |
          mkdir -p ~/.ssh
          ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519

      - name: Run smoke test
        run: bash tests/run.sh
```

- [ ] **Step 2: Push and verify**

```bash
git add .github/workflows/ci-macos.yml
git commit -m "Add GitHub Actions workflow for macOS smoke test"
git push
```

Verify the macOS job runs and passes. If macos-14 runners don't have HVF (they should — it's Apple Silicon hosted), document the failure and consider self-hosted alternative.

- [ ] **Step 3: Iterate if needed**

Same loop as Task 6 if anything fails on macOS CI specifically.

---

## Task 8: README updates

Document Linux support and dependency matrix.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README**

Run: `cat README.md` to see the current structure.

- [ ] **Step 2: Add a "Supported hosts" / "Installation" section**

Add this section near the top of `README.md` (after the brief description):

```markdown
## Supported hosts

| Host                      | Acceleration | Guest arch | Status |
|---------------------------|--------------|------------|--------|
| macOS (Apple Silicon)     | HVF          | aarch64    | Stable |
| Linux x86_64 (with KVM)   | KVM          | x86_64     | Stable |

## Installation

### macOS

    brew install qemu tio socat

### Linux (Debian/Ubuntu)

    sudo apt-get install -y qemu-system-x86 qemu-utils tio socat ovmf wget gpg
    sudo usermod -aG kvm $USER   # then log out and back in

Verify KVM is accessible:

    [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK"
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document Linux support and per-host installation"
```

---

## Task 9: VERSION bump and CHANGELOG

Final release-prep step. Bump VERSION to `2.0.0`.

**Files:**
- Modify: `aq` (line `VERSION=1.6.0`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Bump VERSION in `aq`**

Old:
```bash
VERSION=1.6.0
```

New:
```bash
VERSION=2.0.0
```

- [ ] **Step 2: Add CHANGELOG entry**

Edit `CHANGELOG.md`. Replace the `## Unreleased` section with:

```markdown
## Unreleased

## 2.0.0 "Crossing" 2026-04-30

### New Features

- Linux x86_64 host support with KVM acceleration. aq now runs on
  Ubuntu/Debian (and other Linux distros with /dev/kvm) using the
  same CLI as on macOS.
- Per-arch base image directory layout (`~/.local/share/aq/<arch>/...`).
  Existing macOS installs are migrated automatically on first run.
- GitHub Actions CI for both Linux (ubuntu-latest) and macOS (macos-14)
  runs the e2e smoke test on every push.

### Breaking Changes

None at the CLI level. Storage layout changed (auto-migrated).

### Internal

- New `detect_host()` runtime detection (HOST_OS / ARCH / ACCEL /
  QEMU_BIN / MACHINE_OPTS / UEFI_CODE / UEFI_VARS_FLAVOR).
- Split UEFI handling: `uefi-vars-sysbus` JSON on macOS, second
  pflash drive with .fd file on Linux.
- E2E smoke test under `tests/smoke.sh`.
```

- [ ] **Step 3: Run smoke test one more time**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. Sanity check before tagging.

- [ ] **Step 4: Commit**

```bash
git add aq CHANGELOG.md
git commit -m "Release 2.0.0 \"Crossing\" — Linux host support"
```

- [ ] **Step 5: Tag (optional, when ready to release)**

```bash
git tag v2.0.0
git push --tags
```

---

## Self-Review Checklist

After completing all tasks, verify:

- [ ] **Spec coverage:** every line item from the spec's "Layer 1 — Linux host support" section maps to a task above.
  - Runtime detection → Task 1 ✓
  - bootstrap_base_image for x86_64 → Tasks 2, 4 ✓
  - $BASE_DIR/$ARCH/... layout → Task 2 ✓
  - CI workflow on ubuntu-latest → Task 6 ✓
  - README dependency matrix → Task 8 ✓
  - KVM availability check with clear error → Task 5 ✓
  - Verify GH-hosted runners expose /dev/kvm → Task 6 step 1 (early in workflow) ✓
- [ ] **No placeholders:** no "TBD", no "implement later", no "similar to above"; every code block contains the actual code.
- [ ] **Type / name consistency:** `UEFI_VARS_FLAVOR` values (`sysbus_json`, `pflash_fd`) are referenced identically in `detect_host`, `uefi_vars_args`, `ensure_uefi_vars`, `aq_new`, and `bootstrap_base_image` finalisation.
- [ ] **macOS smoke test green** at every commit.
- [ ] **Linux CI green** by the end of Task 6.
- [ ] **macOS CI green** by the end of Task 7.

## Out of Scope (Phase 2+)

The following are intentionally NOT in this plan; they belong to Phase 2 (snapshots) or Phase 5+ (reaction loop):

- Snapshot CLI (`aq snapshot create/restore/...`)
- Fan-out / parallelism
- vfkit / firecracker backends
- OCI artifact push/pull
- AQ_FACTORS recipes
- Splitting the `aq` script into multiple files
