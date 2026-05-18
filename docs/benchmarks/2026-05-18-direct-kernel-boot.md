# aq direct kernel boot — Benchmark

**Date:** 2026-05-18
**Host:** Apple M3, Darwin 24.6.0 arm64, macOS / HVF acceleration
**QEMU:** 10.0.3
**Alpine version:** 3.22.2
**Base size:** 2 GB (default)

## Workload

`aq new --size=2G <vm-name>` followed by `aq start`. `time` measures the
`aq start` phase only (the `aq new` phase is sub-second on warm path —
just qcow2 overlay creation and bookkeeping).

## Timings

| Path | `aq start` wall-clock | Notes |
|---|---|---|
| Cold full build (`aq new --size=NG` for unseen N) | ~30-40 s | Includes Alpine ISO install, kernel/initramfs HTTP extraction, then VM start. Measured once during Task 4 implementation (kernel extraction validation). |
| **Warm direct kernel boot** | **~6.3 s** | Default path post Phase 2. `-kernel` + `-initrd`, no UEFI bootloader phase, no first-boot resize. |
| Legacy UEFI (`--skip-fast-boot`) | ~14.3 s | Pre-Phase-2 fallback. UEFI firmware + GRUB + installed kernel + first-boot script. |

Direct kernel boot is **~2.3× faster than legacy UEFI** on the warm path.

## Where the warm 6.3 s goes (approximate)

| Phase | Time | Notes |
|---|---|---|
| `aq new` (overlay create + write markers) | <1 s | Pure host-side bookkeeping. |
| QEMU spin-up + virtual hardware init | ~2 s | HVF setup, virtio device probing. |
| Direct kernel boot to userspace | ~2 s | Alpine `linux-virt` kernel, no bootloader. |
| OpenRC service start (sshd ready) | ~2 s | rc startup until sshd accepts connections. |
| Host `aq` waiting for SSH probe | ~1 s | The poll loop in `wait_for_ssh`. |

## Gap vs spec target

The spec (`docs/specs/2026-05-17-direct-kernel-boot-design.md`) targeted
**warm `aq new` < 3 s**. Measured 6.3 s. The gap (~3 s) is dominated by
QEMU init + OpenRC startup, both outside the boot-path optimization Phase
2 was scoped to.

To close it further, candidates from the spec's "Out of scope" section:
- `kvm-clock`, `quiet`, hugepages — sub-second incremental wins.
- Custom init replacing OpenRC — ~1-2 s savings, ergonomic risk.
- Pre-loaded VM-image snapshot via `qemu -incoming` (`aq snapshot create`
  with live memory) — sub-second restore is possible, but ties the
  snapshot to the kernel version.

## Cold full build

The Task 4 implementation work measured a fresh 2G base build at ~30-40 s
on this host: Alpine ISO download (cached), `setup-alpine` install,
`apk add busybox-extras` in the live ISO Alpine, `busybox-extras httpd`
serving `/target/boot`, host `curl` fetching ~20 MB of kernel + initramfs
through the QEMU `hostfwd` port, then poweroff.

Each new size adds another base build with the same ~30 s cost. The
kernel + initramfs are extracted on the first base build for a given
arch and reused across sizes thereafter.

## Decision

Phase 2 exit gate: warm `aq start` strictly less than legacy `aq start`.
**PASS** (6.3 s < 14.3 s).

Sub-3-second warm is not reached but is achievable in a follow-up; not
blocking on this phase landing.
