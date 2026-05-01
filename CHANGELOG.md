# Changelog

## Unreleased

### New Features

- **Linux x86_64 host support** with KVM acceleration. The same `aq` CLI now runs on Ubuntu/Debian (and other Linux distros with `/dev/kvm`) as on macOS, picking qemu+KVM and a x86_64 Alpine guest at runtime via `uname`. macOS Apple Silicon continues using HVF and ARM64 Alpine.
- E2E smoke test (`tests/smoke.sh`) covering the full lifecycle: `new` → `start` → `exec` (arg + stdin forms) → `stop` → `rm`.
- GitHub Actions workflow on `ubuntu-latest` running the smoke test on every push, with apt and tio binary caching for ~2-minute warm runs.

### Internal

- Per-arch storage layout: `~/.local/share/aq/<arch>/{alpine-base,alpine-virt-iso,uefi-vars}`. Existing flat-layout installs are migrated automatically on first run.
- Runtime host detection (`detect_host`) sets `HOST_OS`, `ARCH`, `ACCEL`, `QEMU_BIN`, `MACHINE_OPTS`, `UEFI_CODE`, `UEFI_VARS_FLAVOR`. All `qemu-system-*` invocations parameterised.
- UEFI handling abstracted: `uefi-vars-sysbus` JSON on macOS, split pflash `.fd` (OVMF) on Linux. Dynamic OVMF firmware discovery (Ubuntu 22/24+ uses `OVMF_*_4M.fd`).
- `aq_start` now uses SSH polling (`wait_for_ssh`) instead of `wait_for` on the serial console. The installed Alpine doesn't need a serial getty for runtime; `first_boot_setup` runs over SSH. Serial console remains only inside `bootstrap_base_image`, which has to drive the live ISO's `setup-alpine` interactively.
- `bootstrap_base_image` writes `setup.conf` to the live ISO via a single-line base64 blob instead of a multi-line heredoc — busybox ash heredoc termination over the serial wire was unreliable on x86_64 (the terminator was not consistently recognised, leaving the shell stuck in a continuation prompt).
- `add_ssh_forward` is now race-resistant: switched from `nc -U` to `socat -t1` with retries on the QEMU monitor socket. Previously, after replacing the long serial wait with SSH polling, the immediate hostfwd command could be lost before qemu read it.
- Clear `/dev/kvm` access error on Linux pointing the user at the `kvm` group fix.

## 1.6.0 "The Tortoise" 16-Nov-2025

### Bug Fixes

- Fixed race condition where `aq exec` and `aq console` could run before first boot setup completed, causing APK database lock errors
- Fixed `first_boot_setup` not waiting for commands to complete before returning, ensuring APK operations finish before provisioning scripts run

## 1.5.2 16-Nov-2025

### Bug Fixes

- Fixed "LATEST_ALPINE_ISO_ASC: unbound variable" error in GPG signature verification

## 1.5.1 16-Nov-2025

### Improvements

- Updated Alpine Linux version from 3.22.1 to 3.22.2

### Bug Fixes

- Fixed "unbound variable" error when running commands without required VM name argument

## 1.5 "Batch" 19-Sep-2025

### Bug Fixes

- Fixed `aq scp` "stat local" error by using batch mode (-B) as default option

### Security

- Added GPG signature verification for Alpine Linux ISO downloads to ensure integrity

## 1.4 "Repellent" 16-Sep-2025

### Improvements

- Set VM hostname to the VM name on first boot
- Added clear error messages when attempting to operate on non-existent VMs

### Bug Fixes

- Fixed `aq scp` unbound variable error when no options are provided
- Added clear error message when attempting to start an already running VM
- Fixed `aq stop` error when attempting to stop a VM that was already powered off
- Made `aq stop` idempotent
- Fixed first boot automated setup being skipped due to failed login

## 1.3 "Polite" 16-Sep-2025

### Improvements

- `aq start` now always waits for the VM to boot: no surprises using `aq exec` or `aq console` right after `aq start`

## 1.2 "Sticky" 12-Sep-2025

### Improvements

 - VMs now use persistent SSH ports allocated on start and removed on stop
 - `aq ls` now displays SSH port information for running VMs

## 1.1.31 "Tinfoil" 12-Sep-2025

### New Features

 - `aq scp` command for copying files between host and VMs. Mimics the `scp` command

## 1.0 "Alpemu" 10-Sep-2025

First stable release of aq - a QEMU wrapper for running Alpine Linux VMs on MacOS.

### Core Features

Complete VM lifecycle management: `new`, `start`, `stop`, `rm`, `ls` commands.
Interactive console access: SSH-based console with dynamic port forwarding.
Script execution: Execute commands via stdin pipes or command-line arguments.
Automated VM listing: Table view showing VM names and running status.

### Preliminary Optimizations

VMs inherit (overlay) their storage from the common static base image to save host disk space.
Base image creation uses raw format with ext4 filesystem and tuned caching for faster bootstrap.
Base image size is kept to a minimum.
UEFI firmware is using a minimum possible space for vars.

### Developer Experience

Fast VM creation.
No need for an explicit static SSH port forwarding.
Essential 80% of workflows for local development with VMs.

### Technical Foundation

This release delivers a fully functional VM management tool optimized for development workflows on Apple Silicon Macs.

### Contributors

Phil Pirozhkov
