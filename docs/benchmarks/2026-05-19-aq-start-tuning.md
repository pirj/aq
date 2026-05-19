# aq warm `aq start` — QEMU tuning sweep

**Date:** 2026-05-19
**Host:** GitHub-hosted `ubuntu-latest` runner (x86_64 + KVM)
**QEMU:** 9.0.2 (Ubuntu noble package, default Ubuntu config)
**Guest:** Alpine 3.22.2, `linux-virt` kernel
**Disk:** size-2G base, qcow2 overlay
**SSH probe cadence:** 0.1 s (`AQ_SSH_PROBE_INTERVAL=0.1`)
**Sample size:** n=10 per configuration, warm base (pre-built once)

## Background

After v2.4.0 "Bolt" (direct kernel boot) and v2.5.1 "Polish" (probe-cadence
tightening from 2 s to 0.5 s), warm `aq start` on Linux KVM lands around
6.5–7.5 s. The roadmap had three lingering "what about..." questions worth
answering with data before declining:

1. **`aio=io_uring` / `aio=native`** — would async I/O help boot time?
2. **`-smp 2`** — would two vCPUs let OpenRC parallelize?
3. **Kernel cmdline tweaks** — `tsc=reliable`, `no_timer_check`, `nokaslr`.

The benchmark harness (`tests/bench-aq-start.sh` + `.github/workflows/bench.yml`)
sweeps these on the runner.

## Results

| label         | what                                            | min ms | **median ms** | max ms |
|---------------|-------------------------------------------------|--------|---------------|--------|
| `baseline`    | QEMU defaults (writeback cache, threads aio)    | 6368   | **6898**      | 7746   |
| `io_uring_wb` | `aio=io_uring` + writeback cache                | 6581   | **6905**      | 7348   |
| `io_uring_d`  | `aio=io_uring,cache.direct=on` (canonical)      | 6369   | **6939**      | 7800   |
| `native_d`    | `aio=native,cache.direct=on` (POSIX AIO)        | 6481   | **7005**      | 7430   |
| `threads_d`   | `aio=threads,cache.direct=on` (isolate flag)    | 6268   | **7111**      | 7752   |
| `smp2`        | `-smp 2`                                        | 6584   | **7216**      | 7749   |
| `kcmd`        | `tsc=reliable no_timer_check nokaslr` appended  | 6370   | **7211**      | 7751   |

All medians fall within ±320 ms (≤5 %) of baseline. Per-config IQRs are
~1 000 ms — wider than the inter-config spread.

## Conclusion

**None of the tested tweaks measurably beat the QEMU defaults for warm
`aq start`.** The defaults (writeback cache + threads aio + 1 vCPU + stock
Alpine cmdline) are at least as fast as any configuration tried.

Why each candidate failed to help:

- **`aio=io_uring` / `aio=native`** — warm boot does very little disk I/O.
  The kernel and initramfs are loaded by QEMU directly from the host
  filesystem (page-cached); the first userspace reads (init, OpenRC
  scripts) are also page-cache hits because the base file just got
  touched by the previous warmup boot. There's nothing for async I/O to
  speed up.
- **`cache.direct=on`** — slightly *slower* by ~100–200 ms median. Forcing
  O_DIRECT bypasses the host page cache, which is exactly the wrong move
  when the workload re-reads the same blocks every boot.
- **`-smp 2`** — Alpine's OpenRC defaults to `rc_parallel=NO`, so a
  second vCPU finds little parallel work during boot. Adding it costs
  more in QEMU startup and KVM vCPU thread coordination than it gains.
- **Kernel cmdline tweaks** — `tsc=reliable` and `no_timer_check` shave
  ms-scale calibration; `nokaslr` saves ~tens of ms. Below our probe
  resolution and below natural variance.

## What actually moved the needle

The probe-cadence tightening in v2.5.1 (2 s → 0.5 s in `wait_for_ssh`) was
the largest measured win on this hardware: pre-change runs averaged 8 250
ms (probe rounding dominated); post-change runs average ~6 900 ms — a
real ~1.3 s shaved off `aq start` wall time per invocation.

## Where the remaining ~7 s goes

Per the v2.4.0 benchmark doc breakdown (M3 / HVF), the warm-boot budget is
roughly:

| Phase                                 | ms    |
|---------------------------------------|-------|
| QEMU spin-up + virtual-HW init        | ~1500 |
| Direct kernel boot to userspace       | ~2000 |
| OpenRC service start through sshd     | ~2000 |
| `wait_for_ssh` probe-rounding tail    | ~500  |
| Host-side `aq` overhead               | ~500  |

To shave more, the leverage points are:

- **OpenRC → custom init / lazy services** — biggest single chunk;
  ergonomic risk (no service supervisor for users who actually want one).
- **`microvm` machine type + virtio-mmio** — skips PCI and a lot of legacy
  init; requires switching device strings end-to-end (drive, net) and
  losing UEFI compatibility. Not just a `-machine` override.
- **Live-snapshot fan-out** — already supported (v2.3.0). For "I want
  this VM running again right now" workflows, restoring from a live
  snapshot is sub-second and skips the whole boot.

## Decision

- **Keep QEMU defaults on Linux.** Do not flip the storage `-drive`
  to `aio=io_uring` or `aio=native`.
- **Keep the env-var hooks** (`AQ_DRIVE_EXTRA`, `AQ_QEMU_EXTRA_ARGS`,
  `AQ_MACHINE_OVERRIDE`, `AQ_KERNEL_APPEND_EXTRA`) — they cost
  nothing when unset and let future investigations re-run the sweep.
- **Roadmap items** "aio=native/io_uring" and "use cache=none for normal
  runs, too?" can move to "Declined" with this measurement as the
  source.
