# RFC: postcopy live restore for warm boot

- **Status**: proposed (experimental)
- **Author**: Phil Pirozhkov + Claude
- **Date**: 2026-05-27
- **Tracking issue**: aq/ROADMAP.md "Postcopy live migration for warm restore"

## Summary

Add an opt-in warm-restore path that uses QEMU's postcopy live
migration mode to drop the destination VM's "wall-clock until
SSH-reachable" from ~1.0 s (current pzstd-parallel best) to
~50–150 ms, in exchange for a 5–10 s window in which the guest's
working set is demand-paged from a host-side page server. Gated
behind `AQ_POSTCOPY=1`. Default off.

## Motivation

Round 16 (M3 full-stack `bake run` warm) is currently dominated
by the `migrate` phase: ~960 ms of the ~1100 ms aq-side cost,
i.e. ~87 % of aq's time. The bulk of that is QEMU's vmstate
apply (memory pages written into dest guest physical memory)
running in series with `pzstd -dc` decompression.

Postcopy resumes the destination VM **immediately** on near-empty
RAM, then satisfies guest page faults on demand by reading from
the source. On rails-pg-sample where the immediate working set
(postgres listener, app process, kernel) is a small fraction of
the 1.6 GiB captured memory, the resume can succeed before most
pages have ever been requested. Anything cold-paged later is
amortised against the actual workload's first reads.

Expected wall-clock outcome on M3 same-host: warm `bake run`
from ~1.85 s to ~1.0–1.3 s.

## Non-goals

- **Cross-host postcopy with arbitrary CPU/QEMU mismatches**.
  Vmstate compatibility constraints are unchanged from precopy
  (same CPU model / features within tolerance, same machine type,
  same QEMU version). Postcopy doesn't add new mismatch classes;
  it doesn't fix existing ones either.
- **Lifting the QEMU 10.0.3 pin**. Independent issue. See ROADMAP
  on the 11.0.0 aarch64 HVF live-restore assertion.
- **General-purpose live migration tool**. We only need
  file-to-process restore, not host-to-host.

## Background: how postcopy works (file source flavour)

QEMU postcopy has two halves:

1. **Source side** is a "page server" — typically another QEMU
   process running the source VM, but for our file-based use
   case a small daemon that owns a file descriptor on
   `memory.bin` and serves page requests through a UNIX socket.
2. **Destination side** starts QEMU with `-incoming defer`,
   then via QMP:
   - `migrate-set-capabilities postcopy-ram on`
   - `migrate-incoming "unix:/path/to/source.sock"`
   - small precopy phase transfers CPU state + device state +
     a minimal page set
   - `migrate-start-postcopy`
   - destination VM resumes; subsequent guest accesses to
     unfaulted pages trap via `userfaultfd(2)` and the
     destination requests them from the source over the socket.

After the postcopy phase begins, the destination's RAM grows
from near-empty to full as the guest touches pages. For typical
workloads this stabilises in 5–10 s; pages never touched (zero
pages, unused page cache) are never transferred.

## Design

### File layout

No new on-disk artifacts. `memory.bin` / `memory.bin.zst` /
`memory.bin.zstpatch` already in the cache layout (see
`AQ_MEMORY_SNAPSHOT` enum in v2.5.35) are the source for the
page server.

For `AQ_MEMORY_SNAPSHOT=zstd` or `zstd-patch`, the source needs
the **decompressed** memory.bin. Two options:

- **Eager decompress to a tmpfile**, then mmap. ~1 GiB ramfile
  on disk for the lifetime of the resumed VM. Simple. Reuses
  existing decompress path.
- **Streaming decompress as pages are requested**. Saves the
  tmpfile but requires a frame-aware reader (pzstd's multi-frame
  format makes this feasible per-frame). More complex.

Initial implementation: **eager decompress + mmap**. Cost: ~500 ms
upfront decompress (parallel with pzstd) + 1 GiB ephemeral disk
in `$BASE_DIR/<vm>/postcopy-source-memory.bin`. Removed when
`aq stop` runs.

### Page server process

A new program (or `aq` subcommand) running alongside the dest
QEMU:

```
aq _postcopy_serve <vm-name>  # internal subcommand
```

Steps:
1. Locate `$BASE_DIR/<vm>/postcopy-source-memory.bin` (or
   decompress source to tmpfile if missing).
2. Open a UNIX socket at `$BASE_DIR/<vm>/postcopy.sock`.
3. Wait for QEMU's destination connection.
4. Speak QEMU's migration wire protocol (legacy, not multifd;
   postcopy uses the v3 migration channel).
5. Exit cleanly after destination signals end of postcopy.

Alternatively: **let QEMU itself act as both sides**. Start a
"source" QEMU bound to `memory.bin` (read-only, paused, never
runs), let the dest QEMU connect to it for postcopy. Simpler in
that we don't write a wire-protocol speaker; cost is a transient
~50 MiB of QEMU overhead for the source side. Probably the right
v1 implementation.

### aq_start integration

Inside `aq_start`, when `${AQ_POSTCOPY:-}` is set AND an
`incoming-memory.bin*` file is present:

1. Spawn the source QEMU with the memory file (paused).
2. Launch the dest QEMU with `-incoming defer` instead of the
   current `-incoming exec:pzstd -dc <file>`.
3. Connect via QMP, do the postcopy handshake.
4. Once `migrate-start-postcopy` returns, the dest VM is
   resumed. Proceed with the existing post-migrate code (probe
   SSH, etc.).
5. Track the source QEMU process; tear it down via
   `aq stop` / `aq rm`.

### Failure modes

- **Source QEMU dies during demand-page window**. Next page
  fault → destination QEMU's userfault thread blocks forever →
  guest hangs at next memory access. **Mitigation v1**: print
  a clear error to stderr (via QMP migration events) and
  promote to a hard fail. The user re-runs with `AQ_POSTCOPY=`
  unset, which falls back to precopy.
- **Source memory file becomes unreadable**. Same as above.
- **Destination guest panics on missing CPU feature**. Same as
  precopy. Not specific to postcopy.

## Hardware / vmstate compatibility

**Identical to precopy.** Same vmstate format, same
machine/CPU constraints. Mainly:

- CPU model & feature flags must match (with `-cpu host`, the
  save-side host's features become the guest's view; restoring
  on a host with a strict subset of features fails iff the
  guest actually used a missing feature). For our workloads
  (postgres, docker, node) this is essentially never triggered
  on Apple Silicon M2/M3/M4.
- Machine type, RAM size, attached devices must match.
- QEMU minor version compatibility (we pin 10.0.3).

No new restrictions vs the existing precopy path.

## Performance expectations

| Path | Wall-clock to VM resumed | Wall-clock to SSH-reachable |
|---|---|---|
| Current precopy (R16 on M3) | ~960 ms | ~1100 ms |
| Postcopy v1 (eager decompress + source QEMU) | ~500 ms (precopy small set) + ~50 ms handshake | ~100–250 ms (SSH probe + demand-page first few pages) |
| Postcopy v2 (streaming decompress, no tmpfile) | ~50 ms handshake | ~100–250 ms |

Steady-state (after working set faulted in): identical to
precopy in throughput.

## RAM footprint

| Mode | Peak host RAM during resume |
|---|---|
| precopy | ~2.1 GiB (file in OS cache + dest VM gradually growing to 1.6 GiB during apply) |
| postcopy v1 | ~2.5 GiB (file 480 MiB + decompressed tmpfile 1.6 GiB on disk page-cached + dest VM growing) |
| postcopy v2 (streaming) | ~2.1 GiB (same as precopy) |

**Not 2×**. The ~400 MiB overhead in v1 is the decompressed
tmpfile being page-cached. Goes away if we evict it after
postcopy completes (handler closes file → kernel evicts when
needed).

## macOS HVF caveat (verification needed)

Postcopy depends on `userfaultfd(2)`, a Linux-specific
syscall. **Whether QEMU's HVF backend supports postcopy at all
is unknown to me at design time.** Pre-implementation
verification:

```sh
qemu-system-aarch64 -accel hvf -m 1G -nographic \
  -incoming defer -qmp unix:/tmp/postcopy-test.qmp,server=on,wait=off \
  & QEMU_PID=$!
# In another terminal, via QMP:
{"execute": "migrate-set-capabilities", "arguments": {"capabilities": [{"capability": "postcopy-ram", "state": true}]}}
# Expected: success.
# If error: postcopy-ram unsupported on HVF — RFC closes, Linux-only support.
```

If unsupported on HVF, this RFC ships **Linux-KVM only**. Same
fallback: `AQ_POSTCOPY=1` warns and uses precopy on macOS.

## Implementation plan

1. **Verify HVF postcopy capability** (10 min). If unsupported,
   mark RFC Linux-only and proceed; if supported, proceed for
   both platforms.
2. **Write `aq _postcopy_source` subcommand** (~100 lines) —
   spawn paused source QEMU bound to a memory file, expose a
   UNIX migration socket. ~1 day.
3. **Wire `AQ_POSTCOPY=1` into `aq_start`** — branch around
   `-incoming exec:` to use `-incoming defer` + QMP postcopy
   handshake instead. ~150 lines. ~1 day.
4. **Manage source QEMU lifecycle** — track its PID in
   `$BASE_DIR/<vm>/postcopy-source.pid`; `aq stop`/`aq rm`
   kill it. ~50 lines. ~half day.
5. **Test under R16 fixture** (rails-pg-sample) — bench
   wall-clock + RAM peak; verify guest works after
   demand-paging stabilises. ~half day.
6. **Document** in CHANGELOG + README env-vars table. ~hour.

Total: ~3 days of focused work + verification.

## Open questions

- **Cross-host postcopy via OCI cache**: do we want this? If yes,
  the source-side memory file must travel with the cache
  (already does as memory.bin.zst). No additional protocol
  needed. The dest host decompresses and starts a source QEMU
  locally — that's the same model as same-host postcopy. So:
  works for free.
- **Combining with `AQ_MEMORY_SNAPSHOT=zstd-patch`**: chain
  reconstruction (rlock side) produces a raw memory.bin in
  vm_dir. Postcopy source uses that directly. No protocol
  conflict.
- **What if the guest is idle?** Postcopy's win is largest when
  the guest's immediate working set is small. For idle guests
  (compose stack waiting on connections), most pages are never
  touched → postcopy wins big. For batch jobs that page through
  all memory immediately (e.g. starting a JVM with -Xmx4G), the
  demand-page storm flattens the win. Workload-dependent.

## Decision

Mark as **experimental**. Default off. Ship behind `AQ_POSTCOPY=1`.
Encourage testing on dev loops where wall-clock matters more than
the demand-page window. Re-evaluate after a few weeks of real-
world data on M3 + CI.
