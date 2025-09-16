# Changelog

## 1.3 "Polite" 16-Sep-2025

### Improvements

- `aq start` now always waits for the VM to boot: no surprises using `aq exec` or `aq console` right after `aq start`

## 1.2 "Sticky" 12-Sep-2025

### Improvements

 - VMs now use persistent SSH ports allocated on start and removed on stop
 - `aq ls` now displays SSH port information for running VMs

## 1.1.31 "Tinfoil" 12-Sep-2025

### New Features

 - `aq scp` command for copying files between host and VMs. Mimics the `scp` command

## 1.0 "Alpemu" 10-Sep-2025

First stable release of aq - a QEMU wrapper for running Alpine Linux VMs on MacOS.

### Core Features

Complete VM lifecycle management: `new`, `start`, `stop`, `rm`, `ls` commands.
Interactive console access: SSH-based console with dynamic port forwarding.
Script execution: Execute commands via stdin pipes or command-line arguments.
Automated VM listing: Table view showing VM names and running status.

### Preliminary Optimizations

VMs inherit (overlay) their storage from the common static base image to save host disk space.
Base image creation uses raw format with ext4 filesystem and tuned caching for faster bootstrap.
Base image size is kept to a minimum.
UEFI firmware is using a minimum possible space for vars.

### Developer Experience

Fast VM creation.
No need for an explicit static SSH port forwarding.
Essential 80% of workflows for local development with VMs.

### Technical Foundation

This release delivers a fully functional VM management tool optimized for development workflows on Apple Silicon Macs.

### Contributors

Phil Pirozhkov
