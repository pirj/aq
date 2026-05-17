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
- Per-VM disk size that differs from the base. Resizing within a fresh
  Alpine install is what we're avoiding; if the user needs a different size,
  they rebuild the base.
- Replacing ext4 with anything more economical. Among filesystems bundled in
  Alpine's virt ISO, nothing meaningful is gained.
- Custom init replacement (OpenRC stays).

## Architecture

### Default base size: 8 GB

The base image is pre-partitioned at 8 GB by default. This covers:

- Agent-only workloads (ai.rlock): comfortable headroom.
- Most CI shards and PR-isolation runs.
- Single-service docker-in-VM scenarios.

Heavier workloads (bakeri.sh with full docker stacks, ML pipelines with
local models) rebuild the base at a larger size via:

```
aq base rebuild --size=16G
```

Because qcow2 is sparse, declaring 8 GB instead of 4 GB costs only the
filesystem metadata overhead (~64 MB extra ext4 metadata for the larger
partition), not 4 GB of actual disk.

### Base image build

The existing flow installs Alpine via the virt ISO with `setup-alpine` and
shuts down with a small rootfs partition; the guest then runs `sfdisk` +
`resize2fs` on first VM boot.

The new flow:

1. Boot QEMU with the Alpine ISO and an empty disk **sized to the target
   base size** (8 GB by default, or `--size=N` if specified).
2. Run `setup-alpine` with disk options that create the rootfs partition
   **at full disk size** from the start — no later resize needed.
3. After install completes and SSH is reachable, while the guest is still
   running, extract the kernel and initramfs to the host:

   ```
   aq exec base 'cat /boot/vmlinuz-virt' > ~/.local/share/aq/<arch>/vmlinuz-virt
   aq exec base 'cat /boot/initramfs-virt' > ~/.local/share/aq/<arch>/initramfs-virt
   ```

   No host-side disk mounting (no `hdiutil`, no `losetup`) — pure file copy
   over SSH. Cross-platform by construction.
4. Shut down the base VM. The base.raw is now ready, and `vmlinuz-virt` /
   `initramfs-virt` live alongside it under `~/.local/share/aq/<arch>/`.

### `aq new` — direct kernel boot path (default)

1. Verify `~/.local/share/aq/<arch>/vmlinuz-virt` and `initramfs-virt` exist.
   If not (e.g. user has an old base predating this change), trigger
   `aq base rebuild` automatically with the default size.
2. Create the per-VM overlay qcow2 backed by `base.raw`. No `qemu-img
   resize` and no first-boot setup — base is already the right size.
3. Boot QEMU with direct kernel boot:
   - `-kernel ~/.local/share/aq/<arch>/vmlinuz-virt`
   - `-initrd ~/.local/share/aq/<arch>/initramfs-virt`
   - `-append "console=<console> root=/dev/vda3 rw quiet"` where
     `<console>` is `ttyS0` on Linux x86_64 (q35) and `ttyAMA0` on macOS
     aarch64 (virt). The console name comes from the per-arch detection in
     `detect_host()`. Partition number matches the layout produced by
     `setup-alpine` (`/dev/vda1` = EFI, `vda2` = swap, `vda3` = rootfs);
     see the layout-detection risk mitigation below.
   - No `-machine virt` UEFI args. No `-bios`, no `pflash`.
4. Wait for SSH (existing logic).

The skipped phases (UEFI bootloader + first-boot setup) account for the
target 13-15 seconds of savings.

### `aq new --skip-fast-boot` — legacy UEFI path

Same code path as today: UEFI firmware, OVMF vars, full ISO-aware boot
chain. Retained for debugging and as fallback when direct kernel boot has
issues (e.g. user pinned a non-`-virt` Alpine kernel manually).

### `aq base rebuild [--size=N]`

New subcommand. Equivalent to `rm ~/.local/share/aq/<arch>/base.raw` plus
the build flow above. Default size: 8 GB. The kernel/initramfs files are
overwritten as part of the build.

When invoked from a state where the base files already exist, prompts:

```
A base image already exists at ~/.local/share/aq/<arch>/base.raw (current size: 8G).
Rebuilding will remove it. VMs created from the existing base keep working
(qcow2 overlays embed the path), but new VMs will use the new base.
Continue? [y/N]
```

`-y` / `--yes` bypasses the prompt for scripted use.

### Disk-full error handling

When QEMU reports an IO error or the guest fills its rootfs, `aq` detects
it (via QEMU log scrape or guest exit code) and emits:

```
ERROR: VM 'foo' is out of disk space (current: 8 GB).
Two ways to fix:

 1. Expand THIS VM only (existing data preserved, just this VM affected):
      qemu-img resize ~/.local/share/aq/<arch>/foo/storage.qcow2 +8G
      aq exec foo "growpart /dev/vda 3 && resize2fs /dev/vda3"

 2. Expand for FUTURE VMs as well (rebuild the base):
      aq base rebuild --size=16G
      # existing VMs unaffected; new `aq new` uses the 16G base.

If many VMs are running the same workload and all need more space, prefer
option 2 — otherwise every new VM hits the same wall.
```

This is shown both on the failing operation's exit and stored in
`~/.local/share/aq/<arch>/<vm>/.last-error` for later reference.

### Snapshot compatibility

Existing snapshot mechanism (`aq snapshot create/ls/tree/rm`, `aq new
--from-snapshot=tag`) is untouched. Snapshots are still:

- **Cold** — `qemu-img convert` of a stopped VM's qcow2 disk.
- **Live** — `migrate -d -i file:` + memory dump + disk copy.

Both work with the direct-kernel boot flow because:

- The disk format is unchanged (qcow2 overlay over base.raw).
- The memory state is hypervisor-level, independent of how the kernel got
  loaded.

**Caveat:** live snapshots taken under the old UEFI base cannot be restored
under a new direct-kernel base (or vice versa). Cold snapshots restore fine
because they only carry disk state. This is documented in the snapshot
output:

```
Live snapshots are tied to the base image they were taken from.
Don't restore them across `aq base rebuild`.
```

`aq snapshot create` annotates the snapshot's `meta.json` with the base
image checksum. On `aq new --from-snapshot=tag`:

- If the snapshot is **cold** (no memory dump) and the base checksum
  differs from the current host base: print a warning and proceed.
  Restoration is safe; the new VM just uses a different kernel/initramfs
  than the snapshot was originally taken under.
- If the snapshot is **live** (has memory dump) and the base checksum
  differs: refuse with a clear error. Memory state is bound to the kernel
  that produced it. Suggested recovery: drop the live half (`aq snapshot
  create <tag>-cold ...` from a freshly-restored VM, or restore on a host
  that still has the matching base).
- Matching checksums: proceed silently.

## Implementation surface

Concrete changes to `aq` (the bash script):

| Area | Change |
|---|---|
| `detect_host()` | Add kernel/initramfs paths to the per-arch state. |
| Base build flow | Pre-size the install disk; extract kernel/initramfs via SSH at the end. |
| `aq base rebuild` | New subcommand wrapping the build flow with `--size` support. |
| `_aq_new_one()` | Branch on `--skip-fast-boot`: default → `-kernel`/`-initrd` args, no UEFI; legacy → existing UEFI args. |
| Disk-full detection | Wrap QEMU and `aq exec` failures with the actionable message. |
| Snapshot metadata | Record base checksum in `meta.json`; warn on mismatch in `aq new --from-snapshot`. |

Estimated diff: ~150-250 lines net change to `aq` (one file).

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
- **Live snapshot incompatibility across base rebuilds** — documented; warning
  emitted via `meta.json` mismatch.
- **`aq exec base 'cat /boot/foo' >` writes huge stdout** — initramfs is
  ~50 MB. Acceptable but the `aq exec` path must not corrupt binary data
  (PTY handling can mangle bytes). Use `aq scp` instead if `aq exec`
  pipeline proves unsafe; preferred form is `aq scp base:/boot/vmlinuz-virt
  $DEST/`.

## Out of scope (future TODOs)

- Multi-size base catalog (`base-4g`, `base-8g`, `base-16g` sitting side by
  side). Adds management overhead; defer until usage demands it.
- Firecracker / Cloud Hypervisor backend. Phase decision gate: measure
  warm-boot timings after this lands; if still >5s on macOS HVF and the
  user demand justifies it, evaluate alternative hypervisors then.
- Custom init replacement, hugepages, kvm-clock micro-opts. Sub-second-class
  gains; revisit after the big wins land.
- Caching the host's compiled OVMF firmware (irrelevant once UEFI is the
  fallback only).

## Measurement target

| Workload | Current | Target after this phase |
|---|---|---|
| `aq new` (no snapshot) | ~15-20 s | <3 s |
| `aq new --from-snapshot=tag` cold | ~10 s | <2 s |
| rlock warm `rl new docker-compose` end-to-end (after Step 0 baseline 30 s) | 30 s | <10 s |

The "rlock end-to-end" number folds in plugin-layer rebases and `aq start`
afterward. Sub-second is reserved for the eventual Firecracker phase or
memory-snapshot work.
