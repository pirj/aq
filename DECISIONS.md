# Architectural Decisions

This document captures the cornerstone decisions behind the aq v1.0 "Alpemu" release.

## Bash over POSIX sh

While POSIX sh is more portable, it's overly limiting for a tool targeting macOS development workflows. Bash is available everywhere aq would be used and provides essential features like arrays, better string handling, and more robust scripting capabilities.

## Base Image Strategy: Copy-on-Write Overlays

Create a single base Alpine Linux image and use QCOW2 overlays for individual VMs.

Benefits:
- Storage space efficiency: Only VM-specific changes are stored, saving significant host disk space
- Performance: Fast VM creation without repeated OS installation
- Consistency: All VMs start from the same baseline

## Console Access: SSH over Serial

Serial Console Problems:
- No session isolation: Shared state between interactive and scripted ports
- Connection complexity: Requires `tio` + `socat` and pty workarounds for reliable interactive use
- Protocol issues: Telnet negotiation creates output artifacts, sticky legacy "line-by-line" mode
- Single connection: Only two serial consoles possible per VM
- Non-deterministic state: No guarantee of login prompt vs. active session vs running command

SSH Advantages:
- Session-based: Each connection is independent and clean
- Standard tooling: Works with existing SSH clients and automation
- Multiple connections: Concurrent access without interference
- Reliable: No escape sequence or protocol negotiation issues

Implementation:
- Base image includes OpenSSH server with host user's public key
- Dynamic temporary random port allocation ~prevents~ reduces conflicts between sibling VMs

## Access Pattern: Hybrid Approach

Maintain both SSH and serial console access methods.

Usage:
- SSH: Primary method for `console` and `exec` commands (user-facing)
- Serial: Bootstrap method for base image creation and emergency access
- Tools: Keep `tio` for reliable VM boot detection, `socat`/`nc` for scripting

This provides the best of both worlds: reliable user experience via SSH and low-level access for system operations.

## Platform Optimization: Apple Silicon Focus

Decision: Optimize specifically for Apple Silicon Macs with ARM64 Alpine Linux.

Technical choices:
- Virtualization: HVF acceleration
- Architecture: ARM64 for native performance
- Storage: Raw base image with EXT4 for optimal I/O
- UEFI: Minimal variable file size for faster VM creation
- Networking: User-mode with configurable port forwarding

This delivers maximum performance on the target platform while maintaining simplicity.
