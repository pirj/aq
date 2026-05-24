# aq — orientation for agents

`aq` is a Bash QEMU wrapper for **Alpine Linux** virtual machines
on macOS (HVF) and Linux x86_64 (KVM). It's the lowest layer of
the rlock product family — everything above (`rlock`, `ai.rlock`,
`bakeri.sh`) calls into `aq` for VM lifecycle.

For project background, see [`README.md`](README.md); for shipped
cornerstone decisions see [`DECISIONS.md`](DECISIONS.md); for what
remains, see [`ROADMAP.md`](ROADMAP.md).

## Hard constraints

- **Alpine Linux only.** Not Ubuntu, not Debian, not "configurable
  distro." The whole speed story (small base, `apk` fast-path,
  direct-kernel boot, sub-second warm) depends on Alpine being
  *the* target. Don't add multi-distro abstractions.
- **macOS Apple Silicon + Linux x86_64.** Only these two. macOS
  uses HVF; Linux uses KVM. Pick the right one at runtime via
  `uname`. Don't add aarch64-on-Linux or x86_64-on-macOS unless
  there's a real user; the matrix gets messy fast.
- **Bash, not POSIX sh.** Arrays, `[[ ]]`, `local`, `pipefail` are
  all used. Both target hosts ship Bash 5+ via Homebrew or distro
  package.
- **Pinned QEMU.** QEMU 10.0.3 is what we test against (QEMU
  11.0.0 had an aarch64 HVF live-restore regression — see
  CHANGELOG / DECISIONS). When bumping QEMU, run the full
  benchmark suite (in `~/source/ai.rlock/meta/benchmark-*.md`)
  before declaring the upgrade safe.
- **No GUI guest.** Text-mode Alpine, console + ssh only. No X,
  no Wayland.

## Mental model

```
aq command  →  qemu-system-{aarch64,x86_64}  →  Alpine VM
                       │
                       ├─ base image (per-arch, per-size)
                       │  ~/.local/share/aq/<arch>/base/
                       │
                       └─ per-VM overlay (qcow2 backing → base)
                          ~/.local/share/aq/<arch>/vms/<name>/
```

- **Base image catalog** — pre-partitioned, pre-resized raw
  images at each common size. No first-boot `sfdisk + resize2fs`.
  This is the optimization that gets cold `aq new` under 7s.
- **Live snapshots** — memory + disk snapshot of a running VM,
  restored via `qemu -incoming file:memory.bin`. Sub-second
  warm-restore. See [`DECISIONS.md`](DECISIONS.md) and the
  spec in `rlock/docs/superpowers/specs/`.
- **User-mode networking** (SLIRP) only. Guest reaches host via
  `10.0.2.2`. No bridged/TAP networking (would require root).
  Hostfwd maps host port → guest port 22 for SSH.

## Common operations

```sh
aq new -p 2222:22 -p 8000 guest-1   # create
aq start guest-1                     # start
aq stop guest-1                      # stop
aq ssh guest-1                       # ssh into it
aq exec guest-1 <<<'apk add curl'    # one-shot exec
aq scp -r config.toml guest-1:/etc/  # copy in
aq snapshot create guest-1 -live     # save warm state
aq snapshot ls guest-1               # list snapshots
aq rm guest-1                        # destroy
```

`aq` is consumed programmatically by `rlock`'s plugin protocol;
the CLI is meant for both humans and scripts.

## Conventions

- **Per-arch state under `~/.local/share/aq/<arch>/`.** Don't mix
  Apple-Silicon and x86_64 caches; they're not interchangeable.
- **`meta.json` per VM and per cached snapshot** holds size,
  ports, ram, base-image reference. Authoritative; `aq inspect`
  reads it.
- **Snapshot kinds:** `cold` = disk-only (qcow2 snapshot),
  `live` = disk + memory (qcow2 + memory.bin + state). Live
  restore is ~1.3s isolated; cold rebuild is ~7s.
- **`AQ_NO_SNAPSHOT_COMPRESS=1`** opts out of zstd compression
  on memory.bin. ~400 ms faster warm restore in exchange for
  ~1.1 GB more cache per kind=live layer. Default off; CI may
  opt in.
- **Pin to a QEMU release.** Live restore is exquisitely
  sensitive to QEMU's HVF and migration code. Don't follow
  upstream blindly.

## What NOT to do

- Don't switch to cloud-init for SSH key provisioning — we use
  `fw_cfg` for a reason (skips ~1s of cloud-init boot).
- Don't add full-distro support. "Alpine + minimal busybox" is
  the whole point.
- Don't add bridged networking by default. SLIRP user-mode is
  what makes "aq new" zero-root.
- Don't break the per-size base catalog. Adding a "compute size
  at boot" path will silently re-introduce the 15s sfdisk
  round-trip we eliminated in v2.4.0.
- Don't refactor the snapshot format without a CHANGELOG entry
  and a benchmark run — `rlock` and `bakeri.sh` depend on the
  on-disk layout for cross-machine cache (planned via OCI).

## Sibling repos

- [`rlock`](https://github.com/pirj/rlock) — consumes `aq`'s
  lifecycle and snapshot operations via subprocess. The plugin
  protocol layer.
- [`ai.rlock`](https://github.com/pirj/ai.rlock),
  [`bakeri.sh`](https://github.com/pirj/bakeri.sh) — rlock
  plugin packs; they don't call `aq` directly.

## Where decisions go

- **Cornerstone decisions** of aq's architecture →
  [`DECISIONS.md`](DECISIONS.md) (existing, scoped to aq).
- **Cross-cutting decisions** that affect aq + sibling repos →
  ADRs in `../meta/decisions/`. See `../meta/CLAUDE.md` for
  conventions.
- **Mechanical work** → [`ROADMAP.md`](ROADMAP.md).

## Workspace context

This repo lives at `~/source/ai.rlock/aq/` inside the umbrella
workspace. The umbrella's [`CLAUDE.md`](../CLAUDE.md) is the
single best map of how all sibling repos connect.
