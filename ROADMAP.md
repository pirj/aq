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

### Concurrency

- [ ] **Multi-VM chain-walk incoming-migration timeout (seq-cold,
  second VM).** Found by snapcompose-benchmark Phase 3 walking-
  skeleton on 2026-06-02, run 26804727138, job 79019327924
  (`plus1 / cold / seq`). After the first VM (`main`) successfully
  walks its full chain (docker-engine → docker-compose →
  mise-base → ruby-runtime → ruby-bundler), the second VM (`node`)
  begins its own chain walk. At the docker-compose layer, after
  creating its own `cf1cfb...` snapshot, aq stages the
  concatenated memory.bin.zst of the live layers (here:
  docker-compose @ 267 MB + mise-base @ 371 MB = 1.25 GiB
  combined) and feeds it to QEMU via `-incoming exec:zstd -dc`.
  The migration completion poll then times out after 300×200 ms
  = 60 s with "Incoming migration did not apply".
  - The 60 s ceiling is hit BEFORE the migration completes —
    consumer is processing the stream, the timer is too tight
    for this payload size on ubuntu-latest. Either a) raise the
    poll budget proportional to the staged memory size, or
    b) replace polling with a QMP event-driven wait
    (`MIGRATION` event with `status: completed`).
  - **2026-06-02 update**: v2.5.46 (300+150/GiB) shipped the
    proportional-budget heuristic; v2.5.48 bumped it further to
    (900+600/GiB). snapcompose-benchmark run 26810957993 STILL
    tripped at 2100 polls (~7 min) for ~2 GiB incoming. The
    poll-budget approach is hitting diminishing returns under
    GH ubuntu-latest's hot-dockerd contention — 7 min for one
    migration apply suggests genuine consumer stall, not just
    a too-tight clock. Next step: implement option (b), the
    QMP `MIGRATION` event-driven wait. Polling for any longer
    is masking the underlying perf issue.
  - Sanity check: monolith/cold (one VM, same chain) completes
    successfully on the same runner. The trip is specific to the
    multi-VM "second VM walks its OWN chain after the first VM
    finished" pattern.
  - Until fixed, `+1 seq cold` in snapcompose-benchmark is
    reported as `✗ aq-incoming-timeout` per the methodology's
    cap-trip convention. seq/warm and par/warm are unaffected
    (cache hits don't replay the full chain build).

- [ ] **Concurrent base-image bootstrap race (par-cold from
  multiple `aq new` invocations).** Found by snapcompose-benchmark
  Phase 3 walking-skeleton on 2026-06-02. Symptom: when two `snapc
  run` processes execute simultaneously on an empty cache, both
  detect that `~/.local/share/aq/<arch>/base/...` is missing and
  both attempt `bootstrap_base_image`. The log shows two parallel
  wget downloads of `alpine-virt-...iso` (one ending in `.iso.1`,
  GNU wget's name-conflict suffix) and the boot path then exits
  2 mid-GRUB.
  - Repro: `(cd a && snapc run -- true) & (cd b && snapc run --
    true) &` with cleared cache, where `a` and `b` are snapcompose
    projects.
  - Failing run:
    https://github.com/pirj/snapcompose-benchmark/actions/runs/26804727138
  - Fix sketch: `flock` around the bootstrap entry point in
    `bootstrap_base_image()`. Second arrival should wait, observe
    base is now present, and skip its own bootstrap. Lockfile under
    `~/.local/share/aq/<arch>/base/.bootstrap.lock`.
  - Until fixed, `snapcompose-benchmark`'s par/cold cell is
    expected to trip and is reported as `✗ aq-race` per the
    methodology's cap-trip convention. Warm/par is unaffected
    (base is already cached on the warm path).

### QEMU tuning

- [-] `aio=native/io_uring` — DECLINED with measurement (see `docs/benchmarks/2026-05-19-aq-start-tuning.md`). Neither beats default `threads`+writeback on warm `aq start`; canonical `aio=io_uring,cache.direct=on` runs ~50 ms slower median. Warm boot is page-cache-dominated, not async-I/O-dominated.
- [-] `use cache=none` for normal runs, too? — DECLINED with measurement. `cache.direct=on` (== `cache=none` semantics for our reads) costs ~100–200 ms median by bypassing the page cache. Same benchmark doc.
- [-] adjust SMP — DECLINED with measurement. `-smp 2` is ~300 ms median *slower* than default 1 vCPU because Alpine OpenRC has `rc_parallel=NO`.
- [x] **zstd-compress live-snapshot `memory.bin`** — shipped 2026-05-19 (commit b28f881). After `migrate file:memory.bin` + qmp wait, run `zstd -T0 --rm memory.bin -o memory.bin.zst` when zstd is on the host. `aq new --from-snapshot` and `aq start` detect the `.zst` form and feed QEMU via `-incoming exec:zstd -dc <path>` so the decompressed stream lands in QEMU's migration consumer without a temp file. The rails-pg-sample 4 GiB-RAM capture went from 1,638 MiB to 472 MiB on disk (3.47×); warm cost ~370 ms vs `-incoming file:` (revised after ms-resolution re-baseline). Backward-compatible.
- [x] **`AQ_NO_SNAPSHOT_COMPRESS=1` env var to opt out of zstd** — shipped 2026-05-21, **superseded** by the `AQ_MEMORY_SNAPSHOT=raw` value of the unified enum in v2.5.35. Same semantics, different surface (one enum instead of two boolean flags with implicit precedence).
- [ ] **Postcopy live migration for warm restore (experimental, opt-in)** — gate behind `AQ_POSTCOPY=1`. Drops warm-restore wall-clock from ~1.1 s (post-R16 best on M3) to ~100–250 ms by resuming the destination VM on near-empty RAM and demand-paging the working set from a host-side source as the guest faults. Hardware/vmstate compatibility is identical to precopy (postcopy doesn't change the migration format, only the apply mechanism) — no new cross-host risks vs the existing path. Pre-implementation question: does QEMU postcopy work under macOS HVF (Linux KVM definitely does)? Full design + failure modes + RAM accounting + verification recipe + implementation plan in [`docs/specs/2026-05-27-postcopy-warm-restore-rfc.md`](docs/specs/2026-05-27-postcopy-warm-restore-rfc.md).
- [x] **Memory snapshot dedup via `zstd --patch-from`** — shipped aq v2.5.34 (save side) + rlock v0.1.6 (chain reconstruction). Unified into the `AQ_MEMORY_SNAPSHOT=zstd-patch` enum value in v2.5.35. Measured numbers (in aq's v2.5.34 CHANGELOG entry): 97 % saving at 1 % churn, 84 % at 5 %, 68 % at 10 %; restore cost +~1.7 s per chain step vs plain `zstd` mode on M3. Useful when OCI cache push size is the binding constraint and chain depth is shallow; plain `zstd` (the default) wins on wall-clock for deep chains.

**Note (not a checklist item): `cluster_size=64k,compression_type=zstd`.** The flag combo from earlier roadmap drafts no longer maps to actionable work. `cluster_size=64k` is already QEMU's default for qcow2 (verified via `qemu-img info` on any aq overlay). `compression_type=zstd` only affects clusters that were *explicitly* compressed (e.g. via `qemu-img convert -c`); normal writes stay uncompressed, so setting it on the overlay is a no-op for aq's workflow.

Where it *would* matter is converting the base from `.raw` to `qcow2` with `-c -o compression_type=zstd` — that cuts the on-disk base size roughly in half at the cost of CPU on every cold cluster read. Per the 2026-05-19 bench warm `aq start` is not disk-bound, so the trade-off is "disk space vs. CPU/cold-read latency" and the answer is workload-dependent (laptop on small SSD: maybe worth it; CI/cold storage: probably not). Document if a user reports a concrete need; not pursuing speculatively.

### Potential performance improvements (2026-05-29 research)

Catalogued from a 4-track research dive (QEMU snapshot internals, GH Actions cache, competitor warm-restore architectures, alt VM tech). Source: [`meta/2026-05-29-optimization-research-top10.md`](../meta/2026-05-29-optimization-research-top10.md). Not actively in flight — recorded so we don't re-derive when revisiting. Ranking is by ROI (save / cost), not order of attack.

- [ ] **QEMU `multifd-channels` for `-incoming file:`** — parallel mmap+vmstate-apply instead of single-threaded. Expected: M3 -400 to -500 ms warm, CI -300 to -800 ms warm. ~30-80 LoC in `aq_start`: switch `-incoming file:` to `-incoming defer` + QMP `migrate-set-capabilities multifd on; migrate-set-parameters multifd-channels 4; migrate-incoming "file:N:offset=..."`. Feature in QEMU since 8.2; works on M3 QEMU 10.0.3 today.
- [ ] **`mapped-ram` migration capability** — sparse fixed-offset RAM layout; multifd channels `pread()` non-overlapping regions in parallel. Largest single CI win: -1.5 to -2 s warm; M3 -300 to -500 ms. ~150 LoC for QMP recipe. **Blocked on CI QEMU bump to 9.0+**: ubuntu noble ships 8.2.2; mapped-ram landed in 9.0. Per user: first-priority item to ship once ubuntu-26.04 GH runners land (see [setup-snapcompose TODO](../setup-snapcompose/TODO.md)). [QEMU mapped-ram docs](https://www.qemu.org/docs/master/devel/migration/mapped-ram.html).
- [ ] **Pin `-machine pc-q35-N.N` / `virt-N.N`** — 0 ms today, but prevents 100 % cache-invalidation cliff when noble→26.04 bumps QEMU 8.2→9.x. 2 lines in `MACHINE_OPTS`. Pin to lowest common denominator across current CI + M3 (`pc-q35-8.2` + `virt-8.2` since CI runs 8.2.2 and M3 runs 10.0.3). Must precede any QEMU bump on either platform.
- [ ] **Postcopy migration (Linux/CI only)** — already RFC'd in [`docs/specs/2026-05-27-postcopy-warm-restore-rfc.md`](docs/specs/2026-05-27-postcopy-warm-restore-rfc.md); listed earlier in this section. Expected CI -1.5 to -2.5 s warm. macOS HVF cannot support — `userfaultfd` is Linux-kernel-only. Defer until multifd (above) + mapped-ram together don't hit target.
- [ ] **Working-set recording + prefetch (REAP / FaaSnap / Lambda SnapStart)** — after first warm of a project, record which guest pages got touched in the first 100-500 ms; store working-set bitmap alongside the snapshot; on next warm, prefetch only those pages (~100-200 MB sequential read vs 1.5 GiB full restore). Expected CI -1.5 to -3 s warm on second+ resume; M3 -200 to -400 ms. ~200-300 LoC. New artifact in the cache; working-set drift between runs is a known concern. Papers: [REAP (ASPLOS '21)](https://marioskogias.github.io/docs/reap.pdf), [FaaSnap (EuroSys '22)](https://wangziqi2013.github.io/paper/2023/01/29/faasnap.html), [Lambda SnapStart deep-dive](https://aws.amazon.com/blogs/compute/under-the-hood-how-aws-lambda-snapstart-optimizes-function-startup-latency/).
- [ ] **Kernel cmdline tweaks** — append `tsc=reliable clocksource=tsc nokaslr lpj=N` (and `mitigations=off` behind a dev-only flag) via the existing `AQ_KERNEL_APPEND_EXTRA` knob. Expected CI cold -100 to -200 ms (skips Linux TSC recalibration loop); CI warm -50 to -150 ms. ~5 LoC. Risk-free for `nokaslr` + `tsc=reliable`; `mitigations=off` is dev-only.
- [ ] **Live migration to pre-forked QEMU (`-incoming defer`)** — destination QEMU starts first, then `migrate-incoming` runs only after host-side pzstd decompress finishes. Lets `qemu_launch` (~60 ms M3) overlap with rlock's snapshot walk + hardlink staging. M3 -60 ms warm, CI -50 to -150 ms. ~50 LoC restructure of `aq_start`. Independent of multifd; both stack.
- [ ] **Serial-console READY marker** — alternative to SSH-probe for warm-restore readiness. Guest writes `READY\n` to `/dev/ttyS0` (or `ttyAMA0`); host watches the existing `-serial unix:` chardev. Replaces ~150 ms cross-host SSH probe wait. ~30 LoC host + ~5 LoC guest. Works on both HVF and KVM (vsock would be Linux-host-only — declined).
- [ ] **`-machine microvm` for x86 prebuild VMs** — drops ACPI/PCI; uses virtio-mmio. Saves ~300-500 ms cold qemu_launch (no firmware/edk2). x86-only (no aarch64 microvm) → portable to CI but not M3. ~150 LoC for an x86-only code path + ensure Alpine `linux-virt` kernel includes virtio-mmio drivers (it does). Conditional opt-in if we ever fork the cold path between platforms.
- [ ] **Diff snapshots between PR runs (QEMU changed-block-tracking + memory dirty bitmap)** — same project, two PRs, mostly identical RAM. Ship only the dirty pages over the wire. Firecracker has this as `--diff-snapshot` (developer preview); QEMU has the pieces (CBT for disk; `kvm-dirty-bitmap` for RAM) but needs glue. Bigger lift; pursue only if same-project CI repeat-rate is high enough to amortize. [LWN: QEMU CBT + differential backups](https://lwn.net/Articles/837053/).

#### Honorable mentions — track but don't actively pursue

- **s6-overlay or minimal init for prebuild VMs** — replaces OpenRC's sequential boot during the COLD base build. -800 to -1500 ms cold M3 / -1.5 to -3 s cold CI. Distro-level change (~300 LoC). Owned by snapcompose's base-image plumbing more than aq's; tracked in [snapcompose TODO](../snapcompose/TODO.md).
- **Custom Alpine kernel** — drop unused drivers, custom CONFIG. -200 to -400 ms cold per VM. Maintenance burden (kernel build pipeline per Alpine update) outweighs the win until everything cheaper is exhausted.
- **`-cpu host,enforce`** — DECLINED. Makes QEMU refuse to start when the host lacks a feature the model wants. On Azure-nested-KVM this bites randomly. `migratable=on` (already implied by `Skylake-Server-v4`) is the right choice.

#### Explicitly NOT pursuing (consensus across the 2026-05-29 research)

- **Switch from QEMU to Firecracker / Cloud Hypervisor.** Both kill the M3 HVF dev story. Firecracker has no qcow2 backing chain (regression for our cold cache layout). Cloud Hypervisor's I/O is ~35 % of QEMU per upstream issue. Orchestration rewrite dwarfs the ~100 ms saved on VMM startup. Revisit only after `rlock-server` is shipping and CI traffic dominates over dev.
- **gVisor / Kata containers.** Violates the VM-as-security-boundary threat model that's the cornerstone of the `auth-proxy` story (ai.rlock).
- **QEMU native `compress` / `compress-threads` migration capability.** Deprecated since 8.2, removed in 9.1. The `mapped-ram` + `multifd` combo above is the replacement.
- **LZ4 instead of pzstd for `memory.bin`.** Bench-verified on the M3 rails-pg-sample fixture: pzstd 251 ms vs lz4 567 ms decompress. pzstd's multi-frame format parallelizes across CPU cores; lz4's frame format doesn't. Slower AND larger output.

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
