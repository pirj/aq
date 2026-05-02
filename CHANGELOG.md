# Changelog

## Unreleased

## 2.3.0 "Swarm" 2026-05-02

### New Features

- `aq new --from-snapshot=<tag> --count=N [prefix]` creates N VMs named `<prefix>-0` ... `<prefix>-(N-1)`, each backing onto the snapshot's `disk.qcow2`. Default prefix is `shard-$$` if omitted.
- `aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>` is the CI-style helper: builds the fleet, starts all shards in parallel, runs the user command in each shard with `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` set, multiplexes per-shard output with a `[shard-<name>]` prefix, waits for all to finish, aggregates exit codes (max), and tears the fleet down (unless `--keep`).

### Internal

- `aq_new` body refactored into a `_aq_new_one` inner function so the counted loop can call it without duplication.
- `aq_fanout` uses `awk` for line-prefixed output multiplexing (no per-line fork overhead); per-shard exit codes are written to mktemp files (with `>|` to bypass noclobber) and read back after `wait`. Each shard runs in a `set +e` subshell so a non-zero user exit doesn't skip writing the code.
- Per-shard env vars are propagated by piping `export …` lines plus the user command through `sh -s` over SSH. Inline `VAR=val cmd` doesn't work for `$VAR`-referencing commands because the parent shell expands `$VAR` before the assignment takes effect for the child.

### Limitations

- All shards share the same host directory tree (no cross-shard FS isolation beyond the per-VM qcow2 overlay).
- No CPU / memory caps per shard yet — relies on Linux KSM / macOS page cache to dedup the read-only snapshot pages across shards.

## 2.2.0 "Resume" 2026-05-01

### New Features

- `aq snapshot create` on a *running* VM now captures live memory state via QMP `migrate file:<path>`. The VM is paused for a few seconds during capture, then resumes. `meta.json` records `has_memory: true` and `memory.bin` lives next to `disk.qcow2` in the snapshot dir.
- `aq new --from-snapshot=<tag>` of a memory-bearing snapshot stages the memory file in the new VM dir as `incoming-memory.bin` (hard-linked, no copy on the same filesystem).
- `aq start` of a VM with `incoming-memory.bin` launches qemu with `-incoming "file:<path>"` and resumes at the snapshot point. Measured: SSH reachable in ~1 s vs ~12 s for a cold boot. The incoming file is consumed and removed by qemu; subsequent `aq start` boots cold from the now-up-to-date `storage.qcow2`.

### Internal

- Every running VM now exposes a QMP socket at `<vm-dir>/qmp.sock` alongside the existing readline HMP `control.sock`. New `qmp_hmp` and `qmp_send` helpers send commands; `qmp_wait_migrate` polls for completion of outgoing migration; `qmp_wait_migrate_incoming` polls for incoming application.
- After incoming migration, `aq start` issues HMP `cont` in a verify-and-retry loop because `cont` during the `inmigrate → paused` transition can no-op in some qemu versions.
- `qemu-img info` calls now use `--force-share` so `aq snapshot create` can read backing-chain metadata while qemu holds an exclusive write lock.

### Limitations

- After live restore, the guest clock has rewound to the snapshot moment. Programs sensitive to wall-clock time may misbehave until NTP catches up.
- `memory.bin` can be 100-300 MB on a freshly-booted Alpine; up to RAM size on a heavily-used VM. Storage planning is the operator's responsibility for now.

## 2.1.1 2026-05-01

### Bug Fixes

- Snapshot refcount is now computed on demand from authoritative state (VMs with `.from_snapshot` marker matching the tag, plus snapshots whose `meta.json` parent matches the tag). Previously, the count was kept in a `refcount` file that could drift under crashes, manual file edits, or concurrent operations — the dangerous failure mode being a stuck-zero count that let `aq snapshot rm` silently delete a snapshot still backing a live VM. Removing the cache eliminates the drift class entirely.

## 2.1.0 "Frozen" 2026-05-01

### New Features

- `aq snapshot create/ls/rm/tag/tree` for managing cold snapshots of stopped VMs. Snapshots store disk state under `~/.local/share/aq/snapshots/<arch>/<tag>/` and carry a `meta.json` (parent, source VM, base image, timestamps) and a refcount. Aliases under `tags/<arch>/<name>` are plain symlinks.
- `aq new --from-snapshot=<tag> [vm-name]` creates a new VM whose disk overlays a snapshot, skipping `first_boot_setup`. Multiple VMs can derive from one snapshot; their thin overlays only store deltas.
- `aq snapshot tree` visualises the backing chain as a forest rooted at the alpine base image.
- `aq rm <vm>` decrements the refcount on the snapshot a VM was derived from (if any), so `aq snapshot rm` can detect orphaned snapshots safely.

### Bug Fixes

- `aq stop` now syncs the guest filesystem over SSH before killing qemu, so disk writes from the most recent `aq exec` are durable. This was a long-standing latent issue that became visible when snapshotting (writes from the source VM would be missing in the snapshot).

### Internal

- New helper section in `aq` for snapshot directory layout, `meta.json` read/write, and refcount management. JSON is read with grep/sed (no jq dependency).
- Backing chains use absolute paths, so snapshots remain valid across host directory moves of the parent VM but not across machines.

### Limitations (Phase 2A)

- Snapshots are cold (disk only). Phase 2B will add live memory state for millisecond restore.
- `aq snapshot create` requires the source VM to be stopped.
- `aq snapshot rm` does not yet auto-clean parent snapshots whose refcount reaches 0; that is a deliberate Phase 5 decision.

## 2.0.0 "Crossing" 2026-05-01

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
