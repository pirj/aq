## aq

`aq`, a tiny wrapper around QEMU, runs Alpine Linux virtual machines.

Virtual Machine (VM) has dedicated persistent storage, both for data and for the OS kernel and binaries.

### Rationale

Out of frustration with existing tools, and failing to grasp the depth of the underlying problem, build yet another new tool to fit my needs.

### Features and Anti-features

 - Alpine Linux only
 - only the latest Alpine
 - only the latest QEMU
 - text-mode console and CLI
 - no distinction between an image and a instance
 - Mac-only host
 - direct console local access
 - sane defaults

### Cheat Sheet

    aq new -p 2222:22 -p 8000 guest-1
    aq start guest-1
    aq stop guest-1
    aq console guest-1
    cat script.sh | aq exec guest-1
    aq exec --all <<SH
      echo ssh-ed25519 AAAAC...YJk foo@bar >> .ssh/authorized_keys
    SH
    aq rm guest-1
    aq ls
    aq ls | grep Running
    aq ls | grep guest-1

### Install

    brew install pirj/aq/aq

### Usage

Create a new virtual machine:

    $ aq new
    Created aureate-chuckhole

Console into it:

    $ aq console aureate-chuckhole

Or run non-interactive commands:

    $ aq exec aureate-chuckhole -- ps

Install packages:

    # apk update && apk add victoria-metrics

Run services (sshd, nginx, ...).

    # rc-service victoria-metrics start

Remove it:

    $ aq rm aureate-chuckhole

Monitor (advanced QEMU VM control):

    $ echo quit | nc -U ~/.local/share/aq/cosset-league/control.sock
    $ nc -U ~/.local/share/aq/cosset-league/control.sock # Interactive

## License

AQ is released under the [MIT License](https://opensource.org/licenses/MIT).
