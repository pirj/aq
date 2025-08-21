## aq

Alpine on QEMU

`aq`, a tiny wrapper around QEMU, capable of starting Alpine Linux virtual machines.

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

### Philosophy

Virtual Machine (VM) has persistent storage, both for data and for the OS kernel and binaries.
A VM can be running or be stopped.
VM is not set in stone as an "image".

### Cheat Sheet

    aq new guest-1
    aq start guest-1
    aq stop guest-1
    aq console guest-1
    aq exec guest-1 bootstrap.sh
    aq rm guest-1
    aq ls
    aq ls | grep Running
    aq ls | grep guest-1

### Install

    brew install pirj/aq/aq

(will also install qemu and tio).

### Simplistic Workflow

Create a new virtual machine:

    $ aq new
    Created aureate-chuckhole

Run some commands on it:

    $ aq exec aureate-chuckhole -- ps

Remove it:

    $ aq rm aureate-chuckhole

### Common workflow

Create a new virtual machine.
Install the OS using a script.
Install required packages.
Run services (sshd, nginx, ...).
? reboot

Console:

    $ aq console aureate-chuckhole

??? Most importantly - how to exit ~~Vim~~ Tio, QEMU serial console & QEMU Monitor

Non-interactive commands

    $ aq exec aureate-chuckhole -- ps

### Advanced

Monitor (advanced QEMU VM control):

    echo quit | nc -U control.sock
    nc -U control.sock # Interactive

## TODO

### Port forwarding

Now hardcoded, accept options at start? or when creating a new vm? It should be clear from the beginning what the VM is all about, isn't it?

### set -e, pipefail, bash as interpreter?

### Set a non-default MAC address

Might be needed for multiple machines to avoid duplicate MACs

    -device virtio-net-pci,netdev=net0,mac=56:c9:13:cf:18:a2 \

### daemonize

    -pidfile vm.pid \
    -daemonize

Try with pidfile?
-parallel none \

1. Error:
    -nographic cannot be used with -daemonize
2. Just remove -nographic? Won't work with an error - file a bug? ask a question?
    objc[81811]: +[__NSPlaceholderDate initialize] may have been in progress in another thread when fork() was called.
    objc[81811]: +[__NSPlaceholderDate initialize] may have been in progress in another thread when fork() was called. We cannot safely call it or ignore it in the fork() child process. Crashing instead. Set a breakpoint on objc_initializeAfterForkError to debug.

### cloud image

fetch a cloud image, use it as a base for other qcow2 storage images as backing
does it need installation?
does it have storage?
is it possible to increase storage when using the base as backing?

https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/generic_alpine-3.22.1-aarch64-uefi-tiny-r0.qcow2

### Snapshots

QEMU allows snapshots. Cool feature, can be used to save on creating a fleet of similar machines, mostly to save on the package fetching time". E.g. "install OS, install packages, set up SSHD, web server, git; snapshot; use the snapshot to spawn VMs".

Create an image backed by a reference. Changes, and only changes will be stored.

## Why not X?

### vs Docker

Head-to-head with Docker, Macpine, and Virsh

### vs Virsh

### vs Macpine

## License

AQ is released under the [MIT License](https://opensource.org/licenses/MIT).
