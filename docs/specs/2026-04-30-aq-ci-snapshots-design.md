# aq CI snapshots — design

**Date:** 2026-04-30
**Status:** Approved
**Owner:** Phil Pirozhkov

## Goal

Make aq genuinely useful in CI workflows where dependency installation and per-job overhead dominate wall-clock time. Position aq as the fastest path from "I need an isolated environment with this provisioned state" to "tests are running" — measured in hundreds of milliseconds, not tens of seconds.

Success metric: a public, reproducible benchmark on a real OSS project showing aq+snapshots replacing docker-compose in CI with a multi-minute wall-clock saving, picked up by at least a handful of teams.

## Non-goals

- A general-purpose VM management product. aq stays opinionated and small.
- Multi-host orchestration, distributed fan-out, Kubernetes integration.
- Cross-architecture snapshot portability (Mac aarch64 ↔ Linux x86_64).
- Replacing Docker for application packaging. aq is for environments, not artifacts.
- A backend abstraction layer in v1. Single backend (qemu) until a second is needed.
- Declarative manifest (`aq.toml`, `AQ_FACTORS`) in v1. Bash composition first; semantics emerge from real use.

## Architecture

Three layers. Each builds on the previous and is independently shippable.

```
┌─────────────────────────────────────────────────────────┐
│  CLI: aq new/start/stop/exec/...  (unchanged)           │
│  +    aq snapshot create/restore/ls/rm/tag/tree         │
│  +    aq new --from-snapshot=<tag> [--count=N]          │
│  +    aq fanout <tag> <N> -- <command>                  │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│  Layer 2: Snapshot subsystem                            │
│   - tag → snapshot resolution                           │
│   - locally indexed cache (~/.local/share/aq/snapshots) │
│   - dedup via qcow2 backing chain (parent/child)        │
│   - refcount + GC                                       │
│   - tree visualisation                                  │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│  Layer 1: Host abstraction (minimal)                    │
│   - macOS  → qemu + HVF + ARM64 Alpine guest            │
│   - Linux  → qemu + KVM + x86_64 Alpine guest           │
│   - one codepath, ~5 env vars (QEMU_BIN/ACCEL/ARCH/…)   │
└─────────────────────────────────────────────────────────┘
```

### Key decisions

- **No backend interface.** qemu is the only backend. Differences between macOS and Linux reduce to a small number of variables. Backend abstraction is YAGNI until firecracker is real.
- **Snapshots are arch-specific.** `~/.local/share/aq/snapshots/{aarch64,x86_64}/...`. Cross-arch transfer is not supported. Dev and CI normally run in the same arch; emulation across would defeat the perf win.
- **Snapshot format = qcow2 overlay + memory file.** Native qemu `savevm`/`loadvm` path. No custom converters.
- **Fan-out via backing chain.** One snapshot serves as backing for N thin overlays. Disk usage is `O(N × delta)`, not `O(N × full)`. Memory is shared via mmap so RAM usage is `base + N × delta`.

## Layer 1 — Linux host support

Goal: aq runs on Linux x86_64 + KVM with the same CLI as on macOS. macOS path unchanged.

### Runtime detection

Performed once at startup:

```bash
case "$(uname -s)" in
  Darwin) HOST_OS=darwin; ARCH=aarch64; ACCEL=hvf;
          QEMU_BIN=qemu-system-aarch64;
          MACHINE="virt,highmem=on";
          UEFI_CODE="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" ;;
  Linux)  HOST_OS=linux;  ARCH=x86_64;  ACCEL=kvm;
          QEMU_BIN=qemu-system-x86_64;
          MACHINE="q35";
          UEFI_CODE="/usr/share/OVMF/OVMF_CODE.fd" ;;
esac
```

### Guest image

- macOS: `alpine-base-3.22.2-aarch64.raw` (current behavior).
- Linux: `alpine-base-3.22.2-x86_64.raw` (new bootstrap path; same setup-alpine flow with x86_64 ISO).
- Storage: `$BASE_DIR/$ARCH/alpine-base-...raw`. Per-arch subdirectory.

### Bootstrap differences

- ISO source: `dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-virt-3.22.2-x86_64.iso` on Linux.
- UEFI vars: `OVMF_VARS.fd` copy on Linux; existing edk2 vars on macOS.
- KVM permissions: aq prints a clear error if `/dev/kvm` is unreadable, with hint about adding the user to the `kvm` group.

### Networking

User-mode networking is identical on both hosts. `-nic user,hostfwd=tcp::PORT-:22`. No changes.

### Dependencies

| Host  | Packages                                                |
|-------|---------------------------------------------------------|
| macOS | `qemu`, `tio`, `socat`, `wget`, `gpg` (brew)            |
| Linux | `qemu-system-x86`, `tio`, `socat`, `wget`, `gpg`, `ovmf` (apt/dnf/apk) |

### CI

A new `.github/workflows/ci-linux.yml` runs the full e2e suite on `ubuntu-latest`. This validates Linux support continuously and doubles as a public demonstration that aq works in GitHub Actions.

**Risk:** GitHub-hosted runners must expose `/dev/kvm`. This has been available since 2023 on Linux runners but should be verified empirically at the start of Phase 1. Fallback: TCG (slower, no acceleration) or self-hosted runner for aq's own CI.

## Layer 2 — Snapshot subsystem

### CLI

```
aq snapshot create <vm-name> <tag>
    Snapshot a running VM. <tag> is a human-readable name (e.g.
    "deps-abc123" or "rails-migrated"). The original VM continues
    running.

aq snapshot ls
    Table: tag, parent, arch, size, created, last-used.

aq snapshot rm <tag> [--force]
    Refuses to remove a snapshot with refcount > 0 unless --force.

aq snapshot tag <existing-tag> <new-tag>
    Creates an alias for an existing snapshot. Useful for indirection
    ("latest-deps" → "deps-abc123").

aq snapshot tree [<tag>]
    Visualise the backing chain. Without an argument: all trees in
    the current architecture. With an argument: subtree from <tag>.

aq new --from-snapshot=<tag> [--count=N] [vm-name]
    Restore one or N VMs from a snapshot. VM is in the running state
    at first SSH attempt.
```

### Cache layout

```
~/.local/share/aq/
├── alpine-base-3.22.2-aarch64.raw           # base image (per-arch)
├── alpine-base-3.22.2-x86_64.raw
├── snapshots/
│   ├── aarch64/
│   │   ├── deps-abc123/
│   │   │   ├── disk.qcow2          # overlay over base or parent snapshot
│   │   │   ├── memory.bin          # qemu memory snapshot
│   │   │   ├── meta.json           # parent, created, vm-config, base hash
│   │   │   └── refcount            # int, atomically updated
│   │   └── rails-migrated-def456/
│   │       ├── disk.qcow2          # backing_file → deps-abc123/disk.qcow2
│   │       ├── memory.bin
│   │       ├── meta.json
│   │       └── refcount
│   └── x86_64/
│       └── ...
└── tags/
    ├── aarch64/
    │   ├── latest-deps -> ../snapshots/aarch64/deps-abc123/
    │   └── ci-base -> ../snapshots/aarch64/rails-migrated-def456/
    └── x86_64/
        └── ...
```

### `meta.json` schema

```json
{
  "tag": "deps-abc123",
  "parent": "docker-9a8b7c",
  "arch": "x86_64",
  "base_image": "alpine-base-3.22.2-x86_64.raw",
  "base_image_sha256": "...",
  "created": "2026-04-30T14:23:11Z",
  "last_used": "2026-04-30T14:23:11Z",
  "vm_config": {
    "memory_mb": 1024,
    "vcpus": 1,
    "ssh_port_at_snapshot": 51234
  }
}
```

### Snapshot create semantics

```
Preconditions: VM <vm-name> is running.

1. SSH into VM: sync; sync (flush filesystem caches).
2. Open QMP socket for the VM.
3. QMP: stop  (freeze CPU).
4. QMP: savevm <internal-tag>  (memory snapshot embedded in current disk).
5. QMP: cont  (resume).
6. Filesystem operations:
     - Create snapshots/<arch>/<tag>/ directory.
     - qemu-img convert / move overlay → snapshots/<arch>/<tag>/disk.qcow2
       OR (preferred) use blockdev-snapshot-sync to externalise atomically.
     - Persist memory portion to memory.bin (extracted from saved state).
     - Write meta.json with parent = (vm's previous snapshot or "base").
     - Initialise refcount = 0.
7. Re-base the running VM:
     - Create a new thin overlay for the running VM with backing_file =
       snapshots/<arch>/<tag>/disk.qcow2 so it continues from the snapshot
       point without copying.
8. Increment parent snapshot's refcount.
```

The original VM continues running after snapshot. This is essential for iterative provisioning in one VM (snapshot deps → install rails → snapshot rails → migrate db → snapshot db).

### Snapshot restore semantics

```
1. Resolve <tag> → snapshot directory (via tags/ symlink or direct).
2. Create a new VM <vm-name>:
     - disk = qcow2 overlay with backing_file = snapshots/<arch>/<tag>/disk.qcow2
     - memory = mmap snapshots/<arch>/<tag>/memory.bin (shared, copy-on-write)
3. Start qemu with -incoming "exec: cat memory.bin" or equivalent.
4. VM is in running state. SSH is reachable in ~100-300 ms.
5. Increment snapshot's refcount.
```

### Refcount + GC

- `refcount` is a small file in each snapshot directory, updated atomically (write-then-rename).
- Incremented when: a child snapshot is created, or a VM starts with `--from-snapshot=<tag>`.
- Decremented when: a child snapshot is removed, or a VM with `--from-snapshot=<tag>` is `aq rm`-ed.
- `aq snapshot rm <tag>` refuses to delete with `refcount > 0` unless `--force`.
- `aq snapshot gc` (planned for v1.5, not v1): removes snapshots with `refcount = 0` and `last_used > N days`.

### `aq snapshot tree` output

```
base (alpine-3.22.2-x86_64)
└── docker-9a8b7c   [refs: 2, 312M, 2d ago]
    ├── ruby-1f2e3d   [refs: 1, 87M, 2d ago]
    │   ├── deps-abc123   [refs: 0, 45M, 2h ago]   ← latest-deps
    │   └── deps-def456   [refs: 1, 41M, 1d ago]
    │       └── rails-migrated-789  [refs: 0, 12M, 1h ago]   ← ci-base
    └── npm-bb44cc   [refs: 0, 64M, 1d ago]
        └── node-deps-xyz   [refs: 0, 23M, 30m ago]
```

Implementation: traverse `meta.json` files, build parent/child graph, sort by `created`. Sizes via `du`. Tags resolved by reverse-mapping the `tags/` directory.

### v1 explicit YAGNI

- **No automatic hash-based invalidation.** The user decides when to recreate a snapshot. Bash recipe: `if ! aq snapshot ls | grep -q "deps-$HASH"; then aq snapshot create vm "deps-$HASH"; fi`.
- **No declarative manifest** (`aq.toml`).
- **No `AQ_FACTORS` recipes.**
- **No OCI artifact push/pull.** Local cache + GitHub Actions cache only.
- **No cross-architecture snapshot transfer.**

## Layer 3 — Fan-out / parallelism

### CLI

```
aq new --from-snapshot=<tag> [--count=N] [vm-name-prefix]
    With --count: creates N VMs named <prefix>-0, <prefix>-1, ...
    All N share the snapshot disk as backing.

aq fanout <tag> <N> -- <command>
    High-level CI primitive:
      1. Create N VMs from snapshot.
      2. For each VM, run <command> with environment:
         - AQ_SHARD_INDEX (0..N-1)
         - AQ_SHARD_TOTAL (=N)
      3. Wait for all to finish. Exit code = max(child exit codes).
      4. Stream stdout/stderr with [shard-N] prefix.
      5. On completion, aq rm all VMs (unless --keep).
```

CI usage example:

```bash
aq snapshot create app-vm "rails-migrated-$DEPS_HASH"
aq fanout "rails-migrated-$DEPS_HASH" 8 -- /root/repo/bin/test-shard
# bin/test-shard reads AQ_SHARD_INDEX and runs its assigned test group.
```

### Disk

Each VM gets a thin qcow2 overlay over the snapshot disk:

```
qemu-img create -f qcow2 -F qcow2 \
  -b ~/.local/share/aq/snapshots/<arch>/<tag>/disk.qcow2 \
  ~/.local/share/aq/vms/<vm-name>/disk.qcow2
```

Each overlay starts at ~196 KB.

### Memory

Each qemu process shares the snapshot's `memory.bin` via shared mmap. KSM (Linux) and OS-level page COW (macOS) deduplicate identical pages. Effective memory ≈ `base + N × delta`.

Documented expectation: an 8-shard fan-out from a 1 GB-memory snapshot consumes substantially less than 8 GB RAM in practice.

### Networking

- Each VM gets its own host-forwarded SSH port (existing dynamic allocation).
- Inter-VM communication: not supported in v1. User-mode networking isolates VMs from each other. If the test harness needs shared state, route via host (forwarded port) or external service.

### Parallel start

Background jobs + `wait`. `loadvm` is independent per process. On SSD, 10 VMs from snapshot start in 1-2 s wall clock.

### v1 YAGNI

- Inter-VM networking.
- Per-shard CPU/memory limits. qemu can do it; we'll add when asked.
- Auto-cleanup on fanout error. v1: caller uses `trap`.
- Distributed fan-out across hosts.

## Benchmark targets (for the demo)

Real reference: a typical Rails monorepo with PostgreSQL + Redis + ~5K tests. Target numbers for the launch blogpost:

| Scenario                       | docker-compose | aq + snapshots |
|-------------------------------|----------------|----------------|
| Cold setup (deps + db)        | ~90-180 s      | ~90-180 s (provisioning is identical) |
| Repeat setup (deps cached)    | ~30-60 s       | ~0.3 s (snapshot restore) |
| 8-shard parallel test start   | ~60-120 s      | ~2-3 s |
| Per-job overhead              | ~30-60 s       | <1 s |

If reality matches these, that's the launch material. If not, we adjust the story.

## Roadmap

Six phases. Each is a merge-able increment with a verifiable result. Cumulative scope, but every phase is useful on its own.

### Phase 1: Linux host support — 2 weeks

- Runtime detection: `uname` → host vars.
- `bootstrap_base_image` for x86_64 Alpine.
- `$BASE_DIR/$ARCH/...` layout.
- CI workflow on `ubuntu-latest` running the full existing test suite.
- README dependency matrix (brew vs apt).
- KVM availability check with a clear error.
- **Verify** GitHub-hosted Ubuntu runners expose `/dev/kvm` (assumption to confirm at start of phase).

**Success metric:** existing e2e tests green on `ubuntu-latest`.

**Risk:** runners without KVM. Mitigation: TCG fallback (slow but functional), or self-hosted runner for aq's own CI.

**Release:** aq 2.0.

### Phase 2: Snapshot CLI — 2-3 weeks

- QMP socket handling (small refactor of aq's qemu invocation).
- savevm / loadvm wiring.
- Snapshot directory layout.
- `meta.json` format.
- Refcount tracking.
- Backing-chain handling.
- Tags directory with symlinks.
- `aq snapshot create/restore/ls/rm/tag/tree`.
- E2E tests: provision → snapshot → rm vm → restore → assert state.
- Cookbook documentation.

**Success metric:** snapshot restore yields a running VM in <500 ms on M2 / <1 s on a standard CI runner. Demo: a bash script provisions a Rails app, snapshots it, removes the VM, restores — `bin/rails console` opens instantly.

**Release:** aq 2.1.

### Phase 3: Fan-out — 1-2 weeks

- `--count` parameter for `aq new --from-snapshot`.
- `aq fanout` with stdout multiplexing (`[shard-N]` prefix).
- Shared mmap for `memory.bin`.
- `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` env injection.
- Parallel start via background jobs + wait.
- E2E test: 8-VM fan-out with aggregated exit code.

**Success metric:** 8-VM fan-out from snapshot starts in <3 s wall clock; memory footprint <1.5× single-VM.

**Release:** aq 2.2.

### Phase 4: Demo & content — 1 concentrated week

- Pick a real OSS project with a slow CI (Rails app, GitLab, Mastodon, Discourse, Gitea) — preferably a fork — and rewrite its CI workflow from docker-compose to aq + snapshots.
- Real numbers in a table (cold/warm/fan-out × wall clock × cost).
- Blogpost with reproducible setup (bash scripts in the demo repo).
- README "CI use case" section linking the demo.
- Submit on Hacker News, Lobsters, r/devops.
- Tweet / Mastodon thread.

**Success metric (A — visibility):** ≥50 GitHub stars added; ≥100 HN points OR a notable DevOps voice retweets/comments. **Success metric (B — adoption):** ≥2-3 unsolicited "we tried it, thanks" reports.

### Phase 5: Reaction loop — open-ended

Driven by real user feedback. Likely directions in priority order, but priorities are *set by adopters*, not by us:

- `AQ_FACTORS` recipes (if requests for declarative cache invalidation arrive).
- OCI artifact push/pull (if pain over snapshot sharing surfaces).
- vfkit backend on macOS (if cold-boot-speed requests).
- Firecracker backend (if self-hosted Linux CI teams ask for max perf).
- Snapshot diff / inspect (if debugging tooling is asked for).
- Inter-VM networking (if integration-test requests).

**Success metric:** 5-10 teams using aq in production CI. Concrete case studies. Possibly GitHub Sponsors traction.

### Phase 6 (optional, 6+ months out): Backend abstraction

**Trigger:** only if Phase 5 surfaces genuine demand for firecracker.

Introduce a backend interface, add firecracker as the second backend for Linux CI. Snapshot format adapts to firecracker's native snapshot. This is the original "Approach 2" from brainstorming, but justified by real adoption rather than speculation.

## Anti-roadmap

Explicitly *not* doing as part of this work:

- rlock integration (separate track).
- Dockerfile → sh provision plugin (lives in rlock).
- vfkit / firecracker before Phase 6.
- `AQ_FACTORS` before Phase 5.
- OCI push/pull before Phase 5.
- microvm.nix at all.
- exe.dev-style hosted product before Phase 5.

## Sequencing

1. Commit this design.
2. Use writing-plans to produce the implementation plan for Phase 1.
3. Implement Phase 1, release aq 2.0.
4. Repeat for Phase 2 (release 2.1) and Phase 3 (release 2.2).
5. Phase 4 (demo) — concentrated sprint after 2.2.
6. Phase 5 — reactive, driven by feedback.
