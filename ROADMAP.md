# ROADMAP

- [x] Proof-of-Concept 0.1

## MVP 1.0

- [x] base image
- [x] fix uefi errors
- [x] fix disk IO slowness
- [x] fix base image OS installation race condition
- [x] remove juser? "juser password has changed" - comes from setup-file defaults
- [x] ln -s the uefi_vars, and make it read-only. vms should not modify it
- [x] use JSON file for uefi - doesn't have to be 67M. r-o base and copy
- [x] serial console -> ssh for `console` and `exec`
- [x] full on bash
- [x] fix stupid mistakes
- [x] use raw for the base image to improve bootstrap time
- [-] reduce base image size to a bare minimum (occupied is 133M) - fails under 500
- [x] guest: mkfs.fat -> ext4
- [x] remove setup.conf from root - rm didn't work
- [x] resize (up) the guest filesystem to match the guest storage size — obsoleted by Phase 2 (per-size base catalog + direct kernel boot, partitioned at full size from the start, no first-boot resize)
- [x] implement missing
- [x] allow plain commands to exec
- [x] write down decisions

## 1.x

- [x] reuse the same SSH forwarded port instead of allocating several
- [x] wait for the vm to boot
- [x] reduce boot time, 12s now (target was 2s) — direct kernel boot in v2.4.0 "Bolt" got `aq start` of a fresh VM to ~6.3s on macOS HVF. Sub-3s remains a stretch target; see "Sub-3s warm boot" below.
- [x] snapshots — cold (v2.2.0), live with memory (v2.2.0), fan-out (v2.3.0), boot_mode-aware live restore (v2.4.0)

### Still relevant in 1.x

- [ ] remove excessive output around aq console/exec; also the rest like first boot etc
- [ ] replace /etc/motd that suggests to set up the system
- [-] add --nowait option to "aq start" to skip waiting for system boot — IRRELEVANT: Use background jobs (&) and the wait command instead
- [-] add a special interim status "Booting" to aq_ls — meh, doesn't make sense to add a feature just for the sake of adding it
- [ ] check what happens to nc -U / tio when uncommenting getty for serial in /etc/inittab. Is it ttyS0 or ttyAMA0 ?
- [ ] stability improvements. sometimes fails on bootstrap
        alpine:~# > DISKOPTS="-m sys /dev/vda"
        -sh: can't create DISKOPTS=-m sys /dev/vda: nonexistent directory
        alpine:~#
      takes a while for vm to start and aq console <vm> fails until then
- [ ] detect occupied host ports during random port allocation
- [ ] alpemu.dev — starts with full-screen terminal, basic commands to start a machine, run something on it, and then more terminals spawn and like a few dozen. on scroll
- [ ] formula/tap. dependencies: tio! socat! qemu! zstd (image compression)?
- [ ] autotests — partial: `tests/` has smoke + snapshots + live-snapshots + fanout + direct-kernel-boot + size-base-catalog + skip-fast-boot + unit-helpers. CI runs them on GH; deeper coverage (snapshot prune, error paths, fanout edge cases) still missing.
- [ ] add error when console/exec stopped instance
- [ ] remove setup.conf for real
- [ ] clean up shell history - rm ~/.ash_history
- [ ] also use ext4 for the base's bootfs
- [ ] use cache=none for normal runs, too?
- [ ] further improve images performance cluster_size=64k,compression_type=zstd
- [ ] can be used as a backend for containers.dev? https://github.com/microsoft/vscode-remote-try-rust/blob/main/.devcontainer/devcontainer.json
- [ ] benchmarks/feature rundown vs Docker/Macpine/OrbStack/Podman/Virsh
  - [ ] https://github.com/panubo/docker-sshd Directly compare size, performance, isolation, configurability, reproducibility, horizontal scalability (more same machines), sharing data, startup time. Features: snapshots, overlays. Docker is an app container. aq is a system container
- [ ] bash completions
- [ ] add a doc section on troubleshooting: e.g.
  - socat STDIO UNIX:command.sock
  - UNIX:command.sock PTY,link=command.pty & && SOCAT_PID=$! && tio command.pty
- [ ] allow the user to select the SSH key to use
- [ ] .config/aq.toml for configuring the SSH key?
- [?] aio=native/io_uring - latter won't work, as it's Linux-only, what's the deal with native?
- [ ] fwd options: tcp/udp, hostaddr, guestaddr
- [?] adjust SMP - currently uses the default. is this fine for most cases?

### Deferred from spec reviews

Items pulled out of "Out of scope" sections in design docs so they don't slip through the cracks. Linked back to the spec that surfaced them.

#### `aq new --memory=NG` flag and live-snapshot RAM hotplug

Both prerequisites for `kind = "live"` snapshots being useful for Docker / heavy workloads. Tracked from `rlock/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md`.

- [ ] **`aq new --memory=NG`** — parallel to `--size=NG`. Per-VM choice at start time, not per-base. Distributions explicitly choose RAM (rlock's snapshot framework refuses live save without a pinned size). Live-snapshot `meta.json` records `ram_size_mb`; restore refuses on mismatch.
- [ ] **Memory hotplug for grow-after-restore.** Today's live snapshot binds the captured RAM size — restoring under a different `-m` fails in QEMU migration. To allow growing post-restore (without rebuild):
    - Source VM launched with `-m 1G,maxmem=8G,slots=4` (reserve headroom at start).
    - After `aq new --from-snapshot=<tag>` + `aq start`, host calls QMP `device_add memory-backend-ram,id=mem1,size=...` + `device_add pc-dimm,id=dimm1,memdev=mem1`. Guest sees hotplug event, kernel onlines the new pages.
    - `meta.json` also records `ram_max_mb` so consumers see headroom.
    - Surface as `aq new --from-snapshot=... --memory=4G` where the target size is `>= ram_size_mb` AND `<= ram_max_mb` of the snapshot.

  Defer until a `kind = "live"` consumer actually needs it. The framework enforcing same-size match is the safe default.

#### Base catalog management

From `aq/docs/specs/2026-05-17-direct-kernel-boot-design.md` out-of-scope.

- [ ] **`aq base prune`** — delete size-N bases that no VM or snapshot references. Trivial to add once the catalog gets cluttered.
- [ ] **`aq base prewarm <sizes...>`** — proactively build common sizes (e.g. during install) so the first `aq new --size=16G` doesn't pay the 30s install cost.
- [ ] **`aq snapshot prune`** policy refinement — live entries (~1-4 GiB each) should be the first to evict under disk pressure given their cost. See snapshot-kind spec "Out of scope / follow-ups".

#### Sub-3s warm boot

The Bolt release hit ~6.3s `aq start` (down from ~14s). The spec target was <3s. Closing the remaining ~3s gap (QEMU init ~2s + OpenRC startup ~2s) needs different classes of optimization. From `aq/docs/specs/2026-05-17-direct-kernel-boot-design.md` and `aq/docs/benchmarks/2026-05-18-direct-kernel-boot.md`.

- [ ] **Firecracker / Cloud Hypervisor backend** — decision gate after measuring warm-boot timings; if user demand justifies, evaluate alternative hypervisors. Depot.dev uses Cloud Hypervisor v51 with qcow2 + direct I/O. Out of scope until we measure rlock end-to-end and decide.
- [ ] **Custom init replacement** (skip OpenRC) — ~1-2s savings, ergonomic risk (no service supervision).
- [ ] **hugepages, kvm-clock micro-opts** — sub-second incremental wins.
- [ ] **Caching the host's compiled OVMF firmware** — irrelevant once UEFI is the fallback only.
- [ ] **Migrate to qcow2 base** (depot.dev pattern) — Out of scope; document only if a measured need surfaces. Different format means revisiting the raw-vs-qcow2 latency rationale.

### Use cloud images

Mention https://github.com/alpinelinux/alpine-make-vm-image - build images
https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images - build cloud images
 Pre-made arch qcow2 images https://gitlab.archlinux.org/archlinux/arch-boxes - more like tools to make images?

Consider https://alpinelinux.org/cloud/ again. how hard is it to build that IMDS metadata server that publishes the root pubkey to allow ssh?
https://gitlab.alpinelinux.org/alpine/cloud/tiny-cloud - tiny bootstrapper
> Tiny Cloud is also used for Alpine Linux's experimental "auto-install" feature.

! try again to boot a cloud qcow2 image. last time if failed somehow
! via serial console, create a /usr/lib/tiny-cloud/cloud/*aq*/imds file, and an autodetect, forward a socket to the guest, and extract add code to extract user-data and ssh_authorized_keys from that socket (no http, just yaml, base64 encoded: decode and parse with yx yaml parser)

### non-default MAC address

Multiple machines don't clash on the same MAC address
Might be needed for multiple machines to avoid duplicate MACs
    -device virtio-net-pci,netdev=net0,mac=56:c9:13:cf:18:a2 \
