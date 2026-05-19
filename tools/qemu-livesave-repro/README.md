# QEMU 11.0.0 aarch64 HVF live-restore reproducer

Minimal, aq-free reproducer for the QEMU 11.0.0 regression that breaks
aq's macOS aarch64 live-snapshot restore path:

```
ERROR:target/arm/machine.c:1045:cpu_pre_load:
  assertion failed: (!cpu->cpreg_vmstate_indexes)
```

## Files

- `install-patched-qemu.sh` — one-shot installer. Clones QEMU `v11.0.0`,
  applies the patch, builds `qemu-system-aarch64`, symlinks it into
  `~/.local/bin/`. Idempotent — safe to re-run; skips clone/configure/
  build when the tree is already current.
- `repro.sh` — boots a tiny aarch64 guest under HVF, dumps memory via
  QMP `migrate file:...`, then starts a fresh qemu with `-incoming
  file:...` and observes the assertion. Exits 0 when the assertion
  fires (the bug is present), 1 otherwise (the bug is absent).
- `verify-fix.sh` — same setup as `repro.sh`, but instead of waiting
  for the assertion it attaches to the destination's QMP, confirms
  the VM reaches `paused` (not `paused (inmigrate)`), sends `cont`,
  and verifies the VM transitions to `running`. Exits 0 only when
  the full restore + resume cycle succeeds.
- `0001-hvf-stop-prealloc-cpreg-vmstate.patch` — upstream commit
  [`06fd39e426`](https://gitlab.com/qemu-project/qemu/-/commit/06fd39e426)
  exported as a `git am`-ready patch. Removes the HVF Apple-Silicon
  init code's pre-allocation of `cpreg_vmstate_indexes`, which
  conflicts with the assertion added in v11.0.0
  ([`ab2ddc7b66`](https://gitlab.com/qemu-project/qemu/-/commit/ab2ddc7b66)).

## First check: do you already have QEMU 10.0.3 around?

`brew upgrade qemu` leaves the previous keg in `/opt/homebrew/Cellar/qemu/` until you run `brew cleanup`. If you upgraded recently, 10.0.3 is probably still there — and it doesn't have the v11.0.0-rc0 assertion at all, so it's a drop-in workaround that needs no build:

```sh
ls /opt/homebrew/Cellar/qemu             # 10.0.3 listed?
export PATH="/opt/homebrew/Cellar/qemu/10.0.3/bin:$PATH"
qemu-system-aarch64 --version            # expect "version 10.0.3"
```

Verified: aq live-restore on M3 HVF reports median 654 ms (n=3) with 10.0.3, vs 645 ms with patched 11.0.0 — within run-to-run noise.

If you don't have 10.0.3 in Cellar (clean install, or `brew cleanup` already ran), fall through to building the patched 11.0.0 below.

## Build the patched binary (when 10.0.3 isn't available)

```sh
bash install-patched-qemu.sh
export PATH="$HOME/.local/bin:$PATH"
qemu-system-aarch64 --version    # expect (v11.0.0-1-...)
```

Then `aq new --from-snapshot=<live-tag>` lands in ~700 ms instead of asserting.

## Quick run

By default `repro.sh` uses whatever `qemu-system-aarch64` is on `PATH`
and assumes you have `~/.local/share/aq/aarch64/{vmlinuz-virt,initramfs-virt}`
from a recent `aq new` (anything ARM64 Linux kernel + initramfs works,
override via `KERNEL=` / `INITRD=`).

```sh
bash repro.sh                                                          # against brew qemu
QEMU=/path/to/patched/qemu-system-aarch64 bash verify-fix.sh           # against patched qemu
```

## Building a patched qemu from v11.0.0

```sh
git clone --depth=1 --branch v11.0.0 https://gitlab.com/qemu-project/qemu.git
cd qemu
git am --keep-non-patch path/to/0001-hvf-stop-prealloc-cpreg-vmstate.patch
brew install ninja pkg-config glib pixman
./configure --target-list=aarch64-softmmu --enable-hvf --disable-docs
ninja -C build qemu-system-aarch64
./build/qemu-system-aarch64 --version
# QEMU emulator version 11.0.0 (v11.0.0-1-...)
```

Drop the resulting binary into `~/.local/bin/qemu-system-aarch64`
(or anywhere ahead of brew's on `PATH`) and aq picks it up.

## Background

- Pre-allocation introduced in [`a1477da3dd`](https://gitlab.com/qemu-project/qemu/-/commit/a1477da3dd) (v6.2.0, "hvf: Add Apple Silicon support"). Harmless until the assert showed up.
- Assertion introduced in [`ab2ddc7b66`](https://gitlab.com/qemu-project/qemu/-/commit/ab2ddc7b66) (v11.0.0-rc0, "Use VMSTATE_VARRAY_INT32_ALLOC for cpreg arrays"). Authored by Eric Auger, reviewed by Peter Maydell.
- Fix on `master` (Apr 2026): [`06fd39e426`](https://gitlab.com/qemu-project/qemu/-/commit/06fd39e426). No tagged release contains it yet at the time this directory was committed.
- Linux KVM x86_64 is unaffected — only the HVF init path pre-allocates the conflicting field.
