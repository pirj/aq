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

### Install

#### macOS

    brew install pirj/aq/aq

Or, the underlying dependencies and the script directly:

    brew install qemu tio socat

#### Linux (Debian/Ubuntu)

    sudo apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils socat ovmf wget gpg ca-certificates

    # tio 3.x is required for --script. Ubuntu 24.04 ships an older version;
    # build from source:
    sudo apt-get install -y --no-install-recommends \
      meson ninja-build pkg-config liblua5.4-dev libinih-dev libglib2.0-dev \
      git build-essential
    git clone --depth 1 --branch v3.9 https://github.com/tio/tio.git /tmp/tio
    cd /tmp/tio && meson setup build && meson compile -C build && sudo meson install -C build

    # KVM access:
    sudo usermod -aG kvm $USER   # log out and back in

Verify KVM is reachable:

    [ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM OK"

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

## License

aq is released under the [MIT License](https://opensource.org/licenses/MIT).
