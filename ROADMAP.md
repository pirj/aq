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
- [x] resize (up) the guest filesystem to match the guest storage size
    - but WHEN to do this?! we don't boot the vm yet ! do it on the FIRST boot
- [x] implement missing
- [x] allow plain commands to exec
- [x] write down decisions

## 1.x

- [x] reuse the same SSH forwarded port instead of allocating several

- [ ] remove excessive output around aq console/exec; also the rest like first boot etc

- [ ] install those to the base image instead of in each vm! apk add partx sfdisk e2fsprogs-extra

- [ ] stability improvements. sometimes fails on bootstrap
        alpine:~# > DISKOPTS="-m sys /dev/vda"
        -sh: can't create DISKOPTS=-m sys /dev/vda: nonexistent directory
        alpine:~#
      takes a while for vm to start and aq console <vm> fails until then

- [ ] detect occupied host ports during random port allocation

- [?] resize (down) the base image after OS install to reduce occupied host disk space

- [ ] alpemu.dev - starts with full-screen terminal, basic commands to start a machine, run something on it, and then more terminals spawn and like a few dozen. on scroll
- [ ] formula/tap. dependencies: tio! socat! qemu! zstd (image compression)?
- [ ] autotests
- [ ] add error when console/exec stopped instance
- [ ] remove setup.conf for real
- [ ] clean up shell history - rm ~/.ash_history
- [ ] also use ext4 for the base's bootfs
- [ ] use cache=none for normal runs, too?
- [ ] further improve images performance cluster_size=64k,compression_type=zstd
- [ ] use Alpine cloud images (see details below)
- [ ] snapshots (see details below)
- [ ] can be used as a backend for containers.dev? https://github.com/microsoft/vscode-remote-try-rust/blob/main/.devcontainer/devcontainer.json
- [ ] benchmarks/feature rundown vs Docker/Macpine/OrbStack/Podman/Virsh
- [ ] bash completions

- [ ] add a doc section on troubleshooting: e.g.
  - socat STDIO UNIX:command.sock
  - UNIX:command.sock PTY,link=command.pty & && SOCAT_PID=$! && tio command.pty

- [ ] allow the user to select the SSH key to use
- [ ] .config/aq.toml for configuring the SSH key?

- [?] aio=native/io_uring - latter won't work, as it's Linux-only, what's the deal with native?

- [ ] fwd options: tcp/udp, hostaddr, guestaddr

- [?] multiple machines and MACs
- [?] adjust SMP - currently uses the default. is this fine for most cases?

### Use cloud images

Mention https://github.com/alpinelinux/alpine-make-vm-image - build images
https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images - build cloud images

Consider https://alpinelinux.org/cloud/ again. how hard is it to build that IMDS metadata server that publishes the root pubkey to allow ssh?
https://gitlab.alpinelinux.org/alpine/cloud/tiny-cloud - tiny bootstrapper
> Tiny Cloud is also used for Alpine Linux's experimental "auto-install" feature.

! try again to boot a cloud qcow2 image. last time if failed somehow
! via serial console, create a /usr/lib/tiny-cloud/cloud/*aq*/imds file, and an autodetect, forward a socket to the guest, and extract add code to extract user-data and ssh_authorized_keys from that socket (no http, just yaml, base64 encoded: decode and parse with yx yaml parser)

### Snapshots

QEMU allows snapshots. Cool feature, can be used to save on creating a fleet of similar machines, mostly to save on the package fetching time". E.g. "install OS, install packages, set up SSHD, web server, git; snapshot; use the snapshot to spawn VMs".

### non-default MAC address

Multiple machines don't clash on the same MAC address
Might be needed for multiple machines to avoid duplicate MACs
    -device virtio-net-pci,netdev=net0,mac=56:c9:13:cf:18:a2 \
