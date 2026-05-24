# Changelog

## 2.5.20 "stty sane -echo" 2026-05-25

### Disable serial echo to break the loopback that races with bootstrap

CI logs from a failing cold-path run on Linux/KVM caught the real
root cause of the residual flake. Past the v2.5.16/v2.5.18/v2.5.19
race fixes, some runs still failed at extraction — but the log
showed something unmistakable:

```
alpine:~# -sh: ^[[6n: not found              ← ANSI DSR query reflected
-sh: -sh:: not found                          ← error msg reflected
-sh: localhost:~#: not found                  ← prompt reflected as command
-sh: NUTkFNRU9QVFM9: not found               ← base64 chunk reflected
-sh: 1kZXYKCiMgQ29u: not found               ← more base64 reflected
...
alpine:~# amkdir -p /target                   ← "a" prefix corrupts extraction
```

The guest shell is consuming its own output as input. Default
Alpine getty leaves /dev/ttyS0 in canonical-mode-with-echo state
where everything sent from the host is echoed back through the
same serial. Programs that emit DSR queries (`\e[6n`) see their
queries reflected back into the shell's stdin. The shell tries to
execute the reflected bytes as commands, racing whatever bootstrap
commands we're trying to send. The extraction script's first
character ("m" of `mkdir`) gets eaten or replaced by garbage,
/target/ never gets created, mount fails for all `/dev/vda*`,
extraction emits `AQ_EXTRACT_NO_KERNEL_FOUND`.

This was the real cause of the cold-path flakiness all along —
v2.5.16/v2.5.18/v2.5.19 each mitigated symptoms (waiting for the
shell prompt, bundling sends, chunking base64, obfuscating
sentinels) but the underlying loopback kept finding new ways to
corrupt timing-sensitive automation.

Fix: append `stty sane -echo; echo AQ_TTY_READY` to the post-login
`wait_for` so the tty is in a known state with input echo off
before any bootstrap command goes out. Commands' OUTPUT still
reaches /dev/ttyS0 (so wait_for's expect() still sees what it
needs); only the INPUT echo is silenced.

## 2.5.19 "obfuscated extract sentinel" 2026-05-25

### tio expect() can't tell input echo from output

After v2.5.18 fixed the cold-path setup.conf write race, extraction
still raced: host's `wait_for "expect(AQ_EXTRACT_READY)"` matched
on the SCRIPT SOURCE being echoed back by the guest shell in
canonical mode (visible in the log as `> echo AQ_EXTRACT_READY` —
the `> ` continuation prompt = shell is still parsing the for-loop,
hasn't executed it yet), not on the actual output once execution
reached the `echo` inside the loop. Host moved on to its nc retry
and got connection refused 5 times because guest's `nc -l -p 8080`
hadn't been reached yet.

Fix: build the sentinel literal at printf-runtime so the source
text doesn't contain it as a contiguous string. `printf
'AQ_EXTRACT_R%sY\n' EAD` produces `AQ_EXTRACT_READY` on stdout but
keeps the source as two pieces — input echo won't false-match
expect("AQ_EXTRACT_READY"). Same treatment for
AQ_EXTRACT_PARTITION and AQ_EXTRACT_NO_KERNEL_FOUND.

(SETUP_ALPINE_x86_64_OK was already safe by accident — its source
uses `printf 'SETUP_ALPINE_%s_OK\n' "$(uname -m)"`, and the
substituted arch name isn't part of the script literal.)

## 2.5.18 "chunk the base64" 2026-05-25

### setup.conf written in many short chunks instead of one long line

v2.5.16's bundle fix eliminated the post-login serial race but the
cold path was still flaky. v2.5.17's diagnostic emit confirmed:
`AQ_SETUPCONF_SIZE=0 expected=750` — `/root/setup.conf` was being
written as exactly 0 bytes, not a partial-truncation. The 1 KB
single-line `echo $LONG_BASE64 | base64 -d > /root/setup.conf`
command was getting lost somewhere between socat → qemu serial
chardev → kernel tty canonical-mode input buffer → busybox ash. The
redirect itself fired (truncating the file to 0) but the echo
produced no usable bytes.

Fix: keep base64's default 76-char line wrap, send the encoded form
as many short `echo CHUNK >> /root/setup.conf.b64` commands, then
`base64 -d` the assembled file at the end. Each chunk stays well
under any plausible MAX_CANON/N_TTY_BUF_SIZE cutoff.

## 2.5.17 "diag setup.conf size" 2026-05-25

Diagnostic-only release used to confirm the v2.5.16 cold-path flake
root cause (see v2.5.18 above). Emits `AQ_SETUPCONF_SIZE=N
expected=M` after the base64 decode so we can tell file-write
truncation from setup-alpine misbehavior. Behavior otherwise
identical to v2.5.16; no need to pin to this version.

## 2.5.16 "bundle the bootstrap" 2026-05-25

### Eliminate the post-login serial race on fast hosts (Linux/KVM CI)

Cold path went non-deterministic on `ubuntu-latest` CI runners
shortly after the v2.5.15 release: same fixture, same code, three
re-runs gave three different outcomes — once green, once setup-
alpine running three times with hostname becoming "y", once
kernel/initramfs extraction producing zero-byte files.

Root cause is a two-part timing race in `bootstrap_base_image`:

1. **Post-login race.** The pre-bootstrap `wait_for` ended right
   after `write("root\n")` with no further expect — so wait_for
   returned before the guest had drawn its shell prompt. The next
   three `echo "..." | socat STDIO UNIX:command.sock` invocations
   landed input bytes WHILE the getty was still printing MOTD and
   the shell hadn't started reading. CI logs caught the smoking
   gun:
   ```
   can setup the system with the command: setup-alpine  apk add e2fsprogs
   9YWxwaW5lCgojIFN  awaiting SETUP_ALPINE_x86_64_OK
   echolocalhost:~# echo S0VZTUFQT1BUUz1ub25lCgojIFN...
   ```
   The long base64 setup.conf line lost bytes in the interleaving,
   so on the guest `/root/setup.conf` decoded to garbage,
   `setup-alpine -f` silently fell back to interactive prompts
   (DISKOPTS = `[none]` → no install → no kernel/initramfs →
   extraction fail).
2. **Reconnect race.** Three back-to-back `echo | socat STDIO`
   invocations each opened and closed a fresh connection to qemu's
   `-serial unix:...,server=on` chardev. qemu takes a brief moment
   to mark the prior client as gone; rapid reconnects could be
   refused outright or land while the chardev is half-torn-down.

Two fixes, one release:

- **Post-login wait extended**: append `; expect("# ", 30000)` to
  the login wait_for. Returns only after the shell prompt has
  rendered.
- **Bundle the bootstrap**: replace the three separate `echo |
  socat` invocations with one `{ printf ...; printf ...; ... } |
  socat` that delivers all four lines (write setup.conf, apk add,
  run setup-alpine, emit sentinel) in a single connection. One
  send → one connection → guaranteed in-order delivery to busybox
  ash, which reads stdin line-by-line and executes sequentially.

The race manifested on fast Linux/KVM CI runners and didn't
surface on macOS/HVF where the locally-cached prompt arrives
faster than the next socat could be spawned. Locally reproducing
under qemu-system-x86_64 + TCG on M3 didn't trigger it either
(TCG is slow enough that the race window doesn't open).

## 2.5.15 "one y, then Enter" 2026-05-23

### Fix setup-interfaces infinite loop from over-broad `yes |`

v2.5.10's `yes |` was the wrong knob — it streams infinite literal
"y" tokens, which setup-alpine's setup-interfaces step interprets
as an invalid interface name:

```
Which one do you want to initialize? (or '?' or 'done') [eth0]
y
Available interfaces are: eth0.
Which one do you want to initialize? (or '?' or 'done') [eth0]
y
...
```

This looped until cancellation on Linux/KVM (which apparently
asks setup-interfaces interactively even with INTERFACESOPTS in
setup.conf, unlike aarch64).

Replace `yes |` with `{ echo y; yes ''; } |`: one literal "y" for
the disk-erase y/N confirmation, then a stream of blank lines so
every subsequent prompt picks whatever default sits in its `[...]`
brackets (e.g. `[eth0]` → uses eth0).

## 2.5.14 "mount-trial + handshake" 2026-05-23

### Extraction phase: replace blind retry + blkid syntax with handshake

v2.5.13's blkid-based partition detection didn't actually work
because busybox `blkid` on Alpine doesn't accept util-linux's
`-t TYPE=ext4 -o device` query syntax — it only prints raw
device-attribute lines. So the previous fix silently picked an
empty ROOT, mount failed, nc -l never started, and the host's
nc retry loop spent 30 s before giving up.

Rewriting extraction:

- **Mount-trial** instead of blkid: iterate `/dev/vda*`, try
  `mount -t ext4`, pick the partition that actually contains
  `/boot/vmlinuz-virt`. Works regardless of busybox vs util-linux
  blkid, regardless of arch-specific partition indices.
- **Sentinel handshake**: guest emits `AQ_EXTRACT_READY` right
  before `nc -l -p 8080` blocks. Host waits for that sentinel via
  `wait_for` (which since v2.5.10 surfaces the full serial stream
  in stderr) before connecting. Eliminates the previous blind
  30×1s host retry loop, and any guest-side failure (no kernel
  found, mount error) now appears in the workflow log instead of
  swallowing into 0-byte vmlinuz/initramfs files.
- Host-side retry trimmed to 5×1 s — the handshake makes long
  retries unnecessary.

## 2.5.13 "blkid the rootfs" 2026-05-23

### Cross-arch root-partition detection for kernel/initramfs extraction

After v2.5.12 unstuck the post-login wait_for, Linux/KVM CI got
through setup-alpine cleanly ("Installation is complete. Please
reboot.") but then failed at the next phase:

```
Error: kernel/initramfs extraction produced suspiciously small files (vmlinuz=0, initramfs=0).
       Tar-over-nc extraction may have failed (nc unreachable, tar contents wrong).
```

`bootstrap_base_image()` hardcoded `mount /dev/vda3 /target` for
extracting `vmlinuz-virt` + `initramfs-virt` from the freshly-
installed rootfs. That works on aarch64 (where setup-disk in sys
mode produces vda1=ESP, vda2=swap, vda3=root), but x86_64 setup-disk
can lay the partitions out differently (e.g. with a BIOS-boot
partition prepended). Mount silently failed, `tar | nc -l` never
ran, host nc retry-loop got connection-refused for 30 s, files
were 0 bytes.

- Replace the hardcoded `/dev/vda3` with `blkid -t TYPE=ext4 -o
  device | head -1` so the extraction lands on whichever device
  the ext4 root ended up on. Verify `/target/boot/vmlinuz-virt`
  exists before tar'ing; emit `AQ_EXTRACT_NO_EXT4` /
  `AQ_EXTRACT_NO_KERNEL` sentinels if not (visible on the serial
  for future debugging).

## 2.5.12 "write, actually" 2026-05-23

### Revert v2.5.11; aq requires tio ≥ 3.8

v2.5.11 incorrectly swapped `write(s)` for `send(s)` in the post-
boot login wait_for after misreading the Linux/KVM CI failure as
"macOS has tio 2.x, Linux has tio 3.x". The real story (per tio's
own release notes for v3.8):

> Clean up lua API
> Rename modem_send() to send()
> Rename send to write()

So tio v3.7 (what setup-bakerish was building from source on
Linux) had `send(string)` for serial writes; v3.8 renamed it to
`write(string)` and re-purposed `send(file, protocol)` as the
XMODEM/YMODEM file-send helper. Homebrew's macOS tio is on v3.9,
where the script aq has been using all along (`write("root\n")`)
is correct.

- Revert v2.5.11. Restore `write("root\n")` in the login wait_for.
- Document the tio ≥ 3.8 requirement in the comment.
- aq itself requires no further change; the Linux fix is in
  setup-bakerish, which now builds tio v3.9 from source instead
  of v3.7 (see setup-bakerish CHANGELOG).

## 2.5.11 "send, not write" 2026-05-23

### tio 3.x Lua API: send(), not write()

The v2.5.10 release dropped `--mute` from tio's invocation in
`wait_for` to surface the serial stream on hangs. The first Linux
run with this change immediately revealed why the post-login
bootstrap was hanging for 20 minutes:

```
[tio] Warning: lua: [string "tio"]:1: attempt to call a nil value (global 'write')
[tio] Disconnected
```

tio 3.x's Lua scripting exposes `send(s)`, not `write(s)`. On
Homebrew/macOS aq was running against tio 2.x — which used a
non-Lua script syntax that silently accepted the old `write` form —
so the bug never surfaced there. Linux runners built tio 3.7 from
source (per setup-bakerish's host_deps), hit the Lua mode, and
errored on every `write` call.

The first wait_for after VM boot — `expect("localhost login: ");
write("root\n")` — was supposed to log in as `root`. The `write`
call was nil and errored; tio exited; `root\n` was never sent. The
VM sat at the login prompt while aq's bootstrap commands streamed
in as failed login attempts. setup-alpine never ran, so
SETUP_ALPINE_x86_64_OK never appeared, and the 20-min workflow
timeout hit.

- Rename `write(` to `send(` in the login wait_for. The
  SETUP_ALPINE wait_for has no `send`/`write` so it's unaffected.

## 2.5.10 "yes |" 2026-05-23

### setup-alpine no longer hangs on x86_64 multi-prompt confirmation

The v2.5.9 milestones isolated the post-login Linux/KVM hang to
`wait_for "expect(\"SETUP_ALPINE_x86_64_OK\")"` — setup-alpine never
emitted its OK sentinel. setup-alpine on the Alpine x86_64 ISO has
a deeper bootloader install flow (GRUB on the disk via setup-disk)
than the aarch64 ISO's EFI-stub path, and asks more confirmation
prompts. The bootstrap was sending only a single `y\n` via
`echo y |`, leaving subsequent prompts unanswered.

- Pipe `yes` instead of `echo y` into setup-alpine. `yes` produces
  infinite `y\n` so however many prompts setup-disk needs, they
  all get auto-answered. Behaves identically on aarch64 (which
  finishes after the first y).
- Drop `--mute` from tio in `wait_for`. The serial stream — setup-
  alpine progress, kernel messages, any future prompts — now
  surfaces in stderr, which is the difference between "20 minutes
  of silence" and "actionable trace" the next time something
  hangs.

## 2.5.9 "Bootstrap milestones" 2026-05-22

### Diagnostic logging for the bootstrap_base_image phase

After the v2.5.8 fix unstuck GRUB autoselect on Linux/KVM, the next
validation run hit a fresh 20-min hang during the post-login
bootstrap phase. The block was somewhere between sending the
setup.conf to the live ISO's shell and waiting for the
`SETUP_ALPINE_X_OK` sentinel, but there were no stderr/stdout
breadcrumbs in that whole stretch — so the log left no way to
discriminate which of the three `echo ... | socat` calls (or the
final `wait_for`) was the one that hung.

- Add stderr milestones around each phase: writing /root/setup.conf,
  apk add e2fsprogs, setup-alpine launch, and the SETUP_ALPINE_OK
  wait itself. No behavior change; the next CI run will tell us
  precisely where the bootstrap stalls.

## 2.5.8 "Don't poke GRUB" 2026-05-21

### Linux/KVM base-build no longer hangs on Alpine ISO GRUB autoselect

`bootstrap_base_image()` used to send `\n` into the serial console
*before* waiting for `localhost login:`. On the slow firmware path
(Linux/KVM + OVMF + Alpine ISO under GH-Actions `ubuntu-latest`,
~90 s end-to-end) that `\n` landed *during* GRUB's 1-second
autoselect countdown — GRUB treated it as a keystroke, cancelled the
autoselect, and sat at the menu indefinitely until the workflow
timeout fired. macOS/HVF was fast enough that the same `\n` always
arrived *after* GRUB had handed off to the kernel, so it never
surfaced locally.

- Drop the pre-emptive `write("\n")` from the wait_for call in
  `bootstrap_base_image()`. Alpine's serial getty emits the
  `localhost login:` prompt on its own once spawned; tio is attached
  long before then, so `expect()` matches the natural prompt
  without a nudge.

Surfaced by `pirj/bakerish-rails-pg-example` CI validation; isolated
by a bare-qemu diagnostic workflow that reproduced the boot
succeeding without tio/socat in the loop. See ROADMAP.md "### Bugs"
for the full RCA.

## 2.5.7 "Just downgrade" 2026-05-19

### Simplified macOS QEMU 11.0.0 workaround

Turns out `brew upgrade qemu` leaves the previous keg in `/opt/homebrew/Cellar/qemu/` until `brew cleanup` runs, so most macOS Apple Silicon users hitting the v2.5.6 live-restore regression already have a working QEMU 10.0.3 sitting on disk that predates the v11.0.0-rc0 assertion. A single `PATH=/opt/homebrew/Cellar/qemu/10.0.3/bin:$PATH` is faster and less risky than building a patched 11.0.0 from source.

- **Removed `tools/qemu-livesave-repro/`** (the reproducer, the patch, the verify-fix script, the install-patched-qemu installer, and the README). They were carrying cost for a path no one would actually pick over the keg-downgrade. The RCA writeup stays in `ROADMAP.md`; the scripts are recoverable from git history if needed.
- **`aq_start` hint** for the (darwin, aarch64, qemu==11.0.0) case now points at the QEMU 10.0.3 PATH-prepend recipe instead of the patched-build instructions.
- **README ⚠ callout** in Install simplified to "stay on QEMU 10.x until 11.1.0 ships", with the one-line PATH override. Troubleshooting subsection collapsed from two workarounds to one.
- **`docs/comparison.md` HVF row** now references the QEMU 10.0.3 measurement (median 654 ms, n=3 on M3) instead of the patched 11.0.0 build.

No code-path changes in aq itself — the hint message string is the only diff.

## 2.5.6 "Patch in hand" 2026-05-19

### UX

- **Actionable hint for the QEMU 11.0.0 macOS aarch64 live-restore regression.** When `aq new --from-snapshot=<live-tag>` + `aq start` would otherwise just print `Error: incoming migration did not complete`, aq now detects the specific (darwin, aarch64, QEMU exactly `11.0.0`) combination and follows up with a hint pointing at the upstream commit and the README workaround section, so users don't waste time bisecting their own setup.

### New: `tools/qemu-livesave-repro/`

A pure-QEMU (no aq) reproducer for the regression that broke aq's macOS live-snapshot restore path:

- `repro.sh` — boots a tiny aarch64 HVF guest, captures memory via QMP `migrate file:...`, then starts a fresh qemu with `-incoming file:...`. Exits 0 when the upstream assertion fires.
- `verify-fix.sh` — same setup but attaches to the destination's QMP, confirms the VM reaches `paused` (not `paused (inmigrate)`), sends `cont`, and verifies the VM transitions to `running`. Exits 0 only when the full restore + resume cycle succeeds.
- `0001-hvf-stop-prealloc-cpreg-vmstate.patch` — the upstream fix (`06fd39e426` on QEMU master) exported as a `git am`-ready patch.
- `README.md` — full root-cause writeup (offending commit `ab2ddc7b66` from QEMU v11.0.0-rc0 added a new precondition that conflicts with HVF's pre-allocation introduced in `a1477da3dd` from v6.2.0) and step-by-step instructions to build a patched `qemu-system-aarch64` that aq picks up via `PATH`.

### Measured on M3 HVF, against patched QEMU 11.0.0

| target | median (n=3) |
|---|---|
| `aq_cold` (M3 HVF) | 4163 ms |
| **`aq_live` (M3 HVF, patched QEMU)** | **645 ms** |

645 ms on M3 HVF actually edges out the 680 ms Linux KVM number on GH — the upstream patch closes the regression cleanly, no macOS-specific cost. `docs/comparison.md` updated with the new row.

### Docs

- `README.md`: new Troubleshooting subsection "macOS aarch64 + QEMU 11.0.0: live restore asserts in cpu_pre_load" with the cherry-pick + local-build recipe.
- `ROADMAP.md`: Bugs section closed out with the full RCA, links to the introducing/fixing commits, the M3 vs Linux measurements, and the one open follow-up (bump aq's minimum QEMU once upstream tags a release containing the fix).

## 2.5.5 "Migrate" 2026-05-19

### Bug fixes

- **`qmp_wait_migrate_incoming`: pattern matched `paused (inmigrate)` as if migration were complete.** The `*'VM status: paused'*` case in the bash `case` statement also swallowed `paused (inmigrate)`, so `aq start --from-snapshot=<live-tag>` could send `cont` to QEMU before the incoming migration finished. Latent on Linux KVM because migration completes faster than the 200 ms poll interval (poll usually catches the post-migrate state); reproducible on macOS aarch64 HVF where ARM migration is slower. Put the `(inmigrate)` case first — bash picks the first match.

### New benches

- **`tests/bench-aq-from-live-snapshot.sh`** — provisions a VM once, snapshots it live (with memory), then loops `aq new --from-snapshot=<tag>` + timed `aq start` to SSH-accept. Reveals the actual cost of a live restore vs. cold boot.
- **`tests/bench-podman-sshd.sh`** — mirrors `bench-docker-sshd.sh` against `panubo/sshd` so the two container runtimes are directly comparable.
- Both wired into `.github/workflows/bench-vs-docker-sshd.yml` (workflow renamed to "Bench (aq vs alternatives — Linux)"; filename unchanged so path triggers stay valid).

### Measured (GH `ubuntu-latest` KVM, n=10, 100 ms probe)

| target | median |
|---|---|
| aq cold (new + start)               | **6695 ms** |
| aq live restore (new --from-snapshot + start) | **680 ms** |
| docker run panubo/sshd → TCP-accept | 142 ms |
| podman run panubo/sshd → TCP-accept | 96 ms |

Live restore is **~10× faster than cold boot** and closes the gap to containers from ~47× → ~5×. Updated `docs/comparison.md` with the full table and commentary.

### Known limitation

- **macOS aarch64 HVF + QEMU 11.0.0**: live-snapshot restore fails with an upstream ARM-target assertion (`target/arm/machine.c:1045: cpu_pre_load: !cpu->cpreg_vmstate_indexes`). Cold snapshots are unaffected. Linux x86_64 KVM is unaffected. No aq-side workaround available; tracking through QEMU upstream.

## 2.5.4 "Probe" 2026-05-19

### Performance

- **`wait_for_ssh` probe cadence 2 s → 0.5 s** (and `ConnectTimeout` 2 s → 1 s). Warm `aq start` no longer pays up to 2 s of dead-wait between SSH probes when the guest comes up mid-interval. Measured: on GH `ubuntu-latest` Linux/KVM, median `aq start` dropped from ~8 250 ms → ~6 900 ms (n=10) — a ~1.3 s shave per invocation. Total budget unchanged (~3 min, 360 attempts × 0.5 s). New env var `AQ_SSH_PROBE_INTERVAL` lets benchmarks override further.

### Tooling

- **Benchmark harness.** `tests/bench-aq-start.sh` runs warm `aq start` N times, reports min/median/max in ms. Backed by four passthrough env-var hooks in `aq_start` (production VMs leave them unset):
  - `AQ_DRIVE_EXTRA` — appended to the `-drive` directive
  - `AQ_QEMU_EXTRA_ARGS` — extra raw QEMU args
  - `AQ_MACHINE_OVERRIDE` — replaces `$MACHINE_OPTS`
  - `AQ_KERNEL_APPEND_EXTRA` — extra tokens for `-append`
- **`Bench (Linux warm aq start)` CI workflow** sweeps a fixed configuration grid on push (when `aq` or the bench script changes) and on workflow_dispatch. Markdown summary on the run page; `bench.tsv` uploaded as an artifact.

### Tests

- **`tests/stopped-vm-guard.sh`** locks in the v2.5.1 guard: `aq console` / `aq exec` (arg + stdin) / `aq scp` against a stopped VM must reject with `is not running` and exit non-zero within seconds, not hang on a refused SSH connect.

### QEMU tuning (DECLINED with data)

Used the new bench infra to settle three lingering questions:

- **`aio=io_uring` / `aio=native`** — neither beats the QEMU defaults (`threads` + writeback cache). Canonical `aio=io_uring,cache.direct=on` is ~50 ms median *slower*; `aio=native,cache.direct=on` ~100 ms slower. Warm boot is page-cache-dominated; async I/O has nothing to speed up.
- **`cache=none` / `cache.direct=on`** — ~100–200 ms median slower. Bypassing the host page cache is the wrong move for a workload that re-reads the same blocks every boot.
- **`-smp 2`** — ~300 ms median slower. Alpine OpenRC has `rc_parallel=NO`, so a second vCPU adds coordination overhead without unlocking parallel boot work.
- **Kernel cmdline `tsc=reliable no_timer_check nokaslr`** — within noise of baseline.

Full data in `docs/benchmarks/2026-05-19-aq-start-tuning.md`. Corresponding roadmap entries moved to declined.

## 2.5.3 "Tidy" 2026-05-19

### Guest base cleanup

The bootstrapped per-size base image now ships tidier:

- **`/etc/motd`** is replaced with an aq-specific banner (the stock Alpine motd suggested running `setup-alpine`, which is misleading once aq has finished the install).
- **`/root/.ash_history`** is removed at the end of base build so newly minted VMs don't inherit the install session's command history.
- **`/root/setup.conf`** removal (already in place since v2.4.0) now lives next to the other cleanups as one chained guest-side command.

All three apply to *new* base builds. Existing cached bases keep their current state until rebuilt (`rm ~/.local/share/aq/<arch>/alpine-base-*.raw` to force a rebuild).

### Tests

- New `tests/guest-cleanup.sh` boots a fresh VM and verifies the three cleanups above. Wired into `tests/run.sh` after `skip-fast-boot.sh`.

## 2.5.2 "Tap" 2026-05-19

### Distribution

- **Homebrew tap.** `brew install pirj/aq/aq` now installs from a real tap (https://github.com/pirj/homebrew-aq), pulling `qemu`, `tio`, `socat`, `coreutils` (for `shuf`), `wget`, and `gnupg` as deps. Works on macOS and Linuxbrew; Linux still needs system OVMF + KVM access (the formula's caveats spell this out).
- **Bash completions.** `completions/aq.bash` covers subcommands, VM names from `$BASE_DIR`, snapshot tags, and `aq new` flags (including `--from-snapshot=` completion against existing tags). Homebrew installs it automatically; for manual installs, source the file or drop it into `~/.local/share/bash-completion/completions/aq`.

### Docs

- **Troubleshooting section in README** covering stuck SSH wait, stopped-VM errors, port collision, live-snapshot RAM/boot-mode mismatches, KVM access on Linux, and HVF reinstall after macOS updates.
- **Install section restructured** — "Homebrew (macOS or Linux)" is now the primary path; "Linux (Debian/Ubuntu) without Homebrew" remains as the source-build alternative.

## 2.5.1 "Polish" 2026-05-19

### UX

- **`aq console` / `aq exec` / `aq scp` against a stopped VM** now fails fast with `Error: VM '<name>' is not running. Start it with: aq start <name>` instead of hanging on a refused SSH connect.
- **Quieter warm-boot path.** `aq start`'s SSH waiter no longer prints `Waiting for SSH...` / `SSH ready after N attempts.` when the guest comes up in the typical ~1-3 attempts. Slow boots still get the "Waiting for SSH..." narration after ~10 s plus the existing heartbeat every 20 s.
- **Random port collision detection.** `random_port` now retries (up to 20 times) and uses `nc -z -w 1 127.0.0.1 <port>` to avoid handing back a port already in use on the host. Affects `get_persistent_ssh_port` and the base-build kernel-extract port. Previously a clash silently broke `aq start` (QEMU's hostfwd bind would fail).
- **Drop stale "Batch" codename** from `aq --version`. Codename churns per release (Bolt, RAM, Polish, ...); printing only the version number is more honest than embedding the wrong one.

## 2.5.0 "RAM" 2026-05-19

### New Features

- **`aq new --memory=NG`** — per-VM RAM size, parallel to `--size=NG`. Default is 1G (matches the prior hardcoded value, so existing callers are unaffected). Docker / heavy workloads should pass `--memory=4G` or higher.
- **Live-snapshot RAM-size pinning.** Snapshots created with memory (live snapshots) now record `ram_size_mb` in `meta.json`. `aq new --from-snapshot=<tag>` reads it and:
  - Auto-fills `--memory` from the snapshot when the user didn't specify, so `aq new --from-snapshot=warm-4g foo` "just works" without remembering the size.
  - Refuses `--memory` mismatches with a clear error instead of letting QEMU's `-incoming` migration fail opaquely.
- **Per-VM `.memory` marker** in `$BASE_DIR/<vm>/`. Read by `aq start` to set QEMU's `-m`. Adds to the existing `.size` / `.boot_mode_*` markers.

### Internal

- `parse_memory_arg` helper alongside `parse_size_arg` (same `NG` integer-suffix grammar).
- `parse_new_args` gains `--memory=NG` / `--memory NG` (long and equals forms). `NEW_MEMORY` is left empty when the user doesn't pass `--memory`, so `_aq_new_one` can distinguish "default to 1G" from "auto-pick from snapshot".
- `write_meta` accepts an optional `ram_size_mb` 7th positional, emitted as a JSON number (not string).
- `read_meta` gains a `ram_size_mb` case for number-valued fields.
- `aq_start` reads the VM's `.memory` marker and passes `-m ${N}G` to QEMU. VMs from before this release have no marker and fall back to 1G.

### Known limitations

- **No memory hotplug after restore.** Live snapshots bind the captured RAM size; growing memory post-restore would require launching the source VM with `-m N,maxmem=M,slots=K` and using QMP `device_add pc-dimm` after `-incoming`. Tracked in `ROADMAP.md` under "--memory=NG flag and live-snapshot RAM hotplug" as a deferred follow-up.
- **Snapshots from < v2.5.0** have no `ram_size_mb` field and are treated as size-agnostic. The framework refuses live restores only when the snapshot explicitly records a size that differs from the requested `--memory`.
- The base-build VM still uses hardcoded `-m 1G`. The `--memory` flag controls user VMs only, not base bootstrapping.

## 2.4.0 "Bolt" 2026-05-18

### New Features

- **Per-size base catalog.** `aq new --size=NG` accepts arbitrary disk sizes; the corresponding `alpine-base-<version>-<arch>-NG.raw` is built on demand the first time a new size is requested, then reused for every subsequent `aq new --size=NG`. Each size's base is independent — adding a larger size does not invalidate caches at smaller sizes. Default `--size=2G` matches the prior effective size, so existing callers are unaffected.
- **Direct kernel boot** is the new default for `aq new` / `aq start`. The size-N base is pre-partitioned at full size, so `setup-alpine`'s small partition + first-boot `sfdisk` + `resize2fs` round-trip is eliminated. QEMU launches with `-kernel <vmlinuz-virt>` + `-initrd <initramfs-virt>` extracted from the installed Alpine at base-build time; no UEFI bootloader phase, no GRUB. Measured: `aq start` for a fresh VM drops from ~14 s (legacy UEFI + first-boot setup) to ~6 s on Apple M3 with HVF, a ~2.3× speedup. The legacy UEFI path remains available via `aq new --skip-fast-boot`.
- **`aq new --skip-fast-boot`** flag for opting back into UEFI/edk2 + bootloader chain. Kept for debugging and as a fallback when direct kernel boot has issues.
- **Snapshot meta.json now records `boot_mode` and `base_image`.** Live snapshots refuse to restore under a different boot mode than the one that captured them — memory state is tied to the kernel. Cold snapshots restore freely.
- **Actionable disk-full error message.** `aq exec` detects ENOSPC in command output and prints a recreate-with-larger-size path (`aq rm $vm && aq new --size=8G $vm`), with an in-place resize fallback documented.

### Bug Fixes

- Kernel extraction during base build no longer depends on `apk add busybox-extras` in the live ISO. Replaced with plain busybox `tar c | nc -l -p 8080` on the guest side and `nc | tar x` on the host. Works on GH x86_64 runners where the prior `busybox-extras httpd` path failed silently.

### Internal

- `_aq_new_one`'s overlay `qemu-img create` no longer hardcodes 2G; the virtual size now defaults to the backing image's size (pre-partitioned size-N base or snapshot's disk).
- New per-VM markers in `$BASE_DIR/<vm>/`: `.size` (integer GB), `.boot_mode_direct` or `.boot_mode_uefi`. Used by `aq_start`'s boot-path selection and by the disk-full helper for size lookup.
- New helpers: `parse_size_arg`, `compute_base_filename`, `alpine_base_for_size`, `emit_disk_full_help`.
- `aq_new` arg parsing extracted into `parse_new_args` setting `FORWARDS / FROM_SNAPSHOT / COUNT / NEW_SIZE / SKIP_FAST_BOOT / VM_NAME`.
- Source-only mode via `__AQ_SOURCED_ONLY=1 source ./aq` lets tests exercise pure-logic helpers (`tests/unit-helpers.sh`).

### Tests

- `tests/unit-helpers.sh` (new) — unit coverage for size parsing, filename composition, `parse_new_args`.
- `tests/direct-kernel-boot.sh` (new) — verifies default-path VM boots via `-kernel`/`-initrd`, no resize2fs in dmesg, `/dev/vda3` is rootfs.
- `tests/size-base-catalog.sh` (new) — verifies that two VMs at the same `--size=N` share an existing size-N base and both boot.
- `tests/skip-fast-boot.sh` (new) — verifies legacy UEFI path under `--skip-fast-boot` and marker file placement.
- `tests/run.sh` wires the new suites alongside `smoke`, `snapshots`, `live-snapshots`, `fanout`.

### Known Limitations

- The first `aq new --size=NG` per new N costs the full Alpine install + kernel extraction (~30–60 s). Every subsequent `aq new --size=NG` is fast. Pre-warming common sizes is a future option.
- aq guests are still hardcoded to `-m 1G`. Docker workloads commonly need more; a `--memory=NG` flag parallel to `--size` is queued as a follow-up.
- Live snapshots from before this release have `boot_mode = unknown` and are accepted as cold-snapshot-compatible only; create fresh live snapshots after upgrade.

## 2.3.1 2026-05-03

### Bug Fixes

- `bootstrap_base_image` no longer waits for a sentinel after the post-install cleanup heredoc. After `setup-alpine` completes, leftover output from kernel messages, `udhcpc` lease renewals, and apk progress-bar carriage returns can flood the serial input loop, with the live ISO shell echoing them back as `-sh: ^M: not found` indefinitely. The wait_for would never see the cleanup sentinel, hang, and cause the bootstrap to time out. The cleanup is now best-effort with a short sleep instead — if the rm/umount didn't land, the only consequence is a stale `/root/setup.conf` in the installed VM (cosmetic).

## 2.3.0 "Swarm" 2026-05-02

### New Features

- `aq new --from-snapshot=<tag> --count=N [prefix]` creates N VMs named `<prefix>-0` ... `<prefix>-(N-1)`, each backing onto the snapshot's `disk.qcow2`. Default prefix is `shard-$$` if omitted.
- `aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>` is the CI-style helper: builds the fleet, starts all shards in parallel, runs the user command in each shard with `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` set, multiplexes per-shard output with a `[shard-<name>]` prefix, waits for all to finish, aggregates exit codes (max), and tears the fleet down (unless `--keep`).

### Internal

- `aq_new` body refactored into a `_aq_new_one` inner function so the counted loop can call it without duplication.
- `aq_fanout` uses `awk` for line-prefixed output multiplexing (no per-line fork overhead); per-shard exit codes are written to mktemp files (with `>|` to bypass noclobber) and read back after `wait`. Each shard runs in a `set +e` subshell so a non-zero user exit doesn't skip writing the code.
- Per-shard env vars are propagated by piping `export …` lines plus the user command through `sh -s` over SSH. Inline `VAR=val cmd` doesn't work for `$VAR`-referencing commands because the parent shell expands `$VAR` before the assignment takes effect for the child.

### Limitations

- All shards share the same host directory tree (no cross-shard FS isolation beyond the per-VM qcow2 overlay).
- No CPU / memory caps per shard yet — relies on Linux KSM / macOS page cache to dedup the read-only snapshot pages across shards.

## 2.2.0 "Resume" 2026-05-01

### New Features

- `aq snapshot create` on a *running* VM now captures live memory state via QMP `migrate file:<path>`. The VM is paused for a few seconds during capture, then resumes. `meta.json` records `has_memory: true` and `memory.bin` lives next to `disk.qcow2` in the snapshot dir.
- `aq new --from-snapshot=<tag>` of a memory-bearing snapshot stages the memory file in the new VM dir as `incoming-memory.bin` (hard-linked, no copy on the same filesystem).
- `aq start` of a VM with `incoming-memory.bin` launches qemu with `-incoming "file:<path>"` and resumes at the snapshot point. Measured: SSH reachable in ~1 s vs ~12 s for a cold boot. The incoming file is consumed and removed by qemu; subsequent `aq start` boots cold from the now-up-to-date `storage.qcow2`.

### Internal

- Every running VM now exposes a QMP socket at `<vm-dir>/qmp.sock` alongside the existing readline HMP `control.sock`. New `qmp_hmp` and `qmp_send` helpers send commands; `qmp_wait_migrate` polls for completion of outgoing migration; `qmp_wait_migrate_incoming` polls for incoming application.
- After incoming migration, `aq start` issues HMP `cont` in a verify-and-retry loop because `cont` during the `inmigrate → paused` transition can no-op in some qemu versions.
- `qemu-img info` calls now use `--force-share` so `aq snapshot create` can read backing-chain metadata while qemu holds an exclusive write lock.

### Limitations

- After live restore, the guest clock has rewound to the snapshot moment. Programs sensitive to wall-clock time may misbehave until NTP catches up.
- `memory.bin` can be 100-300 MB on a freshly-booted Alpine; up to RAM size on a heavily-used VM. Storage planning is the operator's responsibility for now.

## 2.1.1 2026-05-01

### Bug Fixes

- Snapshot refcount is now computed on demand from authoritative state (VMs with `.from_snapshot` marker matching the tag, plus snapshots whose `meta.json` parent matches the tag). Previously, the count was kept in a `refcount` file that could drift under crashes, manual file edits, or concurrent operations — the dangerous failure mode being a stuck-zero count that let `aq snapshot rm` silently delete a snapshot still backing a live VM. Removing the cache eliminates the drift class entirely.

## 2.1.0 "Frozen" 2026-05-01

### New Features

- `aq snapshot create/ls/rm/tag/tree` for managing cold snapshots of stopped VMs. Snapshots store disk state under `~/.local/share/aq/snapshots/<arch>/<tag>/` and carry a `meta.json` (parent, source VM, base image, timestamps) and a refcount. Aliases under `tags/<arch>/<name>` are plain symlinks.
- `aq new --from-snapshot=<tag> [vm-name]` creates a new VM whose disk overlays a snapshot, skipping `first_boot_setup`. Multiple VMs can derive from one snapshot; their thin overlays only store deltas.
- `aq snapshot tree` visualises the backing chain as a forest rooted at the alpine base image.
- `aq rm <vm>` decrements the refcount on the snapshot a VM was derived from (if any), so `aq snapshot rm` can detect orphaned snapshots safely.

### Bug Fixes

- `aq stop` now syncs the guest filesystem over SSH before killing qemu, so disk writes from the most recent `aq exec` are durable. This was a long-standing latent issue that became visible when snapshotting (writes from the source VM would be missing in the snapshot).

### Internal

- New helper section in `aq` for snapshot directory layout, `meta.json` read/write, and refcount management. JSON is read with grep/sed (no jq dependency).
- Backing chains use absolute paths, so snapshots remain valid across host directory moves of the parent VM but not across machines.

### Limitations (Phase 2A)

- Snapshots are cold (disk only). Phase 2B will add live memory state for millisecond restore.
- `aq snapshot create` requires the source VM to be stopped.
- `aq snapshot rm` does not yet auto-clean parent snapshots whose refcount reaches 0; that is a deliberate Phase 5 decision.

## 2.0.0 "Crossing" 2026-05-01

### New Features

- **Linux x86_64 host support** with KVM acceleration. The same `aq` CLI now runs on Ubuntu/Debian (and other Linux distros with `/dev/kvm`) as on macOS, picking qemu+KVM and a x86_64 Alpine guest at runtime via `uname`. macOS Apple Silicon continues using HVF and ARM64 Alpine.
- E2E smoke test (`tests/smoke.sh`) covering the full lifecycle: `new` → `start` → `exec` (arg + stdin forms) → `stop` → `rm`.
- GitHub Actions workflow on `ubuntu-latest` running the smoke test on every push, with apt and tio binary caching for ~2-minute warm runs.

### Internal

- Per-arch storage layout: `~/.local/share/aq/<arch>/{alpine-base,alpine-virt-iso,uefi-vars}`. Existing flat-layout installs are migrated automatically on first run.
- Runtime host detection (`detect_host`) sets `HOST_OS`, `ARCH`, `ACCEL`, `QEMU_BIN`, `MACHINE_OPTS`, `UEFI_CODE`, `UEFI_VARS_FLAVOR`. All `qemu-system-*` invocations parameterised.
- UEFI handling abstracted: `uefi-vars-sysbus` JSON on macOS, split pflash `.fd` (OVMF) on Linux. Dynamic OVMF firmware discovery (Ubuntu 22/24+ uses `OVMF_*_4M.fd`).
- `aq_start` now uses SSH polling (`wait_for_ssh`) instead of `wait_for` on the serial console. The installed Alpine doesn't need a serial getty for runtime; `first_boot_setup` runs over SSH. Serial console remains only inside `bootstrap_base_image`, which has to drive the live ISO's `setup-alpine` interactively.
- `bootstrap_base_image` writes `setup.conf` to the live ISO via a single-line base64 blob instead of a multi-line heredoc — busybox ash heredoc termination over the serial wire was unreliable on x86_64 (the terminator was not consistently recognised, leaving the shell stuck in a continuation prompt).
- `add_ssh_forward` is now race-resistant: switched from `nc -U` to `socat -t1` with retries on the QEMU monitor socket. Previously, after replacing the long serial wait with SSH polling, the immediate hostfwd command could be lost before qemu read it.
- Clear `/dev/kvm` access error on Linux pointing the user at the `kvm` group fix.

## 1.6.0 "The Tortoise" 16-Nov-2025

### Bug Fixes

- Fixed race condition where `aq exec` and `aq console` could run before first boot setup completed, causing APK database lock errors
- Fixed `first_boot_setup` not waiting for commands to complete before returning, ensuring APK operations finish before provisioning scripts run

## 1.5.2 16-Nov-2025

### Bug Fixes

- Fixed "LATEST_ALPINE_ISO_ASC: unbound variable" error in GPG signature verification

## 1.5.1 16-Nov-2025

### Improvements

- Updated Alpine Linux version from 3.22.1 to 3.22.2

### Bug Fixes

- Fixed "unbound variable" error when running commands without required VM name argument

## 1.5 "Batch" 19-Sep-2025

### Bug Fixes

- Fixed `aq scp` "stat local" error by using batch mode (-B) as default option

### Security

- Added GPG signature verification for Alpine Linux ISO downloads to ensure integrity

## 1.4 "Repellent" 16-Sep-2025

### Improvements

- Set VM hostname to the VM name on first boot
- Added clear error messages when attempting to operate on non-existent VMs

### Bug Fixes

- Fixed `aq scp` unbound variable error when no options are provided
- Added clear error message when attempting to start an already running VM
- Fixed `aq stop` error when attempting to stop a VM that was already powered off
- Made `aq stop` idempotent
- Fixed first boot automated setup being skipped due to failed login

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
