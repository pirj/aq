## aq

Alpine on QEMU

`aq`, a tiny wrapper around QEMU, capable of starting Alpine Linux virtual machines.

### Rationale

Out of frustration with existing tools, and failing to grasp the depth of the underlying problem, build yet another new tool to fit my needs.

### Features and Anti-features

 - Alpine Linux only
 - only the latest Alpine
 - only the latest QEMU
 - text-mode only, for console, CLI and SSH
 - no distinction between an image and a instance
 - Mac-only host
 - direct "console" local access via telnet
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

### 

Monitor

    nc -U control.sock

Console via telnet

    telnet 127.0.0.1 10023

Console via nc

    nc -U app.sock

or nc, echo etc. E.g. to poweroff:

    echo quit | nc -U control.sock

Create an image backed by a reference. Changes, and only changes will be stored.

## TODO

### Use the default SeaBIOS

Somehow, it doesn't work. Filed a bug https://gitlab.com/qemu-project/qemu/-/issues/3080
Workaround: use the bundled EDK II OVMF EFI firmware
Downsides: flickers on boot

### Set a non-default MAC address

Might be needed for multiple machines to avoid duplicate MACs

    -device virtio-net-pci,netdev=net0,mac=56:c9:13:cf:18:a2 \

### daemonize

    -pidfile vm.pid \
    -daemonize

Error:
    -nographic cannot be used with -daemonize
Just remove -nographic?

### Boot splash!

    boot with a splash picture for 5 seconds.
    -boot menu=on,splash=/root/boot.bmp,splash-time=5000

### Snapshots

QEMU allows snapshots. Cool feature, can be used to save on creating a fleet of similar machines, mostly to save on the package fetching time". E.g. "install OS, install packages, set up SSHD, web server, git; snapshot; use the snapshot to spawn VMs".

### Telnet through a socket

Telnet provides a nice, modern interactive mode to the virtual machine shell.
However, it is inherently TCP/IP, and needs a TCP port to connect to. It can't work via a socket out of the box.
To provide Telnet access as a console to the virtual machine's shell, we need to generate a port.
Those ports have to be kept somehow not to overlap between running virtual machines.

    -serial telnet:127.0.0.1:10023,server=on,wait=off,nodelay=on \

On the other hand, a socket is just a file that can live in the directory where all other files related to that virtual machine reside.

    -serial unix:console.sock,server=on,wait=off,nodelay=on,telnet=on \

There's already a socket that can be accessed with `nc -U`, but it's not comparable for interactive use with Telnet.

`socat` can proxy from a UNIX socket to TCP making it possible to connect with Telnet:

    socat TCP-LISTEN:10223 UNIX-CONNECT:telnet.sock & # no fork: exit when the client closes the connection; goes to background

    telnet localhost 10223

Challenges: still need to be pick an available port.

    seq 100 999 | xargs ... lsof -i :<port>23

Keep the socket for `nc`, as `nc` handles scripting nicely.
Maybe even keep those sockets separate, so that a human-driven console does not interfere with scripted commands.

## Why not X?

### vs Docker

Head-to-head with Docker, Macpine, and Virsh

### vs Virsh

### vs Macpine

## License

AQ is released under the [MIT License](https://opensource.org/licenses/MIT).
