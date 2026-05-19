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

**Live snapshots** — when you snapshot a *running* VM, aq also captures the live memory state. Restoring such a snapshot skips Alpine's boot entirely: the kernel, processes, network connections, and tmpfs contents come back as they were at the snapshot moment. SSH is reachable in ~1 s instead of ~12 s.

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
