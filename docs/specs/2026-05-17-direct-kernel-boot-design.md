# aq direct kernel boot + pre-partitioned base — Phase 2 design

## Problem

Two sources of overhead make `aq new` take 15-30 seconds even when downstream
consumers (like rlock) have a fully-cached snapshot ready to rebase onto:

- **UEFI + ISO install on cold base build** — initial Alpine install through
  the bootloader takes 10-20 seconds. While this is one-time per base, the
  bootloader phase also taxes every regular `aq new`: edk2 firmware spinup
  adds 3-5 seconds even when nothing is being installed.
- **First-boot partition resize** — the base image ships with a small (~213 MB)
  rootfs partition. Every fresh `aq new` runs `sfdisk` + `resize2fs` inside
  the guest to grow it to the per-VM disk size. Costs 5-10 seconds, runs on
  every cold VM creation.

Both costs apply even when the consumer immediately rebases the disk to a
cached snapshot — wasted work, every time.

## Goals

- Cut `aq new` wall-clock from ~15s to <2s on cache-hit and warm boot paths.
- Stay on QEMU (no new hypervisor). Cross-platform: macOS HVF and Linux KVM
  both benefit.
- Keep the legacy UEFI/ISO path reachable via `--skip-fast-boot` for
  debugging and fallback.

## Non-goals

- Firecracker, Cloud Hypervisor, or any other alternative hypervisor.
  Tracked separately as a future phase, gated by measurements after this one.
- In-place resize of an existing VM's disk to a larger size. If a VM
  needs more space, the path is `aq rm $vm && aq new --size=larger $vm`
  — recreate it from the appropriate size-N base. (Per-VM `qemu-img
  resize` + `growpart` is documented as a manual escape hatch in the
  disk-full error message, not as a first-class command.)
- Replacing ext4 with anything more economical. Among filesystems bundled in
  Alpine's virt ISO, nothing meaningful is gained.
- Custom init replacement (OpenRC stays).

## Architecture

### Per-size base catalog, lazy on-demand

There is no single "the base" — there is a **family of base images, one per
disk size used**, built automatically the first time a given size is
requested. Filename pattern:

```
~/.local/share/aq/<arch>/alpine-base-<ALPINE_VERSION>-<arch>-<SIZE>G.raw
```

Examples:
- `alpine-base-3.22.4-aarch64-8G.raw`
- `alpine-base-3.22.4-aarch64-16G.raw`

Every base file is pre-partitioned to its full declared size, with the
ext4 rootfs already grown to fill `/dev/vda3`. No first-boot resize.

`aq new` accepts `--size=N` (default `2G` — same as today's effective
size):

- If the size-N base exists: create overlay backed by it. Fast (no resize
  needed).
- If not: build it once (Alpine ISO install with partition forced to N),
  then create the overlay. Slow the first time, fast every subsequent
  `aq new --size=N`.

This naturally handles per-project size variation: rlock or bakeri.sh
workflows that need 16 GB pass `--size=16G`; agent-only workloads or
casual `aq new` invocations stay on the default 2 GB (matches today's
effective per-VM size, so existing callers are unaffected). Each size's
base is independent — adding a larger size does not invalidate caches at
smaller sizes, and snapshots taken under one size keep working as long
as their base file is present.

There is no `aq base rebuild`. The base catalog grows monotonically as
new sizes are requested. Garbage collection (`aq base prune` — delete
bases with no referring VMs/snapshots) is left as a future TODO.

### Base image build (one per (Alpine version, arch, size))

The existing flow installs Alpine via the virt ISO with `setup-alpine`
and shuts down with a small rootfs partition; the guest runs `sfdisk` +
`resize2fs` on first VM boot.

The new flow, triggered the first time `aq new --size=N` is called for a
size whose base file is missing:

1. Boot QEMU with the Alpine ISO and an empty disk **sized to N**.
2. Run `setup-alpine` with disk options that create the rootfs partition
   **at full N from the start** — no later resize needed.
3. The first time *any* size is built, also extract the kernel and
   initramfs to the host (they live alongside, not per-size):

   ```
   aq scp base:/boot/vmlinuz-virt ~/.local/share/aq/<arch>/vmlinuz-virt
   aq scp base:/boot/initramfs-virt ~/.local/share/aq/<arch>/initramfs-virt
   ```

   `aq scp` is preferred over `aq exec ... > file` for binary safety. No
   host-side disk mounting (no `hdiutil`, no `losetup`) — cross-platform
   by construction.
4. Shut down the base VM. The `alpine-base-<version>-<arch>-NG.raw` is
   now ready.

Kernel and initramfs are **per-arch, not per-size** — they come from the
same Alpine install regardless of partition geometry. Extracted once,
reused for every size.

### `aq new --size=N` — direct kernel boot path (default)

1. Resolve base path: `~/.local/share/aq/<arch>/alpine-base-<v>-<arch>-NG.raw`.
2. If missing: build it (Base image build flow above).
3. Verify `vmlinuz-virt` + `initramfs-virt` exist for this arch. (They
   will if any base build has completed; otherwise they're produced as
   part of step 2.)
4. Create the per-VM overlay qcow2 backed by the size-N base, with
   declared size N. No first-boot setup — partition is already at N.
5. Boot QEMU with direct kernel boot:
   - `-kernel ~/.local/share/aq/<arch>/vmlinuz-virt`
   - `-initrd ~/.local/share/aq/<arch>/initramfs-virt`
   - `-append "console=<console> root=/dev/vda3 rw quiet"` where
     `<console>` is `ttyS0` on Linux x86_64 (q35) and `ttyAMA0` on macOS
     aarch64 (virt). The console name comes from the per-arch detection
     in `detect_host()`. Partition number matches the layout produced by
     `setup-alpine` (`/dev/vda1` = EFI, `vda2` = swap, `vda3` = rootfs);
     see the layout-detection risk mitigation below.
   - No `-machine virt` UEFI args. No `-bios`, no `pflash`.
6. Wait for SSH (existing logic).

The skipped phases (UEFI bootloader + first-boot setup) account for the
target 13-15 seconds of savings — for every `aq new --size=N` after the
first per size.

### `aq new --skip-fast-boot` — legacy UEFI path

Same code path as today: UEFI firmware, OVMF vars, full ISO-aware boot
chain. Retained for debugging and as fallback when direct kernel boot
has issues (e.g. user pinned a non-`-virt` Alpine kernel manually).
Uses the small legacy base; ignores `--size`.

### Disk-full error handling

When QEMU reports an IO error or the guest fills its rootfs, `aq` detects
it (via QEMU log scrape or guest exit code) and emits:

```
ERROR: VM 'foo' is out of disk space (current: 2 GB).

To recreate this VM with more space:

  aq rm foo
  aq new --size=8G foo     # or 16G, 32G, etc.

If the requested-size base doesn't exist yet, this will build it once
(~30 s). Every subsequent aq new --size=8G is fast.

Per-VM resize (existing data preserved) is also possible but trickier:

  qemu-img resize ~/.local/share/aq/<arch>/foo/storage.qcow2 +6G
  aq exec foo "growpart /dev/vda 3 && resize2fs /dev/vda3"
```

This is shown on the failing operation's exit and stored in
`~/.local/share/aq/<arch>/<vm>/.last-error` for later reference.

### Snapshot compatibility

Existing snapshot mechanism (`aq snapshot create/ls/tree/rm`, `aq new
--from-snapshot=tag`) is untouched. Snapshots are still:

- **Cold** — `qemu-img convert` of a stopped VM's qcow2 disk.
- **Live** — `migrate -d -i file:` + memory dump + disk copy.

Both work with the direct-kernel boot flow because:

- The disk format is unchanged (qcow2 overlay over the size-N base).
- The memory state is hypervisor-level, independent of how the kernel got
  loaded.

Snapshots reference their backing base file by absolute path (the qcow2
header carries it). As long as `alpine-base-<v>-<arch>-NG.raw` still
exists for the size the snapshot was taken at, the snapshot restores
correctly under either direct-kernel boot or `--skip-fast-boot` (cold
snapshots) or under direct-kernel boot only (live snapshots — see below).

Because base files are **immutable per (Alpine version, arch, size)** —
no `aq base rebuild`, no in-place overwrite — there is no risk of a
snapshot's backing file changing content underneath it. The only failure
mode is the base file being missing entirely (e.g., user manually deleted
it, or moved hosts).

**Live snapshots restore only under direct-kernel boot.** A live snapshot
captures memory state of the kernel that produced it (direct-kernel boot
at base-build time). Restoring with `--skip-fast-boot` would boot a
different kernel (the UEFI/GRUB one), and the memory image would be
incompatible. `aq new --from-snapshot=tag --skip-fast-boot` therefore
refuses on live snapshots with a clear error.

## Implementation surface

Concrete changes to `aq` (the bash script):

| Area | Change |
|---|---|
| `detect_host()` | Add kernel/initramfs paths to the per-arch state. |
| `aq new` arg parsing | Accept `--size=N` (default `2G` — matches today's effective behavior). Validate against minimum (~1G). |
| Base path resolution | Compute `alpine-base-<v>-<arch>-NG.raw` from current Alpine version, arch, and requested size. |
| Base build flow | Triggered on missing size-N base. Pre-size the install disk to N; extract kernel/initramfs via `aq scp` once (only if not already present for this arch). |
| `_aq_new_one()` | Branch on `--skip-fast-boot`: default → `-kernel`/`-initrd` args, no UEFI; legacy → existing UEFI args + legacy small base. |
| Disk-full detection | Wrap QEMU and `aq exec` failures with the actionable message that points at `aq rm && aq new --size=larger`. |
| Snapshot restore | Refuse `--skip-fast-boot` on live snapshots with a clear error. Cold snapshots work either way. |

Estimated diff: ~200-300 lines net change to `aq` (one file).

## Risks and mitigations

- **Kernel ↔ guest userspace drift** — mitigated by extracting both kernel
  and initramfs from the same base build at the same time. Never use a
  kernel from one Alpine version with userspace from another.
- **Direct kernel boot args wrong for a given Alpine version** — pinning
  Alpine version in the base build (existing practice) makes regressions
  predictable. Retest on Alpine bumps.
- **`setup-alpine`'s partition layout assumed `vda3`** — if Alpine changes
  the layout, `-append root=/dev/vda3` breaks. Mitigation: detect the
  partition number from the live install (`blkid` / `lsblk -o NAME,TYPE`)
  and record it as part of base build metadata; pass at `aq new` time.
- **First `aq new --size=N` per new N is slow** — has to build the size-N
  base from scratch (Alpine install). ~30 s one-time cost per size. Every
  subsequent `aq new --size=N` is fast. Mitigation: surface a clear
  progress message ("Building 16G base image (one-time, ~30 s)...") so
  the user understands the wait. Sizes used in CI should be warmed in a
  setup job, not on the first hot path.
- **Binary file integrity over `aq exec | cat >`** — initramfs is ~50 MB
  and PTY handling can mangle bytes. Mitigation: use `aq scp
  base:/boot/vmlinuz-virt $DEST/`, which goes over SSH SFTP and is
  binary-clean by construction.

## Out of scope (future TODOs)

- **`aq base prune`** — delete size-N bases that no VM or snapshot
  references. Trivial to add once the catalog gets cluttered; leave for
  v1.x.
- **Firecracker / Cloud Hypervisor backend** — Phase decision gate:
  measure warm-boot timings after this lands; if still >5 s on macOS HVF
  and the user demand justifies it, evaluate alternative hypervisors
  then.
- **Custom init replacement, hugepages, kvm-clock micro-opts** —
  Sub-second-class gains; revisit after the big wins land.
- **Caching the host's compiled OVMF firmware** — irrelevant once UEFI
  is the fallback only.
- **Pre-warming base images for common sizes during `aq` install/setup**
  — would smooth the "first `aq new --size=16G` takes 30 s" rough edge.
  Optional; not blocking for v1.

## Measurement target

| Workload | Current | Target after this phase |
|---|---|---|
| `aq new` (no snapshot) | ~15-20 s | <3 s |
| `aq new --from-snapshot=tag` cold | ~10 s | <2 s |
| rlock warm `rl new docker-compose` end-to-end (after Step 0 baseline 30 s) | 30 s | <10 s |

The "rlock end-to-end" number folds in plugin-layer rebases and `aq start`
afterward. Sub-second is reserved for the eventual Firecracker phase or
memory-snapshot work.
