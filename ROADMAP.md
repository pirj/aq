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

## Pending

Flat backlog across all 2.x releases. Items group by theme, not by version — releases happen in small batches as related items land.

### UX polish

- [x] remove excessive output around `aq console`/`aq exec`; also first-boot waiter dots — v2.5.1 quietened the warm-boot SSH wait (`aq start` prints just `Started <vm>` on the fast path). First-boot dots already gone for v2.4.0+ VMs (no marker).
- [x] add error when `aq console`/`aq exec` is run against a stopped VM — v2.5.1 (also covers `aq scp`).
- [x] detect occupied host ports during random port allocation — v2.5.1 (`random_port` retries with `nc -z -w 1`).
- [x] bash completions — v2.5.2 ships `completions/aq.bash` covering subcommands, VM names from `$BASE_DIR`, snapshot tags, and `aq new` flags. Homebrew installs it automatically.
- [x] add a doc section on troubleshooting — v2.5.2 added a Troubleshooting section in README (stuck SSH wait, stopped-VM errors, port collision, snapshot mismatches, KVM/HVF env issues).

### Guest base cleanup

These all apply to the bootstrapped per-size base image. They are cosmetic; existing cached bases keep their current state until rebuilt.

- [x] replace `/etc/motd` — v2.5.3 writes an aq-specific banner at base-build time. Verified by `tests/guest-cleanup.sh`.
- [x] clean up shell history — v2.5.3 removes `/root/.ash_history` at the end of base build. Verified by `tests/guest-cleanup.sh`.
- [-] check what happens to nc -U / tio when uncommenting getty for serial in /etc/inittab — IRRELEVANT: `aq console` switched from serial to SSH long ago (see DECISIONS); getty on serial isn't on any code path.
- [x] remove `setup.conf` for real — `rm -f /target/root/setup.conf` runs during base bootstrap (v2.4.0 kernel-extract path).
- [-] also use ext4 for the base's bootfs — IRRELEVANT: direct kernel boot (v2.4.0 default) doesn't mount `/boot` as a separate fs; legacy UEFI path is a fallback only.

### Distribution

- [x] formula/tap — `brew install pirj/aq/aq` works on macOS and Linuxbrew via https://github.com/pirj/homebrew-aq. Deps: qemu, tio, socat, coreutils (shuf), wget, gnupg. Linux still needs system OVMF + KVM access (caveats note this).

### Configuration

- [ ] allow the user to select the SSH key to use
- [ ] `.config/aq.toml` for configuring the SSH key?
- [ ] fwd options: tcp/udp, hostaddr, guestaddr

### QEMU tuning

- [-] `aio=native/io_uring` — DECLINED with measurement (see `docs/benchmarks/2026-05-19-aq-start-tuning.md`). Neither beats default `threads`+writeback on warm `aq start`; canonical `aio=io_uring,cache.direct=on` runs ~50 ms slower median. Warm boot is page-cache-dominated, not async-I/O-dominated.
- [-] `use cache=none` for normal runs, too? — DECLINED with measurement. `cache.direct=on` (== `cache=none` semantics for our reads) costs ~100–200 ms median by bypassing the page cache. Same benchmark doc.
- [-] adjust SMP — DECLINED with measurement. `-smp 2` is ~300 ms median *slower* than default 1 vCPU because Alpine OpenRC has `rc_parallel=NO`.
- [x] **zstd-compress live-snapshot `memory.bin`** — shipped 2026-05-19 (commit b28f881). After `migrate file:memory.bin` + qmp wait, run `zstd -T0 --rm memory.bin -o memory.bin.zst` when zstd is on the host. `aq new --from-snapshot` and `aq start` detect the `.zst` form and feed QEMU via `-incoming exec:zstd -dc <path>` so the decompressed stream lands in QEMU's migration consumer without a temp file. The rails-pg-sample 4 GiB-RAM capture went from 1,638 MiB to 472 MiB on disk (3.47×); warm cost ~370 ms vs `-incoming file:` (revised after ms-resolution re-baseline). Backward-compatible.
- [x] **`AQ_NO_SNAPSHOT_COMPRESS=1` env var to opt out of zstd** — shipped 2026-05-21, **superseded** by the `AQ_MEMORY_SNAPSHOT=raw` value of the unified enum in v2.5.35. Same semantics, different surface (one enum instead of two boolean flags with implicit precedence).
- [ ] **Postcopy live migration for warm restore (opt-in)** — current restore loads the entire compressed `memory.bin.zst` before the VM resumes, which on rails-pg-sample at 4 GiB captured costs ~1.77 s of migrate phase on M3 (the dominant warm-restore line). QEMU's postcopy mode lets the destination resume immediately on a near-empty memory map and demand-page from the source/file as the guest faults — first SSH/exec into the resumed VM is slightly slower while the working set pages in, but the wall-clock to "VM resumed and accepting connections" drops to ~50 ms. End-to-end warm wall-clock on rails-pg-sample could plausibly fall from 2.78 s to ~1.0–1.3 s on M3 (depending on how much of the captured RAM the immediate workload actually touches). Implementation: add `qmp migrate-set-capabilities postcopy-ram on` before incoming, then `qmp migrate-start-postcopy` after the initial precopy handshake; source side becomes the live-snapshot's memory.bin acting as a userfault page source via a small fd-feeder. Gate behind `AQ_POSTCOPY=1` because (a) it changes the latency profile, not just wall-clock — workloads that immediately touch all of RAM see no win, and (b) cross-host warm (different physical machine restoring the cache) needs the source memory.bin file to stay accessible for the duration of the resumed VM's lifetime, which complicates the cleanup contract. Considered (and rejected) for v1: precopy + xbzrle — xbzrle is in-flight-only and our restore is file-based; multifd is in-flight only and decompresses from a single zstd stream which is already CPU-bound at one core; reducing memory.bin size via `--patch-from` (separate item above) is orthogonal and additive.
- [x] **Memory snapshot dedup via `zstd --patch-from`** — shipped aq v2.5.34 (save side) + rlock v0.1.6 (chain reconstruction). Unified into the `AQ_MEMORY_SNAPSHOT=zstd-patch` enum value in v2.5.35. Measured numbers (in aq's v2.5.34 CHANGELOG entry): 97 % saving at 1 % churn, 84 % at 5 %, 68 % at 10 %; restore cost +~1.7 s per chain step vs plain `zstd` mode on M3. Useful when OCI cache push size is the binding constraint and chain depth is shallow; plain `zstd` (the default) wins on wall-clock for deep chains.

**Note (not a checklist item): `cluster_size=64k,compression_type=zstd`.** The flag combo from earlier roadmap drafts no longer maps to actionable work. `cluster_size=64k` is already QEMU's default for qcow2 (verified via `qemu-img info` on any aq overlay). `compression_type=zstd` only affects clusters that were *explicitly* compressed (e.g. via `qemu-img convert -c`); normal writes stay uncompressed, so setting it on the overlay is a no-op for aq's workflow.

Where it *would* matter is converting the base from `.raw` to `qcow2` with `-c -o compression_type=zstd` — that cuts the on-disk base size roughly in half at the cost of CPU on every cold cluster read. Per the 2026-05-19 bench warm `aq start` is not disk-bound, so the trade-off is "disk space vs. CPU/cold-read latency" and the answer is workload-dependent (laptop on small SSD: maybe worth it; CI/cold storage: probably not). Document if a user reports a concrete need; not pursuing speculatively.

### Stability & testing

- [x] stability improvements on bootstrap — addressed across the 1.x/2.x line: MVP 1.0 fixed the install race, v2.4.0 dropped the first-boot resize/setup phase entirely (direct kernel boot at full size), v2.5.1 added a clear "VM is not running" guard so `aq console`/`exec` no longer races a half-booted guest. The leftover console-paste example in the previous wording was user error (a stray `>` on the typed command), not an aq bug.
- [x] autotests — `tests/` now covers smoke + snapshots + live-snapshots + fanout + direct-kernel-boot + size-base-catalog + skip-fast-boot + unit-helpers + guest-cleanup + stopped-vm-guard, all wired through `tests/run.sh` on GH Linux CI. Snapshot prune itself is a deferred feature (see "Base catalog management"), so its absence from tests reflects the absence of the command, not missing coverage.

### Comparative & marketing

- [ ] alpemu.dev — starts with full-screen terminal, basic commands to start a machine, run something on it, and then more terminals spawn and like a few dozen. on scroll
- [ ] can be used as a backend for containers.dev? https://github.com/microsoft/vscode-remote-try-rust/blob/main/.devcontainer/devcontainer.json
- [x] benchmarks/feature rundown vs Docker/Macpine/OrbStack/Podman/Virsh — shipped in `docs/comparison.md` (structured table across size / cold+warm start / isolation / configurability / reproducibility / horizontal scalability / data sharing / snapshot+overlay support / networking / platforms / daemon+rootless / licensing).
  - [x] **Measured medians (same runner, 100 ms probe, n=10 unless noted)**:
    - **Linux GH `ubuntu-latest` KVM**: aq_cold 6695 ms · aq_live 680 ms · docker_sshd 142 ms · podman_sshd 96 ms · virsh_start 16501 ms (n=5).
    - **Apple M3 HVF**: aq_cold 4163 ms · macpine_start 18461 ms.
    - **OrbStack**: not measured (requires GUI license acceptance on first run; GH `macos-latest` has no nested-virt anyway).
    - Bench is automated where possible: `.github/workflows/bench-vs-docker-sshd.yml` (aq cold + live, docker, podman) and `bench-vs-virsh.yml`. macpine numbers are local-M3 measurements; the GH `macos-latest` workflow was dropped because it has no HVF.

### Already declined

- [-] add `--nowait` option to `aq start` — Use background jobs (`&`) and the `wait` command instead.
- [-] add a special interim status "Booting" to `aq_ls` — doesn't justify the complexity.

### Bugs

#### Linux/KVM base-build hangs in Alpine ISO GRUB autoselect — fixed in 2.5.8

Surfaced 2026-05-21 by `pirj/bakerish-rails-pg-example`'s GH Actions
validation on `ubuntu-latest` runner. tio captured the Alpine ISO
GRUB menu rendering for 16+ min — the "1 second autoselect" never
fired.

Discriminated 2026-05-21 by a bare-qemu diagnostic workflow that ran
`qemu -accel kvm -cpu host -nographic -serial mon:stdio` against the
same Alpine ISO + OVMF on the same runner, with no tio/socat in the
loop: GRUB autoselected normally and Alpine booted to the
`localhost login:` prompt within 90 s. So the hang was not KVM/OVMF
— it was aq's own input.

Root cause: `bootstrap_base_image()` called
`wait_for 'write("\n"); expect("localhost login: "); ...'`. The
leading `write("\n")` was intended as a nudge in case the getty
prompt had been emitted before tio attached. But tio attaches
**immediately** after `qemu -daemonize` returns, and on the slow
firmware path (UEFI + GRUB on Linux/KVM took ~90 s end-to-end), the
`\n` arrived **during** GRUB's countdown. GRUB treats any keystroke
during autoselect as "cancel autoselect" — the menu then sat
forever, `expect("localhost login: ")` never matched.

macOS/HVF wasn't hit because the firmware path is fast enough there
that GRUB has already autoselected and handed off to the kernel
before tio's first `write()` fires.

Fix: drop the pre-emptive `\n` from line 460. Alpine's serial getty
emits `localhost login: ` on its own once spawned; tio is attached
long before then, so expect() matches the natural prompt without a
nudge.

Full validation writeup: `../validation-2026-05-21.md` in the umbrella
repo.

#### Live snapshot restore broken on QEMU 11.0.0 + aarch64 HVF — root-caused, upstream patch identified

Surfaced 2026-05-19 by the isolated live-vs-cold benchmark. `aq new --from-snapshot=<live-tag>` + `aq start` consistently failed on macOS aarch64 HVF with:

```
ERROR:target/arm/machine.c:1045:cpu_pre_load:
  assertion failed: (!cpu->cpreg_vmstate_indexes)
```

Linux KVM x86_64 is unaffected — different cpreg lifecycle.

**Min reproduce** (no aq, pure QEMU, ~70 lines): boot a tiny aarch64 guest under HVF, capture memory via QMP `migrate file:...`, spawn a fresh qemu with `-incoming file:...`. The destination qemu dies with the assertion before getting to any aq-managed step. (The reproducer script lived under `tools/qemu-livesave-repro/` between v2.5.6 and the one-line `git log` away once the user-facing workaround simplified to "just use QEMU 10.0.3"; recoverable from git history if needed.)

**Root cause** is a two-commit interaction:

- [`a1477da3dd`](https://gitlab.com/qemu-project/qemu/-/commit/a1477da3dd) (QEMU v6.2.0, late 2022): `hvf: Add Apple Silicon support`. Allocates `cpu->cpreg_vmstate_indexes` and `cpu->cpreg_vmstate_values` at vCPU init via `g_renew(...)`. At the time the precondition didn't exist, so the pre-allocation was harmless dead code.
- [`ab2ddc7b66`](https://gitlab.com/qemu-project/qemu/-/commit/ab2ddc7b66) (QEMU v11.0.0-rc0, March 2026): `target/arm/machine: Use VMSTATE_VARRAY_INT32_ALLOC for cpreg arrays`. Switches the cpreg vmstate arrays to migration-framework-managed allocation and adds `g_assert(!cpu->cpreg_vmstate_indexes)` as a precondition in `cpu_pre_load`. Authored by Eric Auger, reviewed/suggested by Peter Maydell.

The HVF Apple-Silicon path pre-allocates exactly the same field the new assert says must be NULL — so every aarch64 HVF live restore on QEMU 11.0.0 trips the assertion. Linux KVM doesn't pre-allocate (only `cpu_pre_save` would, and the destination doesn't run that), so KVM is fine.

**Upstream fix**: [`06fd39e426`](https://gitlab.com/qemu-project/qemu/-/commit/06fd39e426) `target/arm/hvf: Stop pre-allocating cpreg_vmstate arrays`, Scott J. Goldman, April 2026. Six lines, removes the HVF pre-allocation so the assert holds. On `master` only — **`stable-11.0` hasn't picked it up**, so a hypothetical 11.0.1 cut today would still ship the bug. Naturally lands in QEMU 11.1.0; an email to `qemu-stable@nongnu.org` could expedite a stable-11.0 backport.

**Verified locally on M3 HVF**:

| qemu | result |
|---|---|
| stock brew `v11.0.0` | assertion, qemu dies on `-incoming` |
| `v11.0.0` + cherry-pick of `06fd39e426` (rebuilt locally) | restore + resume succeed, `aq` bench: **645 ms median** (n=3, 6 ms spread), matches the Linux KVM 680 ms parity |
| brew Cellar `qemu/10.0.3` (predates the assertion) | restore + resume succeed, `aq` bench: **654 ms median** (n=3) — equivalent to the patched 11.0.0 result, no rebuild needed |

User-facing landing in aq:

- [x] Min reproduce written: 70-line script that uses pure qemu (no aq, no disk).
- [x] Verified the regression is QEMU-side, not aq-side (downgrade or cherry-pick + rebuild both fix it without any aq change).
- [x] aq surfaces the QEMU 11.0.0 / darwin / aarch64 combination with a hint pointing at the QEMU 10.0.3 PATH-prepend workaround, instead of letting the user puzzle through "Incoming migration did not apply after 300 polls".
- [x] README Troubleshooting documents the workaround: PATH-prepend the pre-existing `/opt/homebrew/Cellar/qemu/10.0.3` keg if `brew upgrade` left it around (no build, identical performance ~654 ms median on M3). The patched-build path existed briefly as `tools/qemu-livesave-repro/` (v2.5.6 only) and was removed once 10.0.3 was confirmed to be a drop-in workaround — too much carrying cost for a path no one would actually pick.
- [ ] **When QEMU 11.1.0 ships in homebrew-core** (or earlier if `06fd39e426` gets backported to stable-11.0 and a 11.0.x release picks it up):
  - Drop the avoid-11.0 warning from `README.md` (the callout block in Install + the macOS row in "When *not* to use aq" + the Troubleshooting subsection)
  - Drop the `(darwin, aarch64, qemu==11.0.0)` hint branch in `aq_start`'s migration-failure path
  - Bump aq's effective minimum QEMU to the fixed release in `CHANGELOG.md` / formula caveats
  - Confirm `tests/live-snapshots.sh` passes locally on macOS HVF with the new QEMU

`tests/live-snapshots.sh` still passes on Linux KVM CI (which is unaffected) and would fail on macOS HVF only on QEMU 11.0.0; the conditional skip is a follow-up nicety, not a blocker.

### Deferred from spec reviews

Items pulled out of "Out of scope" sections in design docs so they don't slip through the cracks. Linked back to the spec that surfaced them.

#### `aq new --memory=NG` flag and live-snapshot RAM hotplug

Both prerequisites for `kind = "live"` snapshots being useful for Docker / heavy workloads. Tracked from `rlock/docs/superpowers/specs/2026-05-18-snapshot-kind-design.md`.

- [x] **`aq new --memory=NG`** — shipped in v2.5.0 "RAM". `--memory=NG` parallel to `--size=NG`, live-snapshot `meta.json` records `ram_size_mb`, `aq new --from-snapshot=<live-tag>` auto-fills `--memory` from the snapshot or refuses on mismatch.
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
- [-] **Caching the host's compiled OVMF firmware** — IRRELEVANT since v2.4.0: UEFI is the `--skip-fast-boot` fallback only; direct kernel boot (the default) doesn't load OVMF at all.
- [ ] **Migrate to qcow2 base** (depot.dev pattern) — Out of scope; document only if a measured need surfaces. Different format means revisiting the raw-vs-qcow2 latency rationale.

### Use cloud images

- [-] **Boot Alpine cloud qcow2 images instead of running `setup-alpine`** — DECLINED post v2.4.0 "Bolt". The motivation in the original draft was to skip Alpine's installer (~15–20 s of the one-time per-size cold base build) by booting a pre-built cloud image and injecting an SSH key via an aq-side IMDS server + `tiny-cloud` in the guest.

  Direct kernel boot has since eaten most of the savings cloud images would have unlocked:

  - We already grab `vmlinuz-virt` + `initramfs-virt` directly from the installed base — kernel/initramfs already come from Alpine's stock packages, not from the installer's quirks.
  - `setup-alpine`'s output is consumed exactly once per *size*, then every subsequent `aq new --size=NG` reuses the cached base in <1 s. The ~20 s win is therefore one-time per size, not per VM.
  - Adding an IMDS shim + `tiny-cloud` would put a cloud-init-shaped pause on *every* warm boot (~1–2 s observed for tiny-cloud on similar setups), which is a regression on the path that matters most.
  - Resize ergonomics also clash: cloud images ship at a fixed virtual size, while the per-size catalog (v2.4.0) wants partitioned-at-full-size bases per requested `--size`.

  Worth revisiting only if someone (a) really cares about the per-size cold first build and (b) is willing to pay 1–2 s on every warm `aq start` to get it. Links kept for the archaeology:

    - https://github.com/alpinelinux/alpine-make-vm-image — image builder
    - https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images — official cloud-image pipeline
    - https://gitlab.alpinelinux.org/alpine/cloud/tiny-cloud — minimal cloud-init replacement
    - https://gitlab.archlinux.org/archlinux/arch-boxes — Arch-flavoured equivalent

### Networking

- [-] **non-default MAC address** — IRRELEVANT for the current `-nic user,...` (SLIRP NAT) topology: every VM gets its own isolated user-mode network, so MACs never share a broadcast domain. Would become relevant only if aq grows a bridged/tap-backed mode where multiple VMs share an L2 segment; revisit then.
