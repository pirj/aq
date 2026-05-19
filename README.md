## aq

Frustrated with existing tools, and failing to grasp the depth of the underlying problem, built a new tool to fit my needs: `aq`, a QEMU wrapper to **run Alpine Linux virtual machines** on macOS and Linux.

Features and Anti-features: dedicated persistent storage; Alpine Linux only; most recent Alpine; recent QEMU; text-mode, console and CLI.

### Supported hosts

| Host                      | Acceleration | Guest arch |
|---------------------------|--------------|------------|
| macOS (Apple Silicon)     | HVF          | aarch64    |
| Linux x86_64 (with KVM)   | KVM          | x86_64     |

aq picks the right backend at runtime via `uname`. Snapshots and per-VM state live under `~/.local/share/aq/<arch>/`.

### Cheat Sheet

    aq new -p 2222:22 -p 8000 guest-1
    aq start guest-1
    aq stop guest-1
    aq console guest-1
    cat script.sh | aq exec guest-1
    aq scp -r config.toml guest-1:/etc/app/
    aq scp guest-1:/var/log/app.log ./logs/
    aq ls | grep On | cut -d" " -f1 | xargs -n1 -I_ aq exec _ <<SH
      echo ssh-ed25519 AAAAC...YJk foo@bar >> .ssh/authorized_keys
    SH
    aq rm guest-1
    aq ls
    aq ls | grep On
    aq ls | grep guest-1

### Snapshots

    aq new myrails
    aq start myrails
    # ... provision (apk add, bundle install, db:setup, ...)
    aq stop myrails
    aq snapshot create myrails rails-deps
    aq snapshot ls
    aq snapshot tree

    aq new --from-snapshot=rails-deps shard-1
    aq new --from-snapshot=rails-deps shard-2
    aq start shard-1
    aq start shard-2
    # Both shards start from the same provisioned state — no apk add, no bundle install.

Snapshots are stored under `~/.local/share/aq/snapshots/<arch>/<tag>/` and live in the same architecture as the host. Cold snapshots (created from a stopped VM) capture disk state only; new VMs cold-boot from the snapshot's disk.

**Live snapshots** — when you snapshot a *running* VM, aq also captures the live memory state. Restoring such a snapshot skips Alpine's boot entirely: the kernel, processes, network connections, and tmpfs contents come back as they were at the snapshot moment. Measured: SSH reachable in **~680 ms** (Linux KVM, n=10, see `docs/comparison.md`) instead of ~7 s cold.

    aq new myrails
    aq start myrails
    # provision, run a server, do work...
    aq snapshot create myrails myrails-running   # VM stays running
    aq new --from-snapshot=myrails-running fresh-shard
    aq start fresh-shard                          # SSH ready in ~1s

### Fan-out

Run N parallel VMs derived from one snapshot, executing a command per shard:

    aq fanout rails-deps 8 -- /root/repo/bin/test-shard

Each shard receives `AQ_SHARD_INDEX` (0..N-1) and `AQ_SHARD_TOTAL` (=N) in its environment, so a test runner can pick its slice. All shards back onto the same `disk.qcow2` (delta-only writes per shard); if the snapshot has memory state, each shard restores from the same `memory.bin`. Output is multiplexed with a `[shard-<name>]` line prefix, exit code is the max of children's, and shards are torn down after the command finishes (use `--keep` to opt out).

For a finer-grained pipeline you can also use `aq new --from-snapshot=<tag> --count=N <prefix>` to create the fleet and drive it yourself with `aq start`, `aq exec`, `aq stop`, `aq rm`.

### How aq compares to Docker / Podman

The shortest version: **aq is a system container, Docker is an app container.** Different shape, different costs, different wins.

**Where aq is uniquely useful:**

- **Live snapshots with memory.** Provision a non-trivial stack once (apk add, gem install, db:setup, redis warmed, an LLM loaded into RAM, ...), `aq snapshot create` while it's running — every subsequent `aq new --from-snapshot=TAG` resumes from that frozen memory in **~680 ms** (measured, GH Linux KVM, n=10). TCP connections, tmpfs contents, JIT-warmed processes, model weights all come back. Docker's CRIU-based equivalent exists in principle but isn't packaged and isn't reliable across kernel versions.
- **Fan-out** is the snapshot's natural use case: `aq fanout TAG 8 -- /workload` spins up 8 parallel VMs from one provisioned state with `AQ_SHARD_INDEX`/`AQ_SHARD_TOTAL` in env, each landing in ~1 s. Ideal for parallel test suites where setup cost dwarfs the actual test, or any "I've warmed N GB of memory, give me N copies of it" pattern.
- **Full kernel isolation.** Each VM has its own Linux kernel under a hypervisor (HVF on macOS aarch64, KVM on Linux x86_64). A guest kernel bug stays in the guest — there is no guest kernel shared with the host. Containers share the host kernel via namespaces+cgroups, which leaks less than people assume but more than VMs. Matters for CI on untrusted PRs, security research, multi-tenant runners, anything you'd be uncomfortable running with `--privileged`.
- **Provisioning is bash, not a DSL.** No Dockerfile layer cache to invalidate, no `RUN ... && rm -rf /var/lib/apt/lists/*` ritual, no `--target` multi-stage gymnastics. You `aq exec vm` and run real commands; when satisfied, `aq snapshot create`. Once provisioning grows past trivial — an Ansible playbook, a 50-line setup chain, fixtures that depend on the order of previous steps — the gap between "fast iterative debugging" and "Dockerfile build-and-cross-fingers" gets noticeable.
- **Real Linux init.** OpenRC inside the VM. Run multiple cooperating services (`apk add nginx postgresql redis`, `rc-service * start`) without the one-process-per-container constraint or the orchestration layer it implies.
- **Persistent storage is the default.** Each VM has its own qcow2 overlay; `aq stop` + `aq start` preserves everything. No "did I forget a volume mount?" failure mode.
- **No daemon, single bash script.** ~1.8 kloc, MIT-licensed, auditable in an afternoon. No background process, no socket permissions, no commercial-use subscription. Each `aq` invocation is self-contained.

**Where Docker is uniquely useful:**

- **Sub-100 ms cold start.** `docker run -d panubo/sshd` lands in **~142 ms** on the same hardware where aq cold takes ~6.7 s. If you spin up thousands of short-lived workers, that gap dominates.
- **Declarative reproducibility.** Dockerfile + content-addressed layer cache is unmatched for "byte-identical build on any machine". aq snapshots are state, not a build recipe.
- **Bind mounts.** `-v $PWD/src:/src` is friction-free for iterative dev loops. aq doesn't expose 9p/virtfs host-share (yet), so host↔guest file sync is `aq scp` round-trips.
- **Ecosystem.** docker-compose, k8s, registries, image scanners, supply-chain tooling. aq is single-VM-shaped by design.

Full measured comparison (aq vs docker-sshd, podman, virsh, macpine on the same hardware, plus a structured table across size / isolation / configurability / reproducibility / horizontal scalability / data sharing / snapshot+overlay): [`docs/comparison.md`](docs/comparison.md).

### When *not* to use aq

- **You spin up thousands of disposable workers and 6-second cold start hurts.** Containers win; the ~50× gap on cold path isn't closeable. (Snapshots collapse it to ~5× once you've provisioned once — see above — but if you can't amortise the provision, that doesn't help.)
- **You need Windows or macOS guests.** aq is Alpine-only by design.
- **Your dev loop lives on `-v $PWD:/src` bind mounts.** aq's SSH-based file sync is friction. 9p/virtfs isn't wired in yet.
- **You need declarative byte-identical builds shippable to N machines.** Dockerfile + registry is the right tool; aq snapshots are state, not a build manifest.
- **You need GPU or PCI passthrough.** QEMU can do it, but aq doesn't expose the machinery.
- **You need k8s, compose, service meshes, multi-host orchestration.** aq is single-VM-shaped; orchestration is out of scope.
- **macOS aarch64 + live snapshots, right now.** Blocked by an upstream QEMU 11.0.0 ARM migration regression (cold snapshots and Linux KVM live restore both unaffected). Tracking upstream.
- **Your team is fluent in Docker and isn't hitting its limits.** Switching costs are real. aq's wins matter only if you actually need them — if Docker is fine for your workload, it's fine.

### Install

#### Homebrew (macOS or Linux)

    brew install pirj/aq/aq

Pulls in `qemu`, `tio`, `socat`, `coreutils`, `wget`, and `gnupg` from brew. On Linux you still need KVM access and system OVMF — see the Linux section below for the additional steps brew can't handle.

The tap lives at https://github.com/pirj/homebrew-aq.

#### Linux (Debian/Ubuntu) without Homebrew

    sudo apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils socat ovmf wget gpg ca-certificates

    # tio 3.x is required for --script. Ubuntu 24.04 ships an older version;
    # build from source:
    sudo apt-get install -y --no-install-recommends \
      meson ninja-build pkg-config liblua5.4-dev libinih-dev libglib2.0-dev \
      git build-essential
    git clone --depth 1 --branch v3.9 https://github.com/tio/tio.git /tmp/tio
    cd /tmp/tio && meson setup build && meson compile -C build && sudo meson install -C build

#### Linux: KVM access (any install method)

    sudo usermod -aG kvm $USER   # log out and back in

Verify KVM is reachable:

    [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK"

#### Shell completions

The Homebrew install wires bash completions automatically. For a manual install, source `completions/aq.bash` from your `.bashrc` or drop it into `~/.local/share/bash-completion/completions/aq`.

### Usage

Create a new virtual machine:

    $ aq new
    Created aureate-chuckhole

Console into it:

    $ aq console aureate-chuckhole

Or run non-interactive commands:

    $ aq exec aureate-chuckhole ps

Copy files to/from VMs:

    $ aq scp -r nginx.conf aureate-chuckhole:/etc/nginx
    $ aq scp -r aureate-chuckhole:/var/log/ ./vm-logs/

Install packages:

    # apk update && apk add victoria-metrics

Run services (nginx, ...).

    # rc-service victoria-metrics start

Monitor (advanced QEMU VM control):

    $ echo quit | nc -U ~/.local/share/aq/cosset-league/control.sock
    $ nc -U ~/.local/share/aq/cosset-league/control.sock # Interactive

Remove it:

    $ aq rm aureate-chuckhole

## Troubleshooting

### `aq start` hangs at "Waiting for SSH..."

The guest booted but isn't accepting SSH yet. Most often it's first-boot inside a fresh base — give it ~30 s. If it persists, peek at the QEMU monitor:

    nc -U ~/.local/share/aq/<vm>/control.sock     # interactive HMP
    echo info status | nc -U ~/.local/share/aq/<vm>/control.sock

Or watch the serial console directly:

    socat - UNIX:~/.local/share/aq/<vm>/command.sock
    # ...or attach `tio` (nicer terminal handling) via a PTY:
    socat UNIX:~/.local/share/aq/<vm>/command.sock PTY,link=/tmp/<vm>.pty &
    tio /tmp/<vm>.pty

### `aq exec`/`aq console` immediately errors with "VM is not running"

The VM is stopped. Start it: `aq start <vm>`. If `aq ls` shows the VM as `On` but commands still fail, the QEMU process may have died while the per-VM files remain — check `~/.local/share/aq/<vm>/process.pid`.

### Port collision / "could not find a free random port"

`aq` picks ephemeral host ports from the 49152–65535 range and checks each is free before handing it out. If 20 picks in a row are taken, it gives up. Pin a specific port instead:

    aq new -p 2222:22 -p 8080:80 myvm

### Live snapshot refuses to restore

Live snapshots bind the captured boot mode and RAM size. If `aq new --from-snapshot=<tag>` fails with a mismatch, either:

- pass `--memory=<size>` matching the snapshot's `ram_size_mb`,
- or re-create the snapshot from a VM started under the right `--memory`/boot mode.

Cold snapshots (created from a stopped VM) have no such constraints.

### macOS aarch64 + QEMU 11.0.0: live restore asserts in cpu_pre_load

Upstream QEMU 11.0.0 has a regression that affects aarch64 HVF live-snapshot restore specifically:

```
ERROR:target/arm/machine.c:1045:cpu_pre_load:
  assertion failed: (!cpu->cpreg_vmstate_indexes)
```

aq surfaces this as `Error: incoming migration did not complete` plus a hint pointing here. Cold snapshots and Linux KVM x86_64 are unaffected — only the macOS-aarch64-with-memory restore path trips it.

**Root cause** (in case you want to confirm against your own setup): commit [`ab2ddc7b66`](https://gitlab.com/qemu-project/qemu/-/commit/ab2ddc7b66) (in `v11.0.0`) made the ARM target's `cpreg_vmstate_indexes` array auto-allocated by the migration framework and added a `g_assert(!cpu->cpreg_vmstate_indexes)` precondition in `cpu_pre_load`. The HVF code path pre-allocates that same array at vCPU init (since v6.2.0, originally harmless), so the assertion fires on every incoming migration.

**Upstream fix**: [`06fd39e426`](https://gitlab.com/qemu-project/qemu/-/commit/06fd39e426) (on `master`, post-v11.0.0) — six lines, removes the HVF pre-allocation. Not yet in any tagged release.

**Workaround until QEMU 11.1.0 ships**:

aq ships a one-shot installer that builds the patched binary and symlinks it under `~/.local/bin`:

```sh
bash tools/qemu-livesave-repro/install-patched-qemu.sh
export PATH="$HOME/.local/bin:$PATH"     # add to ~/.zshrc to keep it
qemu-system-aarch64 --version            # expect "(v11.0.0-1-...)"
```

The script clones QEMU `v11.0.0`, applies `tools/qemu-livesave-repro/0001-hvf-stop-prealloc-cpreg-vmstate.patch` (the upstream fix exported as a patch), configures with `--target-list=aarch64-softmmu --enable-hvf`, builds, and symlinks. Re-running it is safe — it skips clone/configure/build when the tree already has the expected commit and binary.

Once the patched binary is ahead of brew's on `PATH`, `aq new --from-snapshot=<live-tag>` resumes in ~700 ms — same as Linux KVM.

If you'd rather do it by hand: see `tools/qemu-livesave-repro/README.md` for the step-by-step + the `verify-fix.sh` end-to-end test.

The aq project's own bench measures **645 ms median live-restore** on M3 HVF with the patched QEMU — matching the Linux KVM number, confirming the fix unblocks the macOS path entirely.

Stable-branch status as of writing: the fix is on `master` only; `stable-11.0` hasn't picked it up, so a hypothetical 11.0.1 cut from `stable-11.0` would still have the bug. Naturally lands in **QEMU 11.1.0**. If you want it backported sooner, email `qemu-stable@nongnu.org` requesting `06fd39e426` for stable-11.0.

### Linux: `aq start` errors with "KVM is required"

`/dev/kvm` isn't accessible. Verify:

    [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK"

If your user isn't in the `kvm` group:

    sudo usermod -aG kvm $USER     # log out and back in

### macOS: HVF/qemu errors after macOS update

Reinstall qemu so the new system's HVF entitlements match:

    brew reinstall qemu

## License

aq is released under the [MIT License](https://opensource.org/licenses/MIT).
