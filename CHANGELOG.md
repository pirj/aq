# Changelog

## 2.5.4 "Probe" 2026-05-19

### Performance

- **`wait_for_ssh` probe cadence 2 s → 0.5 s** (and `ConnectTimeout` 2 s → 1 s). Warm `aq start` no longer pays up to 2 s of dead-wait between SSH probes when the guest comes up mid-interval. Measured: on GH `ubuntu-latest` Linux/KVM, median `aq start` dropped from ~8 250 ms → ~6 900 ms (n=10) — a ~1.3 s shave per invocation. Total budget unchanged (~3 min, 360 attempts × 0.5 s). New env var `AQ_SSH_PROBE_INTERVAL` lets benchmarks override further.

### Tooling

- **Benchmark harness.** `tests/bench-aq-start.sh` runs warm `aq start` N times, reports min/median/max in ms. Backed by four passthrough env-var hooks in `aq_start` (production VMs leave them unset):
  - `AQ_DRIVE_EXTRA` — appended to the `-drive` directive
  - `AQ_QEMU_EXTRA_ARGS` — extra raw QEMU args
  - `AQ_MACHINE_OVERRIDE` — replaces `$MACHINE_OPTS`
  - `AQ_KERNEL_APPEND_EXTRA` — extra tokens for `-append`
- **`Bench (Linux warm aq start)` CI workflow** sweeps a fixed configuration grid on push (when `aq` or the bench script changes) and on workflow_dispatch. Markdown summary on the run page; `bench.tsv` uploaded as an artifact.

### Tests

- **`tests/stopped-vm-guard.sh`** locks in the v2.5.1 guard: `aq console` / `aq exec` (arg + stdin) / `aq scp` against a stopped VM must reject with `is not running` and exit non-zero within seconds, not hang on a refused SSH connect.

### QEMU tuning (DECLINED with data)

Used the new bench infra to settle three lingering questions:

- **`aio=io_uring` / `aio=native`** — neither beats the QEMU defaults (`threads` + writeback cache). Canonical `aio=io_uring,cache.direct=on` is ~50 ms median *slower*; `aio=native,cache.direct=on` ~100 ms slower. Warm boot is page-cache-dominated; async I/O has nothing to speed up.
- **`cache=none` / `cache.direct=on`** — ~100–200 ms median slower. Bypassing the host page cache is the wrong move for a workload that re-reads the same blocks every boot.
- **`-smp 2`** — ~300 ms median slower. Alpine OpenRC has `rc_parallel=NO`, so a second vCPU adds coordination overhead without unlocking parallel boot work.
- **Kernel cmdline `tsc=reliable no_timer_check nokaslr`** — within noise of baseline.

Full data in `docs/benchmarks/2026-05-19-aq-start-tuning.md`. Corresponding roadmap entries moved to declined.

## 2.5.3 "Tidy" 2026-05-19

### Guest base cleanup

The bootstrapped per-size base image now ships tidier:

- **`/etc/motd`** is replaced with an aq-specific banner (the stock Alpine motd suggested running `setup-alpine`, which is misleading once aq has finished the install).
- **`/root/.ash_history`** is removed at the end of base build so newly minted VMs don't inherit the install session's command history.
- **`/root/setup.conf`** removal (already in place since v2.4.0) now lives next to the other cleanups as one chained guest-side command.

All three apply to *new* base builds. Existing cached bases keep their current state until rebuilt (`rm ~/.local/share/aq/<arch>/alpine-base-*.raw` to force a rebuild).

### Tests

- New `tests/guest-cleanup.sh` boots a fresh VM and verifies the three cleanups above. Wired into `tests/run.sh` after `skip-fast-boot.sh`.

## 2.5.2 "Tap" 2026-05-19

### Distribution

- **Homebrew tap.** `brew install pirj/aq/aq` now installs from a real tap (https://github.com/pirj/homebrew-aq), pulling `qemu`, `tio`, `socat`, `coreutils` (for `shuf`), `wget`, and `gnupg` as deps. Works on macOS and Linuxbrew; Linux still needs system OVMF + KVM access (the formula's caveats spell this out).
- **Bash completions.** `completions/aq.bash` covers subcommands, VM names from `$BASE_DIR`, snapshot tags, and `aq new` flags (including `--from-snapshot=` completion against existing tags). Homebrew installs it automatically; for manual installs, source the file or drop it into `~/.local/share/bash-completion/completions/aq`.

### Docs

- **Troubleshooting section in README** covering stuck SSH wait, stopped-VM errors, port collision, live-snapshot RAM/boot-mode mismatches, KVM access on Linux, and HVF reinstall after macOS updates.
- **Install section restructured** — "Homebrew (macOS or Linux)" is now the primary path; "Linux (Debian/Ubuntu) without Homebrew" remains as the source-build alternative.

## 2.5.1 "Polish" 2026-05-19

### UX

- **`aq console` / `aq exec` / `aq scp` against a stopped VM** now fails fast with `Error: VM '<name>' is not running. Start it with: aq start <name>` instead of hanging on a refused SSH connect.
- **Quieter warm-boot path.** `aq start`'s SSH waiter no longer prints `Waiting for SSH...` / `SSH ready after N attempts.` when the guest comes up in the typical ~1-3 attempts. Slow boots still get the "Waiting for SSH..." narration after ~10 s plus the existing heartbeat every 20 s.
- **Random port collision detection.** `random_port` now retries (up to 20 times) and uses `nc -z -w 1 127.0.0.1 <port>` to avoid handing back a port already in use on the host. Affects `get_persistent_ssh_port` and the base-build kernel-extract port. Previously a clash silently broke `aq start` (QEMU's hostfwd bind would fail).
- **Drop stale "Batch" codename** from `aq --version`. Codename churns per release (Bolt, RAM, Polish, ...); printing only the version number is more honest than embedding the wrong one.

## 2.5.0 "RAM" 2026-05-19

### New Features

- **`aq new --memory=NG`** — per-VM RAM size, parallel to `--size=NG`. Default is 1G (matches the prior hardcoded value, so existing callers are unaffected). Docker / heavy workloads should pass `--memory=4G` or higher.
- **Live-snapshot RAM-size pinning.** Snapshots created with memory (live snapshots) now record `ram_size_mb` in `meta.json`. `aq new --from-snapshot=<tag>` reads it and:
  - Auto-fills `--memory` from the snapshot when the user didn't specify, so `aq new --from-snapshot=warm-4g foo` "just works" without remembering the size.
  - Refuses `--memory` mismatches with a clear error instead of letting QEMU's `-incoming` migration fail opaquely.
- **Per-VM `.memory` marker** in `$BASE_DIR/<vm>/`. Read by `aq start` to set QEMU's `-m`. Adds to the existing `.size` / `.boot_mode_*` markers.

### Internal

- `parse_memory_arg` helper alongside `parse_size_arg` (same `NG` integer-suffix grammar).
- `parse_new_args` gains `--memory=NG` / `--memory NG` (long and equals forms). `NEW_MEMORY` is left empty when the user doesn't pass `--memory`, so `_aq_new_one` can distinguish "default to 1G" from "auto-pick from snapshot".
- `write_meta` accepts an optional `ram_size_mb` 7th positional, emitted as a JSON number (not string).
- `read_meta` gains a `ram_size_mb` case for number-valued fields.
- `aq_start` reads the VM's `.memory` marker and passes `-m ${N}G` to QEMU. VMs from before this release have no marker and fall back to 1G.

### Known limitations

- **No memory hotplug after restore.** Live snapshots bind the captured RAM size; growing memory post-restore would require launching the source VM with `-m N,maxmem=M,slots=K` and using QMP `device_add pc-dimm` after `-incoming`. Tracked in `ROADMAP.md` under "--memory=NG flag and live-snapshot RAM hotplug" as a deferred follow-up.
- **Snapshots from < v2.5.0** have no `ram_size_mb` field and are treated as size-agnostic. The framework refuses live restores only when the snapshot explicitly records a size that differs from the requested `--memory`.
- The base-build VM still uses hardcoded `-m 1G`. The `--memory` flag controls user VMs only, not base bootstrapping.

## 2.4.0 "Bolt" 2026-05-18

### New Features

- **Per-size base catalog.** `aq new --size=NG` accepts arbitrary disk sizes; the corresponding `alpine-base-<version>-<arch>-NG.raw` is built on demand the first time a new size is requested, then reused for every subsequent `aq new --size=NG`. Each size's base is independent — adding a larger size does not invalidate caches at smaller sizes. Default `--size=2G` matches the prior effective size, so existing callers are unaffected.
- **Direct kernel boot** is the new default for `aq new` / `aq start`. The size-N base is pre-partitioned at full size, so `setup-alpine`'s small partition + first-boot `sfdisk` + `resize2fs` round-trip is eliminated. QEMU launches with `-kernel <vmlinuz-virt>` + `-initrd <initramfs-virt>` extracted from the installed Alpine at base-build time; no UEFI bootloader phase, no GRUB. Measured: `aq start` for a fresh VM drops from ~14 s (legacy UEFI + first-boot setup) to ~6 s on Apple M3 with HVF, a ~2.3× speedup. The legacy UEFI path remains available via `aq new --skip-fast-boot`.
- **`aq new --skip-fast-boot`** flag for opting back into UEFI/edk2 + bootloader chain. Kept for debugging and as a fallback when direct kernel boot has issues.
- **Snapshot meta.json now records `boot_mode` and `base_image`.** Live snapshots refuse to restore under a different boot mode than the one that captured them — memory state is tied to the kernel. Cold snapshots restore freely.
- **Actionable disk-full error message.** `aq exec` detects ENOSPC in command output and prints a recreate-with-larger-size path (`aq rm $vm && aq new --size=8G $vm`), with an in-place resize fallback documented.

### Bug Fixes

- Kernel extraction during base build no longer depends on `apk add busybox-extras` in the live ISO. Replaced with plain busybox `tar c | nc -l -p 8080` on the guest side and `nc | tar x` on the host. Works on GH x86_64 runners where the prior `busybox-extras httpd` path failed silently.

### Internal

- `_aq_new_one`'s overlay `qemu-img create` no longer hardcodes 2G; the virtual size now defaults to the backing image's size (pre-partitioned size-N base or snapshot's disk).
- New per-VM markers in `$BASE_DIR/<vm>/`: `.size` (integer GB), `.boot_mode_direct` or `.boot_mode_uefi`. Used by `aq_start`'s boot-path selection and by the disk-full helper for size lookup.
- New helpers: `parse_size_arg`, `compute_base_filename`, `alpine_base_for_size`, `emit_disk_full_help`.
- `aq_new` arg parsing extracted into `parse_new_args` setting `FORWARDS / FROM_SNAPSHOT / COUNT / NEW_SIZE / SKIP_FAST_BOOT / VM_NAME`.
- Source-only mode via `__AQ_SOURCED_ONLY=1 source ./aq` lets tests exercise pure-logic helpers (`tests/unit-helpers.sh`).

### Tests

- `tests/unit-helpers.sh` (new) — unit coverage for size parsing, filename composition, `parse_new_args`.
- `tests/direct-kernel-boot.sh` (new) — verifies default-path VM boots via `-kernel`/`-initrd`, no resize2fs in dmesg, `/dev/vda3` is rootfs.
- `tests/size-base-catalog.sh` (new) — verifies that two VMs at the same `--size=N` share an existing size-N base and both boot.
- `tests/skip-fast-boot.sh` (new) — verifies legacy UEFI path under `--skip-fast-boot` and marker file placement.
- `tests/run.sh` wires the new suites alongside `smoke`, `snapshots`, `live-snapshots`, `fanout`.

### Known Limitations

- The first `aq new --size=NG` per new N costs the full Alpine install + kernel extraction (~30–60 s). Every subsequent `aq new --size=NG` is fast. Pre-warming common sizes is a future option.
- aq guests are still hardcoded to `-m 1G`. Docker workloads commonly need more; a `--memory=NG` flag parallel to `--size` is queued as a follow-up.
- Live snapshots from before this release have `boot_mode = unknown` and are accepted as cold-snapshot-compatible only; create fresh live snapshots after upgrade.

## 2.3.1 2026-05-03

### Bug Fixes

- `bootstrap_base_image` no longer waits for a sentinel after the post-install cleanup heredoc. After `setup-alpine` completes, leftover output from kernel messages, `udhcpc` lease renewals, and apk progress-bar carriage returns can flood the serial input loop, with the live ISO shell echoing them back as `-sh: ^M: not found` indefinitely. The wait_for would never see the cleanup sentinel, hang, and cause the bootstrap to time out. The cleanup is now best-effort with a short sleep instead — if the rm/umount didn't land, the only consequence is a stale `/root/setup.conf` in the installed VM (cosmetic).

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
