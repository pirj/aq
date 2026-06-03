# Changelog

## 2.5.52 "qmp_wait_migrate_incoming: progress-based stall detection" 2026-06-03

Pure fixed-budget polling conflated two failure modes: real
deadlocks (bail fast) vs slow apply under runner contention
(wait long). snapcompose-benchmark `+1 seq cold` kept hitting
the v2.5.48 budget ceiling (2100 polls / 7 min for 2 GiB
estimated raw) even though we couldn't tell whether the
migration was genuinely stuck or just crawling.

Inner heuristic: every 10th poll (2 s cadence) reads
`query-migrate`'s `ram.transferred` byte counter. As long as
the byte count is climbing, we keep waiting — that's real
progress. Only when no climb has been observed for ~30 s do
we declare the migration stuck and return 1 with diagnostic.
The pre-existing size-scaled wall-clock max stays as a safety
net for the (unlikely) case of "real, sustained, very slow"
that should still bail.

Trades the brittle 2-min/GiB heuristic for a real-progress
signal. Wall-clock failure messages now include the last
`transferred` byte value so post-mortems are actionable.

## 2.5.51 "zstd-patch save: fall back to plain zstd on >2 GiB memory.bin" 2026-06-03

Surfaced by snapcompose-benchmark in CI runs 2026-06-02:
`zstd: error 42 : Can't handle files larger than 2 GB`. The
`--patch-from` CLI path reads both reference and input fully
into memory (single-shot mode) and bails past INT32_MAX bytes
= 2 GiB. 4 GiB-RAM guests with live docker-compose stacks
routinely produce memory.bin in the 2–3 GiB range, so this
isn't a corner case — it's the Phase 2+ benchmark fixture's
default state. Result: the warm-from-patch column couldn't
populate because zstd failed mid-save.

`AQ_MEMORY_SNAPSHOT=zstd-patch` now `stat`s both the input
memory.bin and the decompressed parent reference. When either
exceeds 2 GiB, the save transparently falls back to plain
pzstd / zstd of memory.bin (no `--patch-from`) and skips
emitting the `memory.format` patch marker. The chain still
builds; the layer just loses the patch-storage win on this
hop. Subsequent layers can resume patching against a smaller
ancestor.

Streaming via stdin would bypass the limit for the input
file but `--patch-from`'s reference is `stat`-checked
regardless, so streaming-only doesn't help. The architectural
fix — switching the save path to QEMU's native multifd zstd
compression (`multifd-compression=zstd` + `migrate file:`) —
would remove the limit, the separate compress step, AND the
pzstd-vs-zstd checksum quirk in one go. Filed separately.

## 2.5.50 "bootstrap cleanup: trial-mount /dev/vda* (aarch64 fix)" 2026-06-02

Surfaced by `tests/guest-cleanup.sh` on aarch64 macOS host
2026-06-02. The `need_extract=0` branch of `bootstrap_base_image`
hardcoded `/dev/vda3` as the installed-root mount source — fine
on x86_64 setup-disk's sys-mode layout (ESP + /boot + /), but
aarch64's layout can place root on /dev/vda2. The mount silently
failed, `/target` stayed an empty live-ISO RAM directory, and
the `$cleanup` redirects landed in tmpfs instead of the installed
root. Result: `/root/setup.conf`, `/root/.ash_history` AND the
stock Alpine `/etc/motd` all survived into the cached base.

Replaces the hardcoded path with a trial-mount loop over
`/dev/vda*`, picking the partition whose `/etc/alpine-release`
file exists — same shape as the `need_extract=1` branch's
extraction loop (which is why that path was already arch-safe).
Condensed to a single line because multi-line scripts over the
live ISO's raw serial chardev suffer interleaving from kernel
messages + udhcpc output.

Validated by `tests/guest-cleanup.sh` going green on aarch64:
all three cleanups land (motd is the aq banner, setup.conf
absent, .ash_history absent).

## 2.5.49 "ensure_base_image: gracefully skip flock on macOS" 2026-06-02

Regression from v2.5.45's flock fix: `flock(1)` isn't part of
macOS by default (util-linux only — brew install required), so
v2.5.45–48 broke `aq new` on every macOS host with `flock:
command not found`. The smoke test `tests/guest-cleanup.sh`
surfaced this on host as soon as a fresh base bootstrap was
attempted.

`ensure_base_image` now `command -v flock`-gates the lock
acquisition. macOS hosts proceed without the lock — single-VM
provisioning has no race there, and macOS isn't a CI parallel-
multi-VM target today. Linux runners (the only context where
par-cold matters) always have flock via util-linux, so they
keep the lock semantics.

## 2.5.48 "qmp_wait_migrate_incoming budget — bigger baseline + per-GiB" 2026-06-02

Follow-up to v2.5.46's size-scaled migrate-incoming budget. That
version raised the budget from 300 (60 s) to 300 + 150/GiB
(~90 s for 1 GiB), but real-world GH ubuntu-latest runners with
hot dockerd + concurrent VM build still need >90 s for a 1 GiB
apply. snapcompose-benchmark Phase 3 walking-skeleton re-tripped
this in run 26807611414 / job 79029041845.

Bumps baseline to 900 polls (3 min) + 600/GiB (2 min), and
rounds GiB up so any non-zero incoming gets at least 1 GiB worth
of budget. Compressed-input estimate raised from 3× to 5×
expansion (live snapshots compress well; better to overshoot).

New budget shape:
* 0 GiB raw   → 900 polls (3 min)
* 1 GiB raw   → 1500 polls (5 min)
* 3 GiB raw   → 2700 polls (9 min)
* 6 GiB raw   → 4500 polls (15 min)

## 2.5.47 "flock lockfile open mode (noclobber compat)" 2026-06-02

Follow-up to v2.5.45's flock fix. The lockfile redirection
used `9>` (truncate-create), but aq's top-of-file `set -fC`
(noclobber) makes `9>` refuse to overwrite an existing file —
so the second arriving process, the very case this lock
exists to coordinate, failed with "cannot overwrite existing
file" before even reaching `flock`. Surfaced by snapcompose-
benchmark Phase 3 walking-skeleton re-run with v2.5.45
(run 26805826000, job 79022953872).

Switched to `9>>` (append). flock operates on the descriptor's
inode regardless of mode; append-mode is noclobber-safe and
preserves the previous contents (which are unused — lockfile
is empty by design).

## 2.5.46 "qmp_wait_migrate_incoming budget scales with staged memory" 2026-06-02

Companion to v2.5.45's par-cold fix. Surfaced by snapcompose-
benchmark Phase 3 walking-skeleton's `+1 seq cold` cell on
2026-06-02 (run 26804727138, job 79019327924). After VM #1
walked its chain successfully, VM #2 at the docker-compose
layer staged a 1.25 GiB concatenated memory.bin.zst from rlock's
chain reconstruction. QEMU's vmstate apply needed longer than
the historic fixed 60 s poll budget (300 × 200 ms), and
`qmp_wait_migrate_incoming` bailed before migration completed
with "Incoming migration did not apply".

The default now scales with the staged incoming memory size:
~150 polls per GiB on top of the historic 300 baseline. rails-
pg-sample (~500 MiB) keeps its existing budget; the bench
fixture's 1.25 GiB staging gets ~3.5 min — well within real
qemu apply time. Compressed input (`.zst`) is assumed at ~3×
expansion. Explicit `max_attempts` arg ($2) still overrides.

AQ_TIMING=1 prints the computed budget for visibility.

## 2.5.45 "flock around bootstrap_base_image (par-cold race)" 2026-06-02

Concurrent `aq new` invocations on a fresh cache used to race
`bootstrap_base_image`: both would see the per-size base file
missing, both would call `download_alpine_iso` (second wget
landed on `.iso.1`), and the parallel boot path would crash mid-
GRUB with `exit code 2`. Surfaced by the snapcompose-benchmark
Phase 3 walking-skeleton's `+1 par cold` cell on 2026-06-02
(run 26804727138, job 79019327904).

`ensure_base_image` now fast-paths the present-file case (no lock
acquisition) and, on absence, takes a `flock` on
`<base-dir>/<arch>/.bootstrap.lock` before bootstrap. Second
arrival blocks at the lock, then re-checks file presence after
acquiring — if the first arrival produced the base, skip our own
bootstrap entirely.

Host dependency: `flock` (from util-linux). Ubuntu / Debian ship
it in `util-linux`; macOS via `brew install flock` (Linuxbrew
formula). Add to host-deps documentation on the next README
sweep.

## 2.5.44 "AQ_CPU override for cross-host-family migration (R24 root cause)" 2026-05-28

R24 internal-error post-incoming-migration is root-caused: GH
ubuntu-latest runner pool mixes Intel (Xeon Platinum 8370C) and
AMD Azure SKUs. `-cpu host` exposed the SAVE host's vendor — if
save host was AMD with SVM in CPUID, the guest's `EFER.SVME` got
set to 1. On restore to an Intel host, that bit is reserved-MBZ in
IA32_EFER, so the first VM-entry fails with `KVM: entry failed,
hardware error 0x80000021` (VMX_INVALID_GUEST_STATE).

Diagnostic from CI run 26597337286 warm-zstd-patch (5):
```
EFER=0000000000001d01
   = SCE | LME | LMA | NXE | SVME(bit12, AMD-only)
KVM: entry failed, hardware error 0x80000021
If you're running a guest on an Intel machine without unrestricted
mode support, the failure can be most likely due to the guest
entering an invalid state for Intel VT. ...
```

Same failure mode is documented across QEMU bug trackers as the
canonical cross-CPU-family migration failure with `-cpu host` (RH
BZ #1961519, Debian #831761, kubevirt #5068, LP #2131822).

Fix: surface `AQ_CPU` env override. Default stays `host` (preserves
local dev / single-host workflows). Cross-host CI should set
e.g. `AQ_CPU=Skylake-Server-v4` so the guest CPUID never exposes
SVM regardless of underlying host vendor → guest never sets
EFER.SVME → migration works across the Azure pool. The
companion change in `setup-snapcompose` v3.0.7 wires this up
automatically on Linux runners.

Note: cached snapshots taken under the old `-cpu host` may have
SVME=1 baked into the saved vmstate. Bump the cache-key-prefix
when migrating to AQ_CPU, otherwise warm restores load stale
state and the same error persists.

## 2.5.43 "fast-fail on qemu internal-error state during cont (R24)" 2026-05-28

CI run 26580759406 surfaced a second post-incoming-migration failure
mode that the R23 widened cont budget can't fix: qemu enters
`internal-error` state (`{"status": "internal-error", "running":
false}`). That's a KVM-level migration apply failure, not a
transient — looping `cont` for 30 s yields the same result and just
wastes wall-clock.

Fast-fail with a clear diagnostic the moment `internal-error` is
seen, so callers know to retry the whole warm flow from cache
rather than wait out the cont budget.

Tracked as R24 in meta/TODO.md. Observed at ~1/10 rate on Azure
x86_64 KVM under nested Hyper-V; same code path on macOS HVF
always succeeds.

## 2.5.42 "wider cont retry budget after incoming migration (fix R23 flake)" 2026-05-28

After v2.5.41 replaced `-incoming exec:pzstd` with `-incoming file:`,
a different intermittent failure surfaced on Azure x86_64 KVM
warm restores: `Error: VM did not transition to running after 30
cont attempts` (~2/10 flake rate). The R20 inmigrate hang was
masking this — when the cont loop never ran, the post-migrate
transient state was invisible.

Root cause: under cross-host CI nested Hyper-V, qemu remains in a
transient post-incoming-migration state for longer than the
30 × 0.2 s = 6 s `cont` retry budget. The state eventually settles
to paused → cont accepted → running, but we exited the loop first.

Fix: bump the budget to 150 × 0.2 s = 30 s (`AQ_CONT_MAX_ATTEMPTS`
env override exposed for future tuning) and log the last
`query-status` response when the loop exhausts — so any
future failure leaves diagnostic breadcrumbs instead of a bare
"did not transition" message.

## 2.5.41 "decompress .zst to disk before -incoming (fix R20 cross-host migration hang)" 2026-05-28

### `-incoming exec:pzstd` → pre-decompress + `-incoming file:`

R20: on Azure x86_64 KVM under Hyper-V (GH `ubuntu-latest` runners),
`-incoming exec:pzstd -dc memory.bin.zst` reliably hangs in
`inmigrate` state for >60 s after the producer's EOF on ~1.7 GiB
memory images. 4/5 warm samples in benchmark-r17-r18 run
[26560684291](https://github.com/pirj/snapcompose-rails-pg-example/actions/runs/26560684291)
hit `Incoming migration did not apply after 300 polls`; the 1
passing sample took `migrate=18211ms` — wildly variable even when
it works. The `zstd-patch` path on the same fixture is 5/5 because
it reconstructs to a raw file first and then uses `-incoming file:`.

Hypothesis: `-incoming file:` lets qemu mmap the memory snapshot
(random access, no producer back-pressure); `-incoming exec:` forces
a pipe-driven read-chunk-then-apply loop that appears to deadlock
with KVM's vmstate apply path under Hyper-V nesting. The patch
path's `-incoming file:` always completes in ~1.6 s on the same
runner.

Fix: when `incoming-memory.bin.zst` is present, decompress it to
`incoming-memory.bin` BEFORE launching qemu, then use `-incoming
file:`. Behavior is now uniform across `zstd` and `zstd-patch`
memory modes: qemu always reads from a raw file via mmap.

Cost: M3 same-host warm restore goes from ~800 ms → ~926 ms (one
extra ~400 ms `pzstd -dc` pass to disk for a 1530 MiB raw memory).
Worth it for cross-host reliability.

Escape hatch: `AQ_ZST_STREAM_INCOMING=1` keeps the old
`-incoming exec:pzstd` behavior — for hosts where exec mode works
well and warm-restore latency is critical (e.g. local dev loops
on macOS HVF that have already established the path is fast).

New AQ_TIMING line `  AQ_TIMING: zst_decompress=Nms (raw=NN MiB)`
appears when AQ_TIMING is set so the decompression cost is
visible.

## 2.5.40 "fix R17 cross-host inject; ssh IdentitiesOnly when AQ_HOST_KEY set" 2026-05-28

### Cross-host warm restore inject no longer returns 0 bytes

R17 root-cause (cross-VM warm restore failing with "outfile size: 0
bytes" on Azure x86_64 KVM CI, also reproducible on M3 with
`AQ_HOST_KEY` pointing at a key NOT in the cached guest's
authorized_keys): two layered bugs in `inject_pubkey_via_serial`.

1. `socat - UNIX-CONNECT:sock <<<"$blob" &` — the here-string
   closes socat's stdin immediately, socat half-closes the UNIX
   side at its 0.5 s lingertime, and the guest's reply (which
   arrives ~100 ms later) lands on a closed socket. Confirmed
   experimentally on macOS HVF: 5 different invocation variants
   tested, all background patterns with synchronous EOF returned 0
   bytes; only writer-keeps-pipe-open patterns received guest
   output.

2. Sending `\nroot\n<cmd>\n` in a single write is racy on Alpine
   getty: when getty processes `root\n` and exec's `/bin/login`,
   login calls `tcflush(TCIFLUSH)` to discard pending input
   (a security measure against passwords typed ahead of the
   prompt). Any bytes sent after `root\n` and before the shell
   reads stdin get silently dropped, so the inject command never
   runs and the marker never echoes back.

Fix: hold socat's stdin open via a bidirectionally-opened fifo on
fd 9, and split the write into three phases:

  Phase 1a: `\nroot\n`, then poll for shell prompt (`# `).
  Phase 1b: `echo <ready_marker>\n`, poll for that marker — proves
            shell is actually reading from stdin (rules out the
            terminal-init `\e[6n` cursor-position-request race).
  Phase 2 : the actual `for d in /root /home/rlock; ...; echo <marker>`.

Measured on M3 with the rails-pg-sample fixture:
- Same-host probe-first path (K1 already in authorized_keys):
  unchanged at ~975 ms total, inject=76 ms (no-op).
- Cross-host inject path (forced via `AQ_HOST_KEY=<different-key>`):
  ~1700 ms total, inject=750 ms (the phase 1a→1b→2 cascade with
  inter-phase waits for ready signals).

### `AQ_HOST_KEY` now forces SSH to use ONLY that key

`aq_ssh_id_args` previously only added `-i $AQ_HOST_KEY`; ssh would
still fall through to ~/.ssh/id_* and ssh-agent identities, so when
the host's normal key happened to be in the guest's authorized_keys
the AQ_HOST_KEY override was silently ignored. Added
`-o IdentitiesOnly=yes -o IdentityAgent=none`.

This is also what made the R17 local repro possible — without this
fix, `AQ_HOST_KEY=k2` would still authenticate via the user's K1,
masking the cross-host code path.

## 2.5.39 "drop PATCH_DIAG instrumentation" 2026-05-28

R18 root-cause is identified (rlock chain-reconstruction logic bug,
fixed in rlock v0.1.11), so the encode-side PATCH_DIAG sha256
diagnostic in `aq snapshot create` is no longer needed. Removed.

## 2.5.38 "patch-from refs use single-thread zstd for determinism" 2026-05-27

CI re-bench against the 3-live-layer rails-pg-sample fixture
exposed an R18 (zstd-patch mode) failure: cold-zstd-patch
crashed with `Decoding error (36): Restored data doesn't match
checksum` right after the patch encoder finished. Same code
path works on M3.

Root cause: the patch decoder applies the .zstpatch against a
reference produced by decompressing the parent layer's
memory.bin.zst, then validates the result against the XXH64
checksum embedded by the encoder. Both encode and decode used
`pzstd -dc` when pzstd was on PATH. pzstd's parallel
decompression of large multi-frame archives has been observed
to produce output whose downstream patch-apply trips error 36
on ubuntu-latest CI runners — even though both invocations ran
on the same runner with the same pzstd binary. The reference
bytes weren't bit-identical between two consecutive `pzstd
-dc` runs of the same file.

Fix: use single-thread `zstd -dc` exclusively for patch-from
references in both `aq snapshot create` (encode) and rlock's
chain reconstructor (decode). Costs ~1 s extra wall-clock per
patch encode/decode (~1.5 GiB raw memory at zstd's ~1.3 GiB/s
single-thread); the encode side is buried in cold-build time
anyway, and the decode side already trades wall-clock for disk
under `AQ_MEMORY_SNAPSHOT=zstd-patch`.

The `pzstd -dc` fast path is unchanged for the default
`AQ_MEMORY_SNAPSHOT=zstd` mode — qemu's migration stream is
the direct consumer there, not a patch input, so byte-level
determinism between two reads of the same file doesn't matter.

## 2.5.37 "inject timeout 2s → 10s on cross-host" 2026-05-27

Bench against R17 fixture on ubuntu-latest CI exposed a
regression in v2.5.32's probe-first SSH path on cross-VM warm
restore:

1. probe-first SSH probe fails (host A's key baked into base,
   restored on host B with a different key) → ssh_already_ready=0,
   inject_pubkey_via_serial called. Probe counts as 1
   PerSourcePenalty failure.
2. inject sends the new key via serial. v2.5.31 trimmed the
   marker wait to 2 s for the M3 same-host case where the
   marker never appears (inject command is a no-op there).
3. On CI runners the marker DOES appear, but takes 3–5 s
   (slower login + slower bash). 2 s deadline expires before
   marker → inject returns 1 with "marker not seen", and
   importantly, kills the socat connection before the guest
   finishes appending the key to authorized_keys.
4. wait_for_ssh starts probing. K2 still not in
   authorized_keys → another 4 Permission denied failures →
   PerSourcePenalty hits 5 → "Not allowed at this time" banner
   → wait_for_ssh hits its 360-attempt cap and times out.

Fix: bump the inject deadline back to 10 s. The v2.5.31 trim
was correct for M3 same-host (which now short-circuits via
v2.5.32's probe-first, never reaching this code), but on
cross-host warm restore — the only case we still reach inject
in — the budget needs to cover slow Linux/CI runners.

## 2.5.36 "patch-mode bugfixes — noclobber + --long=31" 2026-05-27

Two bugs in v2.5.34's `AQ_MEMORY_SNAPSHOT=zstd-patch` path,
both surfaced by the first end-to-end multi-live-layer bench
on rails-pg-sample.

**noclobber on the patch-parent tmpfile.** `aq snapshot create`'s
patch branch decompresses the parent's `memory.bin.zst` into a
temp file via `mktemp` + `>`. Under aq's `set -fC` (noclobber),
`>` refuses to overwrite the just-created tmpfile and errors
out with "cannot overwrite existing file". Same shape as the
inject-loop bug fixed in v2.5.27. Fix: `>|` for explicit
truncation.

**zstd `--long=31` required on >128 MiB references.** Our typical
memory.bin is 1.6 GiB. `zstd --patch-from=<1.6 GiB file>`
compresses with a window large enough to cover the reference,
but the decoder (CLI default 128 MiB cap) refuses to decode any
frame whose declared window exceeds the cap — errors with
"Window size larger than maximum / Use --long=31". Pass
`--long=31` on both compress and decompress to bump the window
to 2 GiB. (rlock's chain reconstructor — v0.1.9 — needs the
same flag on its decompress invocations.)

Without these, v2.5.34's patch mode never produced a usable
artifact on any non-trivial workload.

## 2.5.35 "AQ_MEMORY_SNAPSHOT — single enum replaces two flags" 2026-05-27

**Breaking change.** Replace `AQ_NO_SNAPSHOT_COMPRESS=1` and
`AQ_MEMORY_PATCH_MODE=1` with a single enum env var:

    AQ_MEMORY_SNAPSHOT=raw      # uncompressed memory.bin
    AQ_MEMORY_SNAPSHOT=zstd     # DEFAULT — pzstd multi-frame
    AQ_MEMORY_SNAPSHOT=zstd-patch  # zstd --patch-from delta

The previous two boolean flags were mutually exclusive but
encoded as separate variables with implicit precedence, which
made the "which mode am I in?" question harder than it should
have been. One enum makes the trinary choice explicit at the
point of configuration.

`zstd-patch` still requires `AQ_PARENT_MEMORY_ZST=<path>` (it's
the data the patch is computed against, not a mode selector —
kept separate). aq now errors out at save time if patch mode is
requested without a valid parent reference, instead of silently
falling back to plain compression.

**Migration:** no aliases. `AQ_NO_SNAPSHOT_COMPRESS` and
`AQ_MEMORY_PATCH_MODE` are removed entirely. Replace in any
CI configs, dotfiles, or scripts:

    OLD                                 NEW
    AQ_NO_SNAPSHOT_COMPRESS=1     →     AQ_MEMORY_SNAPSHOT=raw
    AQ_MEMORY_PATCH_MODE=1        →     AQ_MEMORY_SNAPSHOT=zstd-patch
    (default)                     →     AQ_MEMORY_SNAPSHOT=zstd  (or unset)

rlock v0.1.7 (next) wires this through; rlock v0.1.6 still
reads `AQ_MEMORY_PATCH_MODE` and will silently produce plain
zstd snapshots if you bump aq without rlock. Bump both
together.

## 2.5.34 "zstd --patch-from save side (opt-in)" 2026-05-27

When `AQ_MEMORY_PATCH_MODE=1` and the caller passes
`AQ_PARENT_MEMORY_ZST=<path>` pointing to the parent live
layer's memory.bin.zst, `aq snapshot create` now emits the
new layer's memory as a zstd delta against the parent's
decompressed raw memory (`zstd --patch-from`). The artifact is
written as `memory.bin.zstpatch` and a sentinel file
`memory.format` recording the format.

### Measured trade-off on a 1.6 GiB raw memory (rails-pg-sample, M3)

Patch sizes against the same parent, varying the simulated
churn (random bytes, worst-case incompressible — real workloads
with structured page changes do better):

| Churn | Patch size | Save vs full pzstd (480 MiB) |
|---|---|---|
| 0 % (identical pages) | 0.4 MiB | 99.9 % |
| 1 % changed | 15.4 MiB | 97 % |
| 5 % changed | 76.4 MiB | 84 % |
| 10 % changed | 153 MiB | 68 % |
| 25 % changed | 384 MiB | 20 % |

Below ~5 % churn the patch is roughly the size of the changed
region itself — for typical stacked plugin layers that extend
an already-running container stack (postgres warm, redis
unchanged, app-server adds one process) the actual ratio is
expected to land in the 95–99 % range.

### Restore-side cost

| Path | Wall-clock on M3 |
|---|---|
| pzstd -dc full layer (baseline) | 422 ms |
| Patch chain: decompress base + apply 1 patch | 2162 ms (594 + 1568) |

A patched warm restore costs ~+1.7 s per chain step vs the
unpatched baseline. Chain depth doesn't divide — each
additional layer adds its own ~1.7 s. **For deep chains, plain
pzstd is the faster trade.** Patch mode is useful when:
- Cache push size / OCI transport bandwidth is the binding constraint, OR
- Chain depth is shallow (2–3 layers) AND most layers' churn is small.

### Default behaviour

Patch mode is **opt-in**: with `AQ_MEMORY_PATCH_MODE` unset (or
without `AQ_PARENT_MEMORY_ZST`), aq writes plain pzstd-compressed
memory.bin.zst exactly as v2.5.33 did. No format migration of
existing caches. The fast restore path is the default.

To skip compression entirely (fastest restore, no disk saving),
keep using `AQ_NO_SNAPSHOT_COMPRESS=1` from v2.5.21 — aq writes
raw memory.bin and `aq start` consumes it via `-incoming file:`.

Save side only in this release. Restore-side chain
reconstruction lives in rlock v0.1.6 (snapshot_walk_vm_rebase
walks back via meta.json's parent links to the oldest non-patch
ancestor, decompresses the base, applies forward patches, and
stages the result into vm_dir/incoming-memory.bin so aq's
`-incoming file:` consumer treats it like any plain memory
snapshot — no aq-side change needed for restore).

## 2.5.33 "pzstd multi-frame memory snapshots" 2026-05-27

Switch live-snapshot memory compression from `zstd -T0`
(single-frame) to `pzstd` (multi-frame, ~386 frames per 1.6 GiB
raw on our test fixture). pzstd writes a wire-compatible zstd
archive — old hosts and old caches keep working with `zstd -dc`
— but the multi-frame structure enables parallel decompression
on the restore side.

On restore, `aq start` now prefers `pzstd -dc` over `zstd -dc`
when both are present. Decompression of a multi-frame archive
runs at ~6 GiB/s aggregate on M3 (vs ~1.3 GiB/s single-thread),
so the migrate phase on rails-pg-sample drops from ~1.77 s to
~0.97 s — a 28 % wall-clock saving on a typical warm restore.

Fully backward compatible:
- pzstd -dc on a single-frame zstd file: falls back to single-thread, same speed as zstd -dc.
- zstd -dc on a multi-frame pzstd file: works, single-thread.
- AQ_NO_SNAPSHOT_COMPRESS=1 opt-out unchanged.

No new opt-in flag — pzstd is preferred whenever it's available
on PATH. On macOS Homebrew's `zstd` formula ships pzstd by
default. On Linux it's typically a separate package.

## 2.5.32 "BSD/locale fixes + probe-first SSH fast path" 2026-05-27

Three intertwined changes:

**Fix `head -c-7` BSD incompatibility.** The inject deadline
loop used `date +%s%N | head -c-7` to drop trailing nanoseconds.
`head -c-N` (all-but-last-N-bytes) is GNU-only; BSD `head`
errors with "illegal byte count". Under the error the comparison
received an empty string, the loop fell through immediately, and
inject phase reported ~80 ms on M3 — the loop literally never
iterated. On Linux/GNU CI it correctly waited the full 2 s
deadline. Replaced with pure bash arithmetic:
`$(( $(date +%s%N) / 1000000 ))`. Same intent, no subprocess,
no GNU dependency.

**Fix `$EPOCHREALTIME` locale-decimal-separator.** Bash 5's
`$EPOCHREALTIME` uses the C library's locale-aware decimal
separator. On macOS with a non-C locale (most users) it's "," —
`awk` parsed "1234567890,123" as 0. AQ_TIMING shipped in
v2.5.29 with all per-phase deltas reading 0 ms on macOS. Now
substitutes "," → "." via parameter expansion at every read:
`${EPOCHREALTIME//,/.}`.

**Probe-first warm SSH (skip inject + skip final wait_for_ssh).**
Once the head-c-7 fix makes the deadline loop honest, the
same-host warm path takes the full 2 s waiting for a marker
that never arrives — the inject command itself is a no-op
because the host's pub key is already in the guest's
authorized_keys (idempotent grep -qxF). Add a one-shot SSH
probe (`wait_for_ssh vm 1`) immediately after migrate. If it
succeeds, the key is already accepted: skip inject entirely
*and* skip the final wait_for_ssh (which would also succeed on
its first probe). If the probe fails, fall through to the
original inject + wait_for_ssh sequence — cross-host warm
restores keep working with at most one extra PerSourcePenalty
counter increment, well within the 5-failure budget. M3 same-
host warm path now has `inject=~80 ms` (the probe itself) and
`wait_ssh=0 ms` (skipped).

## 2.5.31 "inject timeout 10s → 2s + diagnostic dump" 2026-05-26

Cap the `inject_pubkey_via_serial` deadline at 2 s instead of 10 s.
The marker grep loop never fires in the common same-key warm path
(the inject command itself is a no-op because the host's pub key
is already in the guest's authorized_keys), so the loop ran to
deadline on every warm restore. CI Round 11 measurement showed
this as a flat 10 s spent waiting for output that would never
arrive. 2 s is enough headroom for the cross-host case where the
marker actually does appear (~500 ms typical).

When the deadline expires, dump the outfile head/tail + byte
count to stderr so cross-host inject failures surface their
underlying error (e.g. PerSourcePenalties banner, sshd not yet
listening) instead of just "marker not seen in 2 s".

## 2.5.30 "inject stdin via here-string" 2026-05-26

Replace `{ printf; sleep N; } | socat &` writer pipeline in
`inject_pubkey_via_serial` with a here-string: `socat ... <<<"$blob"`.
The previous form's `sleep` in the writer subshell held the
pipeline open for the full N seconds even after socat itself was
killed — `wait $pid` waited for the writer too. Here-string has
no writer subshell, so deadline-based termination actually works.

## 2.5.29 "AQ_TIMING env var" 2026-05-26

When `AQ_TIMING=1`, `aq start` emits a single-line summary of
the warm-restore phase breakdown: `qemu_launch`, `migrate`,
`inject`, `wait_ssh`, total — all in ms. Pure diagnostic, no
behaviour change. Used by `meta/bench-m3-pure-aq.sh` to isolate
where warm-restore wall-clock actually goes.

Known issue at this tag: on macOS with a non-C locale,
`$EPOCHREALTIME` uses "," as decimal separator, which awk
parses as 0 — so on macOS the per-phase deltas reported 0 ms.
Fixed in v2.5.32 alongside the `head -c-7` bug below.

## 2.5.28 "unified post-SETUP_ALPINE re-login + extract" 2026-05-26

Cold-path race fix on M3 aarch64: after `SETUP_ALPINE_OK` the
old code dropped the tio session, reconnected, then sent the
extract sequence. Between disconnect and reconnect the getty
respawned and the extract bytes were lost. Unify the post-
SETUP-ALPINE re-login + extract send + `AQ_EXTRACT_READY`
expect into ONE tio Lua script chain — single connection
across all three steps, no respawn window.

## 2.5.27 "noclobber + mktemp fix in inject" 2026-05-26

`inject_pubkey_via_serial` created its outfile via `mktemp` then
redirected with `>`. Under `set -fC` bash's noclobber refuses to
overwrite an existing file — mktemp had just created it. Use
`>|` to force-truncate. Without this fix the inject path errored
out before sending anything to the guest, masquerading as a
"marker not seen" failure.

## 2.5.26 "warm key-inject — marker-driven + drop sshd kick" 2026-05-26

Two improvements to the warm-restore key-inject path:

**1. Marker-driven serial inject** (replaces fixed sleeps).

The v2.5.23-25 inject used `sleep 1; sleep 1; sleep 1; sleep 3` =
~6 s timing margin. Replaced with a unique marker
(`AQ_INJECT_DONE_$PID_$RANDOM`) appended to the guest command;
host polls socat's captured stdout for that marker and proceeds
the moment it appears. Typical completion: ~300-500 ms vs the
prior 6 s. Expected savings: ~5 s on every warm restore.

**2. Drop `service sshd restart`** (v2.5.21 workaround).

That restart was added as a workaround for a hypothetical "silent
cold-boot fallback" mode where qemu reports `migration completed`
but the guest is actually fresh-booted. With the v2.5.23+ key
inject in place, the actual cross-host warm failure mode (ssh
auth fail → PerSourcePenalties cascade) is fixed at the source.
On a healthy warm restore sshd is already running from save
time; the restart is dead weight. If a future failure mode is
found that genuinely needs the kick, add it back behind an
env-var opt-in.

**3. `AQ_HOST_KEY` env var** for benchmarks/tests.

Path to a private key file; aq uses `.pub` sibling for the
guest's authorized_keys (cold setup-alpine bake + warm serial
inject) and `-i $AQ_HOST_KEY` for ssh client args. Falls back
to `$HOME/.ssh/id_*.pub` when unset. Lets benchmarks generate
disposable test keypairs without touching `$HOME/.ssh/`.

## 2.5.25 "extend key inject to /home/rlock too" 2026-05-26

The v2.5.23/24 key inject only updated /root/.ssh/authorized_keys,
but rlock's snapc-run uses ssh rlock@localhost (the unprivileged
'rlock' user, not root). rlock's _base plugin clones authorized_keys
from /root to /home/rlock at BASE-BUILD time — but cross-host warm
restore lands AFTER that clone, so the rlock user still has the SAVE
runner's pub key.

Loop over [/root, /home/rlock]: append host's pub key if missing,
preserve permissions, chown to the directory's owner.

## 2.5.24 "wait_for_ssh — revert TCP-first probe" 2026-05-26

The v2.5.23 TCP-first probe also tripped OpenSSH 10's
`PerSourcePenalties` `noauth` counter — each TCP open+close
counts as a connection abandoned before authentication. After
~3 probes × 10 s noauth penalty = 30 s threshold, sshd starts
dropping new connections.

Revert `wait_for_ssh` to the v2.5.22 ssh-probe loop. The key
insight (now documented in the function comment): with the
**key inject** from v2.5.23 in place (cold path bakes the host
key into authorized_keys via setup-alpine; warm restore appends
it via serial), the first ssh probe authenticates and the loop
exits before noauth can accumulate. The key inject is the
actual fix; the probe-loop redesign was unnecessary and worse.

## 2.5.23 "cross-host warm — ssh key + TCP-first probe" 2026-05-26

### Fix: cross-host warm restore now actually authenticates

The 2.5.21 sshd-kick was a workaround for the SYMPTOM
("Not allowed at this time" banner from the restored guest) but
not the actual cause. Investigation via in-guest serial commands
and `~/.ssh/id_ed25519.pub` side-by-side dump on save vs restore
runners pinned the real chain:

1. `aq new` on the SAVE runner generates K1, bakes K1.pub into
   the guest's `/root/.ssh/authorized_keys` via setup-alpine.
2. Cache packs `disk.qcow2` (with K1.pub baked) + `memory.bin`.
   The host's PRIVATE key K1 is per-runner and NOT in the cache.
3. RESTORE runner is a fresh Azure VM with a different K2.
4. After warm restore, `aq start`'s `wait_for_ssh` probe uses
   K2; the guest's sshd checks against K1.pub; auth fails with
   `Permission denied (publickey)`.
5. After ~5–10 failed auths from source 10.0.2.2 (the SLIRP
   gateway), OpenSSH 10's PerSourcePenalties activates. New
   connections from 10.0.2.2 are dropped with a
   `Not allowed at this time` banner BEFORE the SSH version
   exchange. The probe loop reads this as "ssh not yet up" and
   retries — each retry refreshes the penalty. Self-sustaining.

Two fixes:

**1. Inject host's pub key into guest's authorized_keys via
serial**, on the warm-restore path, before `wait_for_ssh`. The
existing post-restore serial block already logs in as root to
restart sshd; extended to also append `~/.ssh/id_ed25519.pub`
(or id_rsa/ecdsa fallback) to `/root/.ssh/authorized_keys`.
Idempotent via `grep -qxF` guard. No private keys are written
anywhere — cache stays free of secrets.

**2. Two-phase wait_for_ssh**: TCP-open probe via `/dev/tcp`
until the port accepts, then exactly ONE ssh attempt with auth.
Phase 1 generates zero ssh-protocol traffic for sshd to count
as misbehaviour; phase 2 succeeds because of fix (1). Failed
phase 2 is reported as a real error (key mismatch), not retried.

Same-host warm restart still works (idempotent inject is a no-op
when key already in authorized_keys). Cross-host warm restore
now works.

## 2.5.22 "qemu -D log file env var" 2026-05-25

### `AQ_QEMU_LOG_FILE` env var attaches qemu `-D <file>` to capture trace output

For diagnostic runs where you want qemu's own log (trace events
via `--trace ...`, migration internals) captured to file. Off by
default; opt-in via env var. After daemonize qemu's stderr goes
to `/dev/null`, so `-D <file>` is the only way to recover any
ongoing qemu output.

## 2.5.21 "kick sshd on warm restart" 2026-05-25

### Force sshd up via serial after live-restore — works around silent cold-boot fallback

Probing the guest after a cross-job warm snapc-run failure caught
qemu's `-incoming exec:zstd -dc` doing something subtle on
Linux/KVM: qmp reports `migration: completed` and `state:
running`, the cont loop succeeds, but the actual guest memory
state is FRESH (cold-booted from the snapshot's disk). Evidence:

```
Welcome to Alpine Linux 3.22
Kernel 6.12.91-0-virt on x86_64 (/dev/ttyS0)
alpine login: root                                ← fresh getty prompt
Welcome to your aq Alpine VM.
alpine:~# ps aux | grep -E "sshd|postgres|dockerd"
                                                  ← empty: NO snapshot processes
```

A live-restored guest would have resumed the snapshot's running
processes (sshd, postgres, dockerd at their original PIDs); a
cold-booted guest does not, and on the snapshot's frozen-mid-
runlevel disk, openrc doesn't always bring sshd back. The
host-side snapc-run's wait_for_ssh then sees nothing on hostfwd's
guest port, gives up after 3 min.

Same-job warm restart from file works perfectly (confirmed
2026-05-24 via diagnose-warm phase 4 — restored processes show at
original PIDs). So qemu's restore-from-file IS reliable; what
differs is _across hosts_: different machine, different runner,
different kvm-clock starting offset, different host kernel build.
Some combination causes the silent cold-boot fallback.

Pragmatic workaround: after migration+cont succeeds, send
`service sshd restart` via the serial-console socket before the
host-side wait_for_ssh runs. Costs ~2 s on the successful warm
path (sshd restart is a no-op-ish), unblocks the failure mode.

The cross-host live-restore silent fallback is still upstream-
worth investigating — possibly a kvm-clock pvclock state issue —
but until then this gets cold-warm CI green.

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

So tio v3.7 (what setup-snapcompose was building from source on
Linux) had `send(string)` for serial writes; v3.8 renamed it to
`write(string)` and re-purposed `send(file, protocol)` as the
XMODEM/YMODEM file-send helper. Homebrew's macOS tio is on v3.9,
where the script aq has been using all along (`write("root\n")`)
is correct.

- Revert v2.5.11. Restore `write("root\n")` in the login wait_for.
- Document the tio ≥ 3.8 requirement in the comment.
- aq itself requires no further change; the Linux fix is in
  setup-snapcompose, which now builds tio v3.9 from source instead
  of v3.7 (see setup-snapcompose CHANGELOG).

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
source (per setup-snapcompose's host_deps), hit the Lua mode, and
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
