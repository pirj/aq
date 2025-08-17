## aq

Alpine on QEMU

`aq`, a tiny wrapper around QEMU, capable of starting Alpine Linux "units".

Features and anti-features:
 - Alpine Linux only
 - only the latest Alpine
 - only the latest QEMU
 - text-mode only, for console, CLI and SSH
 - no distinction between an image and a instance
 - Mac-only host

### Rationale

Out of frustration with existing tools, and failing to grasp the depth of the underlying problem, build yet another new tool to fit my needs.

### Philosophy

A unit has persistent storage, both for data and for the OS kernel and binaries.
It can be running or be stopped.
It is not "fixed" as an image.
It is easy to use one storage as a base for others.

### Cheat Sheet

Here's a sneak peek of `aq` for you:

    aq new guest-1    # creates a new unit
    aq start guest-1
    aq stop guest-1
    aq status guest-1
    aq ls             # list machines
    aq console
    aq rm guest-1

### Install

    brew install pirj/aq/aq

## TWO

Mount the Alpine as cdrom
and set up the system on a mounted
bootstrap via telnet/sock

Create an image backed by a reference.

prepare a base image
spawn units from base

Changes, and only changes will be stored.


wget https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-virt-3.22.1-aarch64.iso

qemu-img create -f qcow2 -o backing_file=alpine-virt-3.22.1-aarch64.iso -F raw alpine.qcow2

qemu-system-aarch64 \
 -machine virt,highmem=on -accel hvf -cpu host -m 1G \
 -bios /opt/homebrew/Cellar/qemu/10.0.3/share/qemu/edk2-aarch64-code.fd \
 -drive if=virtio,file=alpine.qcow2 \
 -device virtio-net-pci,netdev=net0,mac=56:c9:13:cf:18:a2 \
 -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8428-:8428 \
 -rtc base=utc,clock=host \
 -nographic \
 -serial telnet:127.0.0.1:10023,server=on,wait=off,nodelay=on \
 -serial unix:app.sock,server=on,wait=off,nodelay=on \
 -mon chardev=mon0,mode=readline -chardev socket,id=mon0,path=control.sock,server=on,wait=off \
 -serial mon:stdio

and then

    telnet 127.0.0.1 10023

or

nc -U app.sock

or socat, nc, echo etc

to poweroff:

    echo quit | nc -U control.sock

Create an image backed by a reference. Changes, and only changes will be stored.

## TODO

### Use the default SeaBIOS

Somehow, it doesn't work. Filed a bug https://gitlab.com/qemu-project/qemu/-/issues/3080
Workaround: use the bundled EDK II OVMF EFI firmware
Downsides: flickers on boot

## Set a non-default MAC address

Might be needed for multiple machines to avoid duplicate MACs

    -device virtio-net-pci,netdev=net0,mac=56:c9:13:cf:18:a2 \

## daemonize

    -pidfile /Users/pirj/.macpine/victoria/alpine.pid \
    -daemonize

## Boot splash!

    boot with a splash picture for 5 seconds.
    -boot menu=on,splash=/root/boot.bmp,splash-time=5000


## Why not X?

### vs Docker

Head-to-head with Docker, Macpine, and Virsh

### vs Virsh

### vs Macpine
