# Direct Kernel Boot + Per-Size Base Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut `aq new` wall-clock from ~15-20s to <3s on the warm path by replacing the UEFI/ISO boot chain with direct `-kernel/-initrd` QEMU args and pre-partitioning the base image at full target size so the guest skips `sfdisk` + `resize2fs` on first boot.

**Architecture:** Per-size catalog of independent base images (`alpine-base-<v>-<arch>-NG.raw`). `aq new --size=N` looks up or builds the size-N base on demand. Kernel + initramfs extracted once per arch via SSH right after the first base install completes; reused across sizes. Legacy UEFI path stays reachable via `--skip-fast-boot` for fallback.

**Tech Stack:** Bash 5, QEMU 10.x, `qemu-img`, OpenSSH (host + guest), Alpine Linux 3.22.x in-VM, `socat` for serial during ISO install. Tests are bash integration scripts run from `tests/`.

---

## Spec reference

This plan implements `docs/specs/2026-05-17-direct-kernel-boot-design.md`. The spec was last revised on commit `c686187`.

## File Structure

**Modified files:**
- `aq` (the bash CLI, ~200-300 lines net change). Existing pattern is one large file; we follow it.

**New files:**
- `tests/direct-kernel-boot.sh` — smoke test for the new boot path on the default size.
- `tests/size-base-catalog.sh` — smoke test for `--size=N` building a separate base.
- `tests/skip-fast-boot.sh` — smoke test for the legacy UEFI fallback.
- `tests/unit-helpers.sh` — sources `aq` and exercises pure-logic helpers (size parsing, filename composition).
- `docs/benchmarks/` directory (new dir) for measurement results.

**Touched but unchanged in spirit:**
- `tests/smoke.sh`, `tests/snapshots.sh`, `tests/live-snapshots.sh` — these continue to exercise the default path (which becomes direct kernel boot). Re-run after changes to confirm no regressions.

---

## Task 1: Pure-logic helpers — size parsing + filename composition

**Files:**
- Modify: `aq` (add two helper functions near the top, after `detect_host`).
- Create: `tests/unit-helpers.sh`

- [ ] **Step 1: Write failing tests**

Create `tests/unit-helpers.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for pure-logic helpers in aq.
set -eu
set -o pipefail

AQ_PATH="${AQ:-./aq}"

# Source the aq script but skip its main dispatch by intercepting argv.
# aq's dispatch happens via `aq_<cmd>` lookup at the end; by setting __AQ_SOURCED_ONLY=1
# we tell aq to define functions and stop. We'll add the guard in Step 3.
__AQ_SOURCED_ONLY=1 source "$AQ_PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# parse_size_arg
[ "$(parse_size_arg 8G)" = "8" ]      || fail "parse_size_arg 8G -> 8"
[ "$(parse_size_arg 16G)" = "16" ]    || fail "parse_size_arg 16G -> 16"
[ "$(parse_size_arg 2G)" = "2" ]      || fail "parse_size_arg 2G -> 2"
parse_size_arg 8 2>/dev/null          && fail "parse_size_arg 8 (no suffix) should error"
parse_size_arg 8M 2>/dev/null         && fail "parse_size_arg 8M (wrong unit) should error"
parse_size_arg garbage 2>/dev/null    && fail "parse_size_arg garbage should error"
parse_size_arg 0G 2>/dev/null         && fail "parse_size_arg 0G should error"
pass "parse_size_arg"

# compute_base_filename
[ "$(compute_base_filename 3.22.4 aarch64 8)" = "alpine-base-3.22.4-aarch64-8G.raw" ] \
  || fail "compute_base_filename 3.22.4 aarch64 8"
[ "$(compute_base_filename 3.22.4 x86_64 16)" = "alpine-base-3.22.4-x86_64-16G.raw" ] \
  || fail "compute_base_filename 3.22.4 x86_64 16"
pass "compute_base_filename"

echo "All unit-helpers tests passed."
```

- [ ] **Step 2: Run tests to verify failure**

```
chmod +x tests/unit-helpers.sh
./tests/unit-helpers.sh
```
Expected: fails with `parse_size_arg: command not found` (functions and the source-only guard don't exist yet).

- [ ] **Step 3: Implement helpers and sourced-only guard**

In `aq`, near the top after `detect_host()`'s closing brace, add:

```bash
# Parse a size argument like "8G" -> "8". Validates suffix is "G" and
# numeric part is a positive integer. Prints the integer or errors out.
parse_size_arg() {
  local arg="$1"
  case "$arg" in
    [1-9]G|[1-9][0-9]G|[1-9][0-9][0-9]G)
      echo "${arg%G}"
      ;;
    *)
      stderr "Error: invalid size '$arg'. Expected positive integer followed by G (e.g. 8G, 16G, 32G)."
      return 1
      ;;
  esac
}

# Compose a size-specific base filename.
# Usage: compute_base_filename <alpine-version> <arch> <size-int-G>
compute_base_filename() {
  local version="$1" arch="$2" size="$3"
  echo "alpine-base-${version}-${arch}-${size}G.raw"
}
```

In `aq`, at the very bottom (where dispatch happens), wrap the dispatch in a guard. Find the existing dispatch (around the end of file — likely a `case "$1" in ... aq_$1 "${@:2}" ;; esac` or similar) and prepend:

```bash
# Sourced-only mode: tests source this file just to call helpers.
# Defined functions remain available; dispatch is skipped.
if [ "${__AQ_SOURCED_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
```

- [ ] **Step 4: Run tests to verify success**

```
./tests/unit-helpers.sh
```
Expected: `PASS: parse_size_arg`, `PASS: compute_base_filename`, final `All unit-helpers tests passed.`

- [ ] **Step 5: Commit**

```bash
git add aq tests/unit-helpers.sh
git commit -m "feat(aq): size parsing + per-size base filename helpers"
```

---

## Task 2: `aq new --size=N` arg parsing

**Files:**
- Modify: `aq` — `aq_new()` function (around line 497).
- Modify: `tests/unit-helpers.sh` — add coverage for arg parsing.

- [ ] **Step 1: Locate the current `aq_new` arg parser**

Read lines 497-563 of `aq`. The existing parser handles `-p host:vm` port forwards, `--count=N`, and `--from-snapshot=tag`. We add `--size=N` to it.

- [ ] **Step 2: Write failing test**

Append to `tests/unit-helpers.sh` (before the final echo):

```bash
# aq_new size parsing — verify --size= is read and validated.
# We can't fully exercise aq_new (it spins up VMs), but we can test that
# argument extraction works by setting a probe variable.
test_size_parse() {
  local size
  size=$(__AQ_SOURCED_ONLY=1 NEW_SIZE_PROBE=1 \
    bash -c 'source '"$AQ_PATH"'; parse_new_args --size=8G dummy-vm; echo "$NEW_SIZE"')
  [ "$size" = "8" ] || fail "parse_new_args --size=8G -> NEW_SIZE=8 (got '$size')"
}
test_size_parse
pass "parse_new_args --size"
```

This refers to a new `parse_new_args` helper that sets `NEW_SIZE` (alongside existing parsed values). We'll extract it from `aq_new` in Step 3.

- [ ] **Step 3: Run tests to verify failure**

```
./tests/unit-helpers.sh
```
Expected: fails because `parse_new_args` doesn't exist yet.

- [ ] **Step 4: Extract arg parsing into `parse_new_args` and add `--size`**

Refactor `aq_new`'s arg parsing into a helper. Replace lines 497-528 (the part that walks `$@` and sets `forwards`, `from_snapshot`, `count`, etc.) by introducing:

```bash
# Parse `aq new` arguments. Sets module-level variables that aq_new reads:
#   FORWARDS (array), FROM_SNAPSHOT, COUNT, NEW_SIZE, VM_NAME
# Validates and exits on error.
parse_new_args() {
  FORWARDS=()
  FROM_SNAPSHOT=""
  COUNT=1
  NEW_SIZE="2"   # default; matches today's effective per-VM disk size
  VM_NAME=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -p)
        FORWARDS+=("$2"); shift 2 ;;
      -p*)
        FORWARDS+=("${1#-p}"); shift ;;
      --from-snapshot=*)
        FROM_SNAPSHOT="${1#--from-snapshot=}"; shift ;;
      --from-snapshot)
        FROM_SNAPSHOT="$2"; shift 2 ;;
      --count=*)
        COUNT="${1#--count=}"; shift ;;
      --count)
        COUNT="$2"; shift 2 ;;
      --size=*)
        NEW_SIZE=$(parse_size_arg "${1#--size=}") || exit 1
        shift ;;
      --size)
        NEW_SIZE=$(parse_size_arg "$2") || exit 1
        shift 2 ;;
      --skip-fast-boot)
        SKIP_FAST_BOOT=1; shift ;;
      -*)
        stderr "Error: unknown option '$1'"; exit 1 ;;
      *)
        if [ -z "$VM_NAME" ]; then VM_NAME="$1"; else
          stderr "Error: unexpected argument '$1'"; exit 1
        fi
        shift ;;
    esac
  done
}
```

Update `aq_new` to call `parse_new_args "$@"` first, then use the populated variables. Replace the inline parser. Default `SKIP_FAST_BOOT` to 0 at the top of `parse_new_args`: `SKIP_FAST_BOOT=0`.

- [ ] **Step 5: Run tests to verify success**

```
./tests/unit-helpers.sh
```
Expected: all PASS including `parse_new_args --size`.

- [ ] **Step 6: Confirm legacy invocations still parse**

Manual: `./aq new --help 2>&1 | head -3` should still print help (or whatever the no-args behavior was). `./aq new -p 8080:80 foo` should still set up the forward. Try `./aq new --size=8G --from-snapshot=foo bar` — no crash; `NEW_SIZE=8, FROM_SNAPSHOT=foo, VM_NAME=bar`. Use `set -x` temporarily if needed.

- [ ] **Step 7: Commit**

```bash
git add aq tests/unit-helpers.sh
git commit -m "feat(aq): --size=N flag for aq new + arg-parsing extraction"
```

---

## Task 3: `bootstrap_base_image` accepts size parameter

**Files:**
- Modify: `aq` — `bootstrap_base_image()` (around line 351) and `ensure_base_image()` (around line 347).

- [ ] **Step 1: Note the current state**

Currently `LATEST_ALPINE_BASE` is a hardcoded global. `bootstrap_base_image` takes no arguments and creates a 500M raw at the hardcoded path.

- [ ] **Step 2: Add size parameter through the chain**

Replace the global `LATEST_ALPINE_BASE` constant with a derived expression. At the top of `aq` near line 199 (where `LATEST_ALPINE_BASE` is declared):

```bash
# Per-size base filename. SIZE is set by aq_new (default 2) via parse_new_args.
# This expression is re-evaluated per-call; do not capture into a constant.
alpine_base_for_size() {
  compute_base_filename "$LATEST_ALPINE_VERSION" "$ARCH" "$1"
}
```

Remove the `LATEST_ALPINE_BASE=alpine-base-$LATEST_ALPINE_VERSION-$ARCH.raw` line at line 199.

Update `ensure_base_image` to take size:

```bash
ensure_base_image() {
  local size="$1"
  local fname; fname=$(alpine_base_for_size "$size")
  [ -f "$BASE_DIR/$ARCH/$fname" ] || bootstrap_base_image "$size"
}
```

Update `bootstrap_base_image` signature and body:

```bash
bootstrap_base_image() {
  local size="$1"
  local fname; fname=$(alpine_base_for_size "$size")
  download_alpine_iso
  (
    mkdir -p $BASE_DIR/$ARCH
    cd $BASE_DIR/$ARCH

    rm -f "wip-$fname"
    rm -f uefi-vars.json uefi-vars.fd

    qemu-img create -f raw "wip-$fname" "${size}G" 1>/dev/null
    # ... rest unchanged up to the final mv/chmod ...
```

At the bottom of `bootstrap_base_image` (around line 488-489), replace `mv $BASE_DIR/$ARCH/{wip-,}$LATEST_ALPINE_BASE` and `chmod -w` with:

```bash
    mv "$BASE_DIR/$ARCH/wip-$fname" "$BASE_DIR/$ARCH/$fname"
    chmod -w "$BASE_DIR/$ARCH/$fname"
```

Find every other reference to `$LATEST_ALPINE_BASE` in `aq` (`grep -n LATEST_ALPINE_BASE aq`). Each one needs to become an `alpine_base_for_size` call with the appropriate size. The main hot spot is around line 581 inside `_aq_new_one`:

Before:
```bash
backing_file="$BASE_DIR/$ARCH/$LATEST_ALPINE_BASE"
```

After:
```bash
backing_file="$BASE_DIR/$ARCH/$(alpine_base_for_size "$NEW_SIZE")"
```

Similarly update `write_meta` around line 254 which references `$LATEST_ALPINE_BASE` — replace with a per-VM recorded value:

```bash
printf '  "base_image": "%s",\n'  "$(alpine_base_for_size "$NEW_SIZE")"    >> "$dir/meta.json.tmp"
```

- [ ] **Step 3: Quick smoke**

```
./aq new --size=2G test-quick
```
Expected: works exactly as before (2G is default size). Builds `alpine-base-3.22.4-<arch>-2G.raw` if missing.

```
./aq rm test-quick
```

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "feat(aq): thread size parameter through base build"
```

---

## Task 4: Extract kernel + initramfs after first base install

**Files:**
- Modify: `aq` — extend `bootstrap_base_image` to do a reboot-and-extract cycle after `setup-alpine` completes.

- [ ] **Step 1: Plan the extraction flow**

After `setup-alpine` finishes (current line 458 `wait_for "expect(\"SETUP_ALPINE_${ARCH}_OK\")"`), we currently clean up `/root/setup.conf` and poweroff. We need to insert: reboot into installed Alpine, SSH in, scp out kernel + initramfs, then poweroff.

Kernel and initramfs are reused across sizes (same Alpine version + arch). We only need to do this if they don't already exist for the arch:

```bash
[ -f "$BASE_DIR/$ARCH/vmlinuz-virt" ] && [ -f "$BASE_DIR/$ARCH/initramfs-virt" ]
```

- [ ] **Step 2: Add extraction logic to `bootstrap_base_image`**

The existing cleanup phase (around line 472) already does:

```bash
echo "mkdir -p /target; mount /dev/vda3 /target; rm -f /target/root/setup.conf; umount /target" | socat STDIO UNIX:command.sock
```

This runs in the **live ISO Alpine**, with the installed Alpine's rootfs mounted at `/target`. The installed kernel + initramfs are at `/target/boot/vmlinuz-virt` and `/target/boot/initramfs-virt`.

We DO NOT reboot into the installed Alpine — setup-alpine does not configure a serial-getty (per the existing comment in aq), so a serial login prompt would never appear. Instead, we read kernel files while still in the live ISO Alpine, before unmounting `/target`.

Replace the existing single-line `mkdir /target; ... umount /target` invocation with a multi-line flow that also extracts kernel files:

```bash
    # If kernel/initramfs are already extracted for this arch, just clean up
    # setup.conf and unmount (matches existing behaviour).
    if [ -f "$BASE_DIR/$ARCH/vmlinuz-virt" ] && [ -f "$BASE_DIR/$ARCH/initramfs-virt" ]; then
      echo "mkdir -p /target; mount /dev/vda3 /target; rm -f /target/root/setup.conf; umount /target" \
        | socat STDIO UNIX:command.sock
    else
      stderr "Extracting kernel + initramfs (one-time per arch, ~30 s)..."

      # Mount the installed rootfs and clean up.
      echo "mkdir -p /target && mount /dev/vda3 /target && rm -f /target/root/setup.conf" \
        | socat STDIO UNIX:command.sock

      # Stream vmlinuz-virt and initramfs-virt out via serial+base64. The
      # sentinel lines bracket the payload; we strip them on the host.
      # Each blob is read in one `socat` invocation. base64 with -w0 keeps
      # the stream as a single long line (avoids busybox quirks with line
      # wrapping at varying widths).
      {
        echo "echo __VMLINUZ_BEGIN__"
        echo "base64 -w0 /target/boot/vmlinuz-virt"
        echo "echo"
        echo "echo __VMLINUZ_END__"
      } | socat STDIO UNIX:command.sock > "$BASE_DIR/$ARCH/wip-vmlinuz.raw"

      {
        echo "echo __INITRAMFS_BEGIN__"
        echo "base64 -w0 /target/boot/initramfs-virt"
        echo "echo"
        echo "echo __INITRAMFS_END__"
      } | socat STDIO UNIX:command.sock > "$BASE_DIR/$ARCH/wip-initramfs.raw"

      echo "umount /target" | socat STDIO UNIX:command.sock

      # Extract the base64 payloads from the raw socat capture. Each blob is
      # the line between the BEGIN and END sentinels.
      awk '/^__VMLINUZ_BEGIN__/{f=1;next} /^__VMLINUZ_END__/{f=0} f' \
        "$BASE_DIR/$ARCH/wip-vmlinuz.raw" \
        | base64 -d > "$BASE_DIR/$ARCH/wip-vmlinuz-virt"
      awk '/^__INITRAMFS_BEGIN__/{f=1;next} /^__INITRAMFS_END__/{f=0} f' \
        "$BASE_DIR/$ARCH/wip-initramfs.raw" \
        | base64 -d > "$BASE_DIR/$ARCH/wip-initramfs-virt"
      rm -f "$BASE_DIR/$ARCH/wip-vmlinuz.raw" "$BASE_DIR/$ARCH/wip-initramfs.raw"

      # Sanity check: kernel and initramfs should be non-trivial in size.
      vsz=$(wc -c < "$BASE_DIR/$ARCH/wip-vmlinuz-virt")
      isz=$(wc -c < "$BASE_DIR/$ARCH/wip-initramfs-virt")
      if [ "$vsz" -lt 1000000 ] || [ "$isz" -lt 1000000 ]; then
        stderr "Error: kernel/initramfs extraction produced suspiciously small files (vmlinuz=$vsz, initramfs=$isz)."
        stderr "       Serial extraction may have failed. Inspect $BASE_DIR/$ARCH/wip-*.raw if rerun."
        exit 1
      fi

      mv "$BASE_DIR/$ARCH/wip-vmlinuz-virt"   "$BASE_DIR/$ARCH/vmlinuz-virt"
      mv "$BASE_DIR/$ARCH/wip-initramfs-virt" "$BASE_DIR/$ARCH/initramfs-virt"
      chmod -w "$BASE_DIR/$ARCH/vmlinuz-virt" "$BASE_DIR/$ARCH/initramfs-virt"
      stderr "  ..done (vmlinuz=$vsz initramfs=$isz bytes)"
    fi
```

Why this works:
- We're still in the live ISO Alpine when extraction runs (no reboot).
- `/target` is mounted from `/dev/vda3` (installed rootfs).
- `base64 -w0` emits a single long line; trivial to delimit with sentinels.
- The base64 payload reaches the host via the serial Unix socket; we strip everything except the payload lines.

If `base64 -w0` is unavailable in the live ISO Alpine's busybox (it's usually present, but worth checking), the fallback is `base64 | tr -d '\n'` — also single line. Adjust the script if the first run produces empty wip-*.raw files.

- [ ] **Step 3: Manual smoke**

```
# Wipe any extracted kernel from prior runs to force a re-extract.
rm -f ~/.local/share/aq/$(uname -m | sed 's/arm64/aarch64/')/vmlinuz-virt
rm -f ~/.local/share/aq/$(uname -m | sed 's/arm64/aarch64/')/initramfs-virt
# Trigger a base build that will exercise extraction:
./aq new --size=2G test-extract
./aq rm test-extract
ls -la ~/.local/share/aq/$(uname -m | sed 's/arm64/aarch64/')/vmlinuz-virt
ls -la ~/.local/share/aq/$(uname -m | sed 's/arm64/aarch64/')/initramfs-virt
```
Expected: both files present and non-empty (typical sizes: vmlinuz ~10 MB, initramfs ~50 MB).

If extraction over serial is broken (corrupted output), fall back to the hostfwd-SSH plan documented above. Stop and ask before committing if that becomes necessary — it changes the spec slightly.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "feat(aq): extract kernel + initramfs during first base install"
```

---

## Task 5: Direct kernel boot in `_aq_new_one` (default path)

**Files:**
- Modify: `aq` — `_aq_new_one()` (around line 565-635) where the QEMU args for new VMs are composed.

- [ ] **Step 1: Locate the existing QEMU args for `_aq_new_one`**

Look for the `$QEMU_BIN \ -machine $MACHINE_OPTS -accel $ACCEL ...` block. The existing VM-launch path uses UEFI args. We add a new conditional branch.

- [ ] **Step 2: Add per-arch console name to `detect_host`**

In `detect_host` (line 72), add a `CONSOLE` variable per arch:

```bash
case "$(uname -s)" in
  Darwin)
    HOST_OS=darwin
    ARCH=aarch64
    ACCEL=hvf
    QEMU_BIN=qemu-system-aarch64
    MACHINE_OPTS="virt,highmem=on"
    UEFI_CODE="$(brew --prefix qemu 2>/dev/null)/share/qemu/edk2-aarch64-code.fd"
    UEFI_VARS_FLAVOR=sysbus_json
    CONSOLE=ttyAMA0
    ;;
  Linux)
    HOST_OS=linux
    ARCH=x86_64
    QEMU_BIN=qemu-system-x86_64
    MACHINE_OPTS="q35"
    UEFI_CODE=$(find_ovmf_code) || {
      echo "Error: OVMF firmware not found. Install package 'ovmf'." >&2
      exit 1
    }
    UEFI_VARS_FLAVOR=pflash_fd
    CONSOLE=ttyS0
    # ... existing /dev/kvm checks ...
    ;;
```

- [ ] **Step 3: Add direct-kernel-boot branch in the VM-start path**

Find the block in `_aq_new_one` that runs the per-VM QEMU instance. Wrap the UEFI-specific args in a conditional. Pseudocode:

```bash
if [ "${SKIP_FAST_BOOT:-0}" = "1" ]; then
  # Legacy UEFI path — existing args.
  uefi_args=(
    -drive "file=$UEFI_CODE,format=raw,if=pflash,readonly=on,unit=0"
    $(uefi_vars_args .)
  )
  boot_args=("${uefi_args[@]}")
else
  # Direct kernel boot — no UEFI, no bootloader.
  boot_args=(
    -kernel "$BASE_DIR/$ARCH/vmlinuz-virt"
    -initrd "$BASE_DIR/$ARCH/initramfs-virt"
    -append "console=$CONSOLE root=/dev/vda3 rw quiet"
  )
fi

$QEMU_BIN \
  -machine $MACHINE_OPTS -accel $ACCEL -cpu host -m 1G \
  "${boot_args[@]}" \
  -drive if=virtio,file=storage.qcow2,format=qcow2,cache=none \
  ... rest of args unchanged ...
```

Locate the *actual* place in the existing `_aq_new_one` where the qemu command is run — read lines ~620-640 — and apply the equivalent structure. The existing code uses literal flags joined into one line; convert to an array as needed.

- [ ] **Step 4: Write per-VM markers (boot mode, size)**

In `_aq_new_one`, right after creating the VM directory and the overlay
disk (around line 615, alongside the existing `.needs_first_boot_setup`
logic), write three markers used by later tasks:

```bash
echo "$NEW_SIZE" > "$BASE_DIR/$vm_name/.size"

if [ "${SKIP_FAST_BOOT:-0}" = "1" ]; then
  touch "$BASE_DIR/$vm_name/.boot_mode_uefi"
else
  touch "$BASE_DIR/$vm_name/.boot_mode_direct"
fi
```

Then replace the existing `first_boot_setup` marker so it only fires on
the legacy UEFI fallback path (size-N bases are pre-partitioned):

```bash
# Only flag first-boot setup on the legacy UEFI fallback path.
if [ -z "$from_snapshot" ] && [ "${SKIP_FAST_BOOT:-0}" = "1" ]; then
  touch .needs_first_boot_setup
fi
```

The corresponding consumer of `.needs_first_boot_setup` (the code that runs sfdisk/resize2fs on first boot) stays unchanged — it only fires when the marker is present.

- [ ] **Step 5: Smoke run**

```
./aq new --size=2G test-direct
./aq exec test-direct uname -r          # should print Alpine kernel version
./aq exec test-direct df -h /            # rootfs at 2G already
./aq stop test-direct
./aq rm test-direct
```
Expected: VM boots and is usable. No `sfdisk`/`resize2fs` messages in the boot output.

If boot fails: check `-append` string (`root=/dev/vda3` may be wrong if Alpine's `setup-alpine` chose a different partition layout). Use `./aq console test-direct` to diagnose, or fall back to `--skip-fast-boot` to confirm UEFI path still works.

- [ ] **Step 6: Commit**

```bash
git add aq
git commit -m "feat(aq): direct kernel boot is the default path for aq new"
```

---

## Task 6: `--skip-fast-boot` legacy UEFI path

**Files:**
- Modify: `aq` — confirm legacy branch in `_aq_new_one` works end-to-end.

- [ ] **Step 1: The flag is already parsed (Task 2) and gated (Task 5)**

`SKIP_FAST_BOOT` is set by `parse_new_args`. The conditional in Task 5 branches on it.

- [ ] **Step 2: Verify legacy UEFI flow still works**

```
./aq new --skip-fast-boot --size=2G test-legacy
./aq exec test-legacy 'echo from-legacy'
./aq rm test-legacy
```
Expected: VM boots via UEFI (you'll see edk2 firmware output briefly), guest runs first-boot setup (sfdisk + resize2fs), `aq exec` returns `from-legacy`.

- [ ] **Step 3: Commit**

```bash
git add aq
git commit -m "test(aq): verify --skip-fast-boot legacy UEFI path"
```

(No code change; this commit captures the verification step in history.)

---

## Task 7: Snapshot live restore refuses under `--skip-fast-boot`

**Files:**
- Modify: `aq` — annotate snapshot meta.json with boot mode; reject mismatched live restores.

- [ ] **Step 1: Locate snapshot metadata writers/readers**

`write_meta` (line 244) writes `snapshot/meta.json` for a tag. `read_meta` (line 264) reads it. `aq_snapshot_create` calls `write_meta` (around line 1182). `aq_new --from-snapshot` calls `read_meta` (around line 572).

- [ ] **Step 2: Add `boot_mode` field to meta.json**

Modify `write_meta` to take an extra parameter and emit it:

```bash
write_meta() {
  local tag="$1" parent="$2" vm_name="$3" has_memory="$4" boot_mode="$5"
  # ... existing emits ...
  printf '  "boot_mode": "%s"\n' "$boot_mode" >> "$dir/meta.json.tmp"
  # ... rest of meta.json closing ...
}
```

Update the call sites in `aq_snapshot_create` to pass `boot_mode` — derive it from the VM's own marker. Add to `_aq_new_one`: after the conditional in Task 5, also `touch .boot_mode_direct` or `.boot_mode_uefi` to mark which boot mode this VM was created with. Then in `aq_snapshot_create`, read that marker to compute `boot_mode`:

```bash
local boot_mode
if [ -f "$BASE_DIR/$vm_name/.boot_mode_direct" ]; then
  boot_mode=direct
elif [ -f "$BASE_DIR/$vm_name/.boot_mode_uefi" ]; then
  boot_mode=uefi
else
  boot_mode=unknown   # pre-Phase-2 VM
fi
```

- [ ] **Step 3: Reject mismatched live restore in `aq_new --from-snapshot`**

Around line 572 where `_aq_new_one` is called with `from_snapshot`, after `resolve_tag` and before creating the VM, inspect the snapshot's meta.json:

```bash
if [ -n "$from_snapshot" ]; then
  local snap_meta="$(snapshot_path "$resolved")/meta.json"
  local snap_has_memory snap_boot_mode
  snap_has_memory=$(read_meta "$resolved" has_memory)
  snap_boot_mode=$(read_meta "$resolved" boot_mode)

  local current_mode=direct
  [ "${SKIP_FAST_BOOT:-0}" = "1" ] && current_mode=uefi

  if [ "$snap_has_memory" = "true" ] && [ "$snap_boot_mode" != "$current_mode" ] && [ "$snap_boot_mode" != "unknown" ]; then
    stderr "Error: live snapshot '$resolved' was taken under boot_mode=$snap_boot_mode."
    stderr "       You are creating a VM under boot_mode=$current_mode."
    stderr "       Memory state is incompatible across boot modes."
    stderr "       Use --skip-fast-boot $([ "$snap_boot_mode" = "uefi" ] && echo "" || echo "(remove --skip-fast-boot)") to match,"
    stderr "       or take a fresh cold snapshot first."
    exit 1
  fi
fi
```

(`read_meta` may need extending to accept a field name argument — if it already does, great; if not, extend it minimally.)

- [ ] **Step 4: Smoke**

```
# Create a VM, snapshot it live, then try to restore under the wrong mode.
./aq new --size=2G test-snap-src
./aq start test-snap-src
./aq snapshot create test-snap-src tag-direct
./aq stop test-snap-src
./aq rm test-snap-src

# Cold restore — should warn or succeed (cold snapshots are mode-agnostic).
./aq new --from-snapshot=tag-direct test-snap-cold
./aq rm test-snap-cold

# Live restore under wrong mode — should refuse.
./aq new --skip-fast-boot --from-snapshot=tag-direct test-snap-wrong 2>&1 | grep -q "incompatible across boot modes"
echo "PASS: live restore rejected under mismatched boot mode"

./aq snapshot rm --force tag-direct
```

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "feat(aq): refuse live snapshot restore under mismatched boot mode"
```

---

## Task 8: Disk-full error handling

**Files:**
- Modify: `aq` — wrap QEMU and `aq exec` failures.

- [ ] **Step 1: Identify failure points**

QEMU disk IO failures surface as exit codes from `aq exec` (SSH commands return non-zero when the guest fs is full) or as QEMU log lines on disk write errors. The cheap detection: post-fail, inspect the last 100 lines of guest dmesg for `No space left on device` or `EXT4-fs error.*ENOSPC`. The cheaper detection: just emit the actionable message any time an `aq exec` exits non-zero with stderr matching `No space left on device`.

- [ ] **Step 2: Add a wrapper function**

Near the end of `aq` after the existing helpers, add:

```bash
emit_disk_full_help() {
  local vm_name="$1" size="$2"
  cat >&2 <<EOM
ERROR: VM '$vm_name' is out of disk space (current: ${size}G).

To recreate this VM with more space:

  aq rm $vm_name
  aq new --size=8G $vm_name     # or 16G, 32G, etc.

If the requested-size base doesn't exist yet, this will build it once
(~30 s). Every subsequent aq new --size=8G is fast.

Per-VM resize (existing data preserved) is also possible but trickier:

  qemu-img resize $BASE_DIR/$ARCH/$vm_name/storage.qcow2 +6G
  aq exec $vm_name "growpart /dev/vda 3 && resize2fs /dev/vda3"
  # Note: this requires e2fsprogs-extra + cloud-utils-growpart inside
  # the guest. They're not preinstalled in the base.
EOM
  echo "$vm_name out of disk space (size ${size}G)" \
    > "$BASE_DIR/$vm_name/.last-error" 2>/dev/null || true
}

# Wrap a command; if it fails AND the error mentions disk full,
# emit the help message. Usage: with_disk_full_help vm_name size -- command...
with_disk_full_help() {
  local vm="$1" size="$2"; shift 2; shift # skip --
  local out rc
  if out=$("$@" 2>&1); then echo "$out"; return 0; fi
  rc=$?
  echo "$out" >&2
  if echo "$out" | grep -qE 'No space left on device|EXT4-fs.*ENOSPC|qemu.*ENOSPC'; then
    emit_disk_full_help "$vm" "$size"
  fi
  return $rc
}
```

- [ ] **Step 3: Apply the wrapper at one entry point**

Wrapping every callsite is overkill. The primary entry point is `aq_exec`. Add the disk-full check there: after the SSH/serial command returns non-zero, scan its output and possibly emit the help.

Find `aq_exec` (`grep -n "^aq_exec" aq`) and add at the failure path. The minimum addition is the grep + emit_disk_full_help call:

```bash
aq_exec() {
  # ... existing setup ...
  local cmd_output cmd_rc
  cmd_output=$(... existing exec call ...) || cmd_rc=$?
  if [ "${cmd_rc:-0}" -ne 0 ] && echo "$cmd_output" | grep -qE 'No space left on device|EXT4-fs.*ENOSPC'; then
    local vm_size; vm_size=$(read_vm_size_marker "$vm_name" || echo 2)
    emit_disk_full_help "$vm_name" "$vm_size"
  fi
  echo "$cmd_output"
  return "${cmd_rc:-0}"
}
```

Where `read_vm_size_marker` reads `.size` from the VM directory (which `_aq_new_one` writes alongside `.boot_mode_*`).

In `_aq_new_one`, alongside the boot mode marker, write the size:
```bash
echo "$NEW_SIZE" > "$BASE_DIR/$vm_name/.size"
```

- [ ] **Step 4: Smoke**

Hard to test deterministically. Verify the wrapper compiles and the entry path doesn't regress:

```
./aq new --size=2G test-df
./aq exec test-df 'echo hello'   # should still print hello, no disk-full triggered
./aq rm test-df
```

Manual disk-full test (optional, slow):
```
./aq new --size=2G test-df
./aq exec test-df 'dd if=/dev/zero of=/big bs=1M count=2200 || true'   # try to fill to ~2.2G
./aq exec test-df 'echo test'   # this command would fail if rootfs full
```
Look for the disk-full help in stderr.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "feat(aq): actionable error when guest runs out of disk"
```

---

## Task 9: End-to-end smoke — direct kernel boot

**Files:**
- Create: `tests/direct-kernel-boot.sh`

- [ ] **Step 1: Author the test**

```bash
#!/usr/bin/env bash
# E2E: aq new (default direct kernel boot) works.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM="aq-dkb-$$"

cleanup() { set +e; "$AQ" stop "$VM" 2>/dev/null; "$AQ" rm "$VM" 2>/dev/null; }
trap cleanup EXIT

echo "[dkb] aq new (default size, direct kernel boot)"
"$AQ" new "$VM"

echo "[dkb] aq exec uname"
out=$("$AQ" exec "$VM" uname -r)
[ -n "$out" ] || { echo "[dkb] FAIL: empty kernel version"; exit 1; }
echo "[dkb] kernel: $out"

echo "[dkb] df -h /"
"$AQ" exec "$VM" df -h /

echo "[dkb] confirm no resize2fs ran on this boot"
ranges=$("$AQ" exec "$VM" 'dmesg | grep -ic resize2fs || true')
[ "$ranges" = "0" ] || { echo "[dkb] FAIL: resize2fs ran ($ranges hits)"; exit 1; }

echo "[dkb] confirm /dev/vda3 is mounted at rootfs"
mp=$("$AQ" exec "$VM" 'findmnt -no SOURCE /')
[ "$mp" = "/dev/vda3" ] || { echo "[dkb] FAIL: rootfs is $mp, expected /dev/vda3"; exit 1; }

echo "[dkb] aq stop"
"$AQ" stop "$VM"
echo "[dkb] OK"
```

`chmod +x tests/direct-kernel-boot.sh`.

- [ ] **Step 2: Run it**

```
./tests/direct-kernel-boot.sh
```
Expected: all `[dkb]` lines, ending with `OK`.

- [ ] **Step 3: Commit**

```bash
git add tests/direct-kernel-boot.sh
git commit -m "test(aq): smoke direct kernel boot end-to-end"
```

---

## Task 10: End-to-end smoke — per-size base catalog

**Files:**
- Create: `tests/size-base-catalog.sh`

- [ ] **Step 1: Author the test**

```bash
#!/usr/bin/env bash
# E2E: aq new --size=N builds and reuses a size-N base.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM1="aq-size-${$}-a"
VM2="aq-size-${$}-b"

cleanup() {
  set +e
  for vm in "$VM1" "$VM2"; do
    "$AQ" stop "$vm" 2>/dev/null
    "$AQ" rm "$vm" 2>/dev/null
  done
}
trap cleanup EXIT

# Compute size-base path the same way aq does.
ARCH=$(uname -m)
case "$ARCH" in arm64) ARCH=aarch64 ;; esac
BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/aq/$ARCH"

# Pick a size unlikely to already exist (so we exercise the build path).
SIZE=3   # 3G — non-default, unusual

BASE_PATH="$BASE_DIR/alpine-base-"*"-${ARCH}-${SIZE}G.raw"
rm -f $BASE_PATH 2>/dev/null || true

t0=$(date +%s)
echo "[scat] first aq new --size=${SIZE}G (cold, builds base)"
"$AQ" new --size="${SIZE}G" "$VM1"
t_cold=$(( $(date +%s) - t0 ))

# Verify size-N base file was created.
ls $BASE_PATH > /dev/null || { echo "[scat] FAIL: size-${SIZE}G base not found"; exit 1; }

# Verify guest sees N-sized rootfs.
size_g=$("$AQ" exec "$VM1" "df -BG --output=size / | tail -1 | tr -d ' G'")
[ "$size_g" -ge $((SIZE - 1)) ] || { echo "[scat] FAIL: rootfs ${size_g}G < expected ~${SIZE}G"; exit 1; }

t1=$(date +%s)
echo "[scat] second aq new --size=${SIZE}G (warm, reuses base)"
"$AQ" new --size="${SIZE}G" "$VM2"
t_warm=$(( $(date +%s) - t1 ))

echo "[scat] timings: cold=${t_cold}s warm=${t_warm}s"
[ "$t_warm" -lt "$t_cold" ] || { echo "[scat] FAIL: warm ($t_warm) not faster than cold ($t_cold)"; exit 1; }

echo "[scat] OK"
```

`chmod +x tests/size-base-catalog.sh`.

- [ ] **Step 2: Run it**

```
./tests/size-base-catalog.sh
```
Expected: cold path builds the base (~30 s), warm reuses it (a few seconds), both VMs see ~3 G rootfs, `OK` at end.

- [ ] **Step 3: Commit**

```bash
git add tests/size-base-catalog.sh
git commit -m "test(aq): smoke per-size base catalog (cold build, warm reuse)"
```

---

## Task 11: End-to-end smoke — `--skip-fast-boot` legacy fallback

**Files:**
- Create: `tests/skip-fast-boot.sh`

- [ ] **Step 1: Author the test**

```bash
#!/usr/bin/env bash
# E2E: --skip-fast-boot exercises the legacy UEFI path.

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
VM="aq-legacy-$$"

cleanup() { set +e; "$AQ" stop "$VM" 2>/dev/null; "$AQ" rm "$VM" 2>/dev/null; }
trap cleanup EXIT

echo "[legacy] aq new --skip-fast-boot"
"$AQ" new --skip-fast-boot "$VM"

echo "[legacy] aq exec hello"
out=$("$AQ" exec "$VM" 'echo hello')
[ "$out" = "hello" ] || { echo "[legacy] FAIL: '$out' != 'hello'"; exit 1; }

# On the legacy path, /target was historically created by setup-alpine for the
# first-boot resize. The marker .needs_first_boot_setup should have been
# placed and consumed; check that the rootfs has been resized to fill the
# (default 2G) overlay disk.
size_g=$("$AQ" exec "$VM" "df -BG --output=size / | tail -1 | tr -d ' G'")
[ "$size_g" -ge 1 ] || { echo "[legacy] FAIL: rootfs size ${size_g}G"; exit 1; }

echo "[legacy] OK"
```

- [ ] **Step 2: Run it**

```
chmod +x tests/skip-fast-boot.sh
./tests/skip-fast-boot.sh
```
Expected: completes, `OK` at end. Will take longer than direct kernel boot (UEFI firmware spinup + first-boot resize).

- [ ] **Step 3: Commit**

```bash
git add tests/skip-fast-boot.sh
git commit -m "test(aq): smoke --skip-fast-boot legacy path"
```

---

## Task 12: Benchmark recording

**Files:**
- Create: `docs/benchmarks/2026-05-DD-direct-kernel-boot.md` (use today's date)

- [ ] **Step 1: Run the benchmark workload**

```
# Cold: wipe any cached size-2 base, then time aq new.
rm -f ~/.local/share/aq/*/alpine-base-*-2G.raw
time ./aq new aq-bench-cold
./aq rm aq-bench-cold

# Warm: size-2 base now exists. Time aq new again.
time ./aq new aq-bench-warm
./aq rm aq-bench-warm

# Legacy: same workload with --skip-fast-boot.
time ./aq new --skip-fast-boot aq-bench-legacy
./aq rm aq-bench-legacy
```

Record each `real` timing.

- [ ] **Step 2: Author the doc**

```markdown
# aq direct kernel boot — Benchmark

**Date:** 2026-05-DD
**Host:** <uname -a / CPU / RAM>
**QEMU:** <qemu-img --version | head -1>
**Alpine version:** 3.22.4

## Workload

`aq new <vm-name>` from a clean state, then `aq rm`. No `aq exec` work
(measures only VM creation + boot).

## Timings

| Path | Time | Notes |
|---|---|---|
| Cold (no size-2 base yet) | <X> s | Builds size-2 base first; ~30 s one-time. |
| Warm (size-2 base cached) | <Y> s | Direct kernel boot, no first-boot setup. |
| Legacy (`--skip-fast-boot`) | <Z> s | UEFI + setup-alpine + first-boot resize. |

## Targets per spec

Warm should be <3 s. Legacy should be roughly the pre-Phase-2 baseline
(~15-20 s).

## Decision

<pass / fail vs spec target; any follow-up tasks>
```

- [ ] **Step 3: Commit**

```bash
mkdir -p docs/benchmarks
git add docs/benchmarks/2026-05-*-direct-kernel-boot.md
git commit -m "docs(benchmark): record direct kernel boot timings"
```

---

## Self-Review Checklist

After all tasks land:

- [ ] `tests/unit-helpers.sh` — passes.
- [ ] `tests/smoke.sh` — passes (regression of existing lifecycle test).
- [ ] `tests/snapshots.sh` — passes (cold snapshot create/restore).
- [ ] `tests/live-snapshots.sh` — passes (live snapshot create/restore under direct boot mode).
- [ ] `tests/fanout.sh` — passes (`--count=N` still works).
- [ ] `tests/direct-kernel-boot.sh` — new, passes.
- [ ] `tests/size-base-catalog.sh` — new, passes.
- [ ] `tests/skip-fast-boot.sh` — new, passes.
- [ ] `aq` shellcheck-clean (or no new findings).
- [ ] Benchmark doc filled in with actual numbers; warm target met.

## Known follow-ups (post-this-plan)

- `aq base prune` — delete bases with no referring VMs/snapshots. YAGNI until catalog gets cluttered.
- `aq base prewarm <sizes...>` — proactively build common sizes (e.g., during install) so the first per-size `aq new` isn't slow. Optional.
- Speeding up base build via Alpine cloud images (vs the current ISO + setup-alpine flow). Mentioned in `ROADMAP.md`.
- Migrating to qcow2 base (depot.dev pattern). Out of scope; document only if a measured need surfaces.

## Out of scope

- Firecracker / Cloud Hypervisor backend. Separate phase; depends on this one's measurement.
- Memory snapshot/restore optimization beyond what's already implemented (live snapshots).
- Custom init replacement, hugepages, kvm-clock micro-opts.
