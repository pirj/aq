# aq vs the alternatives

This doc is for "I need a clean Linux somewhere — what's the trade-off vs Docker / Podman / macpine / OrbStack / virsh?". It frames the comparison around the simplest equivalent of what aq does: a one-shot SSH-reachable Linux that you can drop into and run commands.

The roadmap calls out [`panubo/sshd`](https://github.com/panubo/docker-sshd) (GitHub repo is `panubo/docker-sshd`; Docker Hub image is `panubo/sshd`) as the canonical container-side analog — an Alpine image with `sshd` baked in. Most of the comparison treats *that* as the Docker-side reference, not "Docker in general", because aq is "single Linux you ssh into", not "twelve microservices in a compose file".

## TL;DR

| Need                                                  | Pick                                  |
|-------------------------------------------------------|---------------------------------------|
| Hermetic kernel-level isolation; full root inside     | **aq** (or virsh/libvirt at scale)    |
| Sub-second startup, sharing host kernel is fine       | Docker / Podman                       |
| Throwaway dev sandbox on macOS that "just works"      | OrbStack (proprietary) or **aq**      |
| Reproducible, declarative VM provisioning at scale    | virsh + cloud-init                    |
| Lots of Alpine VMs on macOS, OSS                      | macpine or **aq**                     |
| Fan out N parallel workers from one provisioned state | **aq fanout** (live snapshots)        |

aq is in the "system container" lane: every instance has its own kernel, its own `/proc`, its own loaded modules. That costs ~5 s of warm start and a ~150 MB base. Containers skip both costs because they share the host kernel.

## At-a-glance comparison

| | **aq** | panubo/sshd | plain Docker | Podman | macpine | OrbStack | virsh/libvirt |
|---|---|---|---|---|---|---|---|
| Type | Full VM (QEMU) | OCI container | OCI container | OCI container | Full VM (QEMU) | Full VM + container runtime | Full VM (QEMU/KVM) |
| Guest kernel | own | shared host | shared host | shared host | own | own (shared Linux VM) | own |
| Host platforms | macOS-aarch64, Linux-x86_64 | anywhere Docker runs | anywhere Docker runs | Linux + macOS via VM | macOS only | macOS only | Linux only |
| Default image size | ~150 MB (Alpine + linux-virt) | ~13 MB (Alpine + openssh) | varies | varies | similar to aq | ~50 MB shared rootfs | depends on cloud image |
| Cold first start | ~30 s (per-size base build) | <1 s (after `docker pull`) | <1 s | <1 s | ~30–60 s | ~2–5 s | varies |
| Warm subsequent start | **cold 4.2 s (M3) / 6.7 s (GH KVM); live 680 ms (GH KVM)** | **142 ms (GH KVM)** | ~1–2 s | **96 ms (GH KVM)** | **18.5 s (M3)** | sub-second (claimed) | **16.5 s (GH KVM)** |
| Snapshot (cold) | yes; raw+qcow2 chain | image commit (heavier) | image commit | image commit | no first-class | yes | qcow2 internal |
| Snapshot (live, w/ memory) | yes (v2.2.0) | no (would need CRIU) | CRIU possible, fiddly | CRIU possible | no | no | yes (savevm) |
| Fan out N from one state | `aq fanout TAG N -- cmd` | image+exec | image+exec | image+exec | no first-class | no | manual |
| Overlay model | qcow2 backing-file | filesystem layers | filesystem layers | filesystem layers | qcow2 | qcow2 + layered FS | qcow2 |
| Isolation strength | hypervisor | namespaces+cgroups | namespaces+cgroups | namespaces+cgroups | hypervisor | hypervisor (for outer Linux) | hypervisor |
| Network model | SLIRP user-mode (NAT) | bridge or host | bridge or host or none | bridge or host | SLIRP or vmnet | bridge | bridge/NAT/...|
| Data sharing | `aq scp`, `aq exec`, port forwarding | bind-mount `-v`, `docker cp` | bind-mount, cp, named volumes | bind-mount, cp | mount fwd | bind-mount + virtfs | virtfs/9p/NFS |
| Required to install | one bash script + qemu/socat/tio | dockerd | dockerd | podman | macpine + qemu | OrbStack | libvirt + virsh + qemu |
| Licensing | MIT | MIT | Apache-2 (container only; Docker Desktop is proprietary on macOS) | Apache-2 | MIT | proprietary | LGPL |
| Daemon required | no | yes (dockerd) | yes (dockerd) | no (rootless) | no | yes | yes (libvirtd) |
| Rootless | n/a (no daemon) | possible (Docker rootless) | possible | yes (default) | n/a | n/a | yes (qemu:///session) |

Where a row is concrete it's measured or quoted from upstream; where it's "varies" or italicised it's a fair estimate, not measured. The aq numbers come from `docs/benchmarks/2026-05-19-aq-start-tuning.md`.

## The axis-by-axis breakdown

### Disk footprint

Containers win comfortably. `panubo/sshd` is roughly 13 MB compressed (Alpine + openssh-server + a handful of busybox extras). aq's size-2G base hovers around 130–200 MB because it carries a real kernel, a real init system (OpenRC), and a real userland that mounts a real ext4 root.

That said, the *delta per instance* is similar: both rely on copy-on-write. aq's per-VM `storage.qcow2` typically stays under 200 MB until you actually fill it; Docker's per-container writable layer behaves the same.

### Cold/warm start time — measured

Two benches on two pieces of hardware. Each ran the same `aq` script side by side with the alternative, so the numbers are directly comparable *within* a row block — not across blocks (M3 HVF is faster than the GH Linux runner).

**Linux GH `ubuntu-latest` (x86_64 KVM)**, n=10 (n=5 for `virsh_start`), 100 ms probe cadence:

| target | min | **median** | max | vs `aq_cold` |
|---|---|---|---|---|
| `aq_cold` — `aq new --size=2G` + `aq start` | 6363 ms | **6695 ms** | 7127 ms | 1× (baseline) |
| `aq_live` — `aq new --from-snapshot=<live-tag>` + `aq start` | 678 ms | **680 ms** | 687 ms | **~10× faster** |
| `docker_sshd` — `docker run -d -p :22 panubo/sshd` → TCP-accept | 137 ms | **142 ms** | 353 ms | ~47× faster |
| `podman_sshd` — `podman run -d -p :22 docker.io/panubo/sshd` → TCP-accept | 92 ms | **96 ms** | 815 ms | ~70× faster |
| `virsh_start` — `virsh start <dom>` on Alpine cloud qcow2 (cloud-init pre-warmed) | 16274 ms | **16501 ms** | 16791 ms | ~2.5× *slower* |

**Apple M3 HVF (aarch64)**, n=5 unless noted, 100 ms probe cadence:

| target | min | **median** | max | vs `aq_cold` |
|---|---|---|---|---|
| `aq_cold` — `aq new --size=2G` + `aq start` | 3940 ms | **4163 ms** | 4383 ms | 1× (baseline) |
| `aq_live` (HVF, **patched** QEMU v11.0.0 + upstream fix `06fd39e426`) [n=3] | 645 ms | **645 ms** | 651 ms | **~6.5× faster** |
| `aq_live` (HVF, stock brew QEMU 11.0.0) | — | *fails — upstream ARM regression* | — | n/a |
| `macpine_start` — `alpine launch` + warm-up, then loop `alpine start <vm>` | 14401 ms | **18461 ms** | 18606 ms | ~4.4× *slower* |
| OrbStack | — | *no CI path; published sub-second figure not independently verified* | — | n/a here |

The patched-QEMU live-restore row is interesting: **645 ms on M3 HVF beats the 680 ms on GH Linux KVM** — same fix unblocks parity across both backends. See `tools/qemu-livesave-repro/` for the reproducer + patch.

Source: `.github/workflows/bench-vs-docker-sshd.yml`, `bench-vs-virsh.yml`, and the `tests/bench-*.sh` scripts. M3 numbers are local-machine measurements.

Five things worth pointing out:

1. **aq live-snapshot restore is genuinely sub-second.** 680 ms median, *9 ms spread* across 10 runs — the most stable bench in any of the tables. QEMU's `-incoming` reads the captured memory image straight back into RAM, skipping the whole kernel-boot + OpenRC + sshd-start path. The remaining 680 ms is QEMU init + memory replay + `cont` + the SSH probe round.
2. **Live snapshots close the cost-of-VM gap from ~47× to ~5×.** Once you've provisioned a VM and snapshotted it running, every subsequent fan-out lands in ~0.7 s — competitive with containers for workflows where you can amortise the provision-once cost. The aq fanout primitive (v2.3.0) does exactly this, spawning N parallel VMs from one live snapshot.
3. **aq is ~2.3–4.4× faster than other QEMU wrappers on the same hardware.** vs `virsh` on Linux (7.2 s → 16.5 s) and vs `macpine` on macOS (4.2 s → 18.5 s). The big delta is direct-kernel-boot (v2.4.0) vs the full UEFI/SeaBIOS bootloader + cloud-init path that both libvirt-managed cloud images and macpine's stock Alpine images go through.
4. **Podman is a touch faster than Docker** (96 vs 142 ms median), with one outlier run (815 ms — likely first-run storage initialization). Both run-to-TCP-accept times are dominated by sshd binding to port 22 inside the container, not by the container runtime itself.
5. **`aq_live` on macOS HVF is currently blocked** by an upstream QEMU 11.0.0 regression in the ARM migration code (`target/arm/machine.c:1045: cpu_pre_load: !cpu->cpreg_vmstate_indexes`). Cold snapshots and Linux KVM x86_64 are unaffected. Tracking through QEMU upstream; no aq-side workaround.

Cold-cold (image pull / base build / cloud-init first-boot) is excluded from the loop because every system amortises it differently:

- **aq cold first build per size**: ~30 s. Caches per `(alpine-version, arch, size)`; subsequent same-size `aq new` skips it.
- **`panubo/sshd` first pull**: ~3–5 s on a fast connection. Cached by the container runtime; subsequent runs skip it.
- **virsh** first boot: cloud-init takes ~30 s on top of the kernel boot to provision SSH keys via NoCloud. The bench warms this up once before the timed loop.
- **macpine** first launch: ~30 s for image download + first boot. Once an instance exists, `alpine start` reuses it.

The takeaway:

- "Fastest from zero to interactive shell": containers (~100 ms).
- "Fastest once you've provisioned": still containers, but **aq's gap collapses to ~5×** via live snapshots.
- "Fastest *full* VM": aq, on both Linux KVM and macOS HVF; ~2.3× vs virsh, ~4.4× vs macpine.
- "Fastest *and* I want a full kernel + the host kernel not to be exposed to whatever runs inside": **aq live restore**, no contender in any of the tables.

### Isolation

Docker / Podman share the host kernel via namespaces and cgroups. A guest kernel vulnerability isn't reachable because there is no guest kernel; conversely, a host kernel vulnerability *is* shared. Containers leak less than people assume but more than VMs.

aq, macpine, OrbStack, virsh all run a *separate* Linux kernel under the hypervisor (HVF on macOS aarch64, KVM on Linux x86_64). Escape requires a hypervisor bug, not a kernel bug. For workloads where you don't fully trust what runs inside (CI for arbitrary repos, evaluating third-party code, multi-tenant runners), VMs are the safer default.

### Configurability at runtime

Both containers and aq let you pass options at start time. The shapes differ:

- aq: `aq new --size=8G --memory=4G -p 8080:80 my-vm`
- docker-sshd: `docker run -d --memory=4g -v $PWD/keys:/etc/authorized_keys:ro -p 8080:80 panubo/sshd`

Disk size for aq is fixed at base-build time per size; you can pick any `--size=NG` and aq will build it once. Docker images are not size-aware at start — the writable layer can grow until the host disk fills.

Memory: aq pins memory at boot (`--memory=NG`) and matches it on snapshot restore. Docker takes `--memory` as a cgroup limit on a fluid pool — different semantics, but the user-visible effect is similar for steady-state workloads.

### Reproducibility

Containers nailed this with the `Dockerfile` + content-addressed layer cache. There's no equivalent declarative artifact in aq — provisioning happens via `aq exec` from a shell. Snapshots are aq's reproducibility primitive: provision once, snapshot, then `aq new --from-snapshot=TAG` to land in the same state. It's content-addressable in spirit, not in tooling.

If you need "rebuild byte-identical on N machines": stick with Docker. If you need "land in the exact same state I had ten minutes ago": aq snapshots are equivalent or better (live snapshots restore TCP connections and tmpfs too).

### Horizontal scalability — fan-out from one provisioned state

This is where aq has a feature most containers don't ship: **live-memory snapshots + `aq fanout`**. You provision one VM, snapshot it running, then `aq fanout TAG 8 -- /workload` spawns 8 VMs that *resume* from the captured memory state in ~1 s each. Each gets `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` in its env so a test runner can pick its slice.

Container equivalent: `docker run` the same image N times and pass `--env SHARD_INDEX=$i`. That works fine for stateless workloads, but you re-pay the boot/init cost N times and can't share warm caches, JIT state, loaded models, etc. For workloads where startup is dominated by "load 4 GB of weights into RAM", a live snapshot fan-out is dramatically faster (sub-second vs minutes).

CRIU can do something analogous for containers but is fiddly to set up and brittle across kernel versions; nobody ships it as a default user-facing feature.

### Sharing data with the host

aq's primary surface is SSH-shaped: `aq scp file.txt vm:/path`, `aq exec vm cmd`, port forwards via `-p`. Mount-style sharing isn't built in; if you need it, host directly via virtfs/9p is a TODO (no roadmap item yet).

Containers default to bind mounts: `-v $PWD/src:/src` and the container reads directly from the host fs. Cheaper and lower-friction for typical dev loops. OrbStack on macOS does the same but with much better cross-fs performance than Docker Desktop.

### Snapshots / overlays

| | cold snapshot | live (w/ memory) | overlay/COW |
|---|---|---|---|
| **aq** | yes (raw → qcow2 backing chain) | yes (since v2.2.0, restores tcp+tmpfs+procs) | yes (qcow2 overlay per VM) |
| Docker | image commit | no (CRIU is external and brittle) | yes (overlayfs layers) |
| Podman | image commit | no | yes |
| macpine | not first-class | no | yes (qcow2) |
| OrbStack | yes (image snapshots) | no | yes |
| virsh | yes | yes (`virsh save/restore`, `snapshot-create`) | yes (qcow2 internal snapshots) |

If "save the running state of this thing and restore it on N machines" is a requirement, aq and virsh are the only mainstream choices with a first-class story.

## When to pick aq

- You want a real, isolated Linux to play in.
- You're on macOS Apple Silicon and don't want Docker Desktop's licensing/footprint, or Linux with KVM.
- You want fast fan-out from a provisioned state (live snapshot + `aq fanout`).
- You'd rather edit a 1.8 kloc bash script than chase libvirt config.

## When *not* to pick aq

- You ship microservices that need declarative compose / k8s. Use containers.
- You need sub-second cold start for short tasks (CI jobs that run for ten seconds). Containers win.
- You need 9p/virtfs-style host-fs sharing right now. aq doesn't expose this yet.
- You need Windows or macOS guests. aq is Alpine-only by design.

## Footnotes & methodology

- All measured medians come from real CI / hardware:
  - **GH `ubuntu-latest` KVM (x86_64)**: aq cold, aq live, docker-sshd, podman-sshd, virsh. `.github/workflows/bench-vs-docker-sshd.yml` + `bench-vs-virsh.yml` drive `tests/bench-*.sh` on the same runner.
  - **Apple M3 HVF (aarch64)**: aq cold, macpine. Local-machine measurements with the same 100 ms probe cadence; not in CI because GH `macos-latest` is itself a VM and doesn't expose Hypervisor.framework.
- Container benches probe via TCP-accept on the bridged host port (which iptables only forwards once the container's sshd is bound). VM benches that use QEMU user-mode networking probe via *real SSH handshake* — TCP-accept on a QEMU SLIRP hostfwd lights up the moment QEMU starts (long before guest sshd is ready), so a `nc -z` probe would record nonsense (~50 ms regardless of guest state). The macpine bench learned this the hard way.
- **OrbStack** isn't measured because (a) it requires GUI license acceptance on first run, so it can't be driven headless in CI, and (b) the only hosted macOS runner available without paying for the "large" tier has no nested virt, so even if we could automate setup the numbers would be TCG-emulation, not HVF. The "sub-second (claimed)" cell is the upstream marketing claim — no independent measurement.
- **`virsh` first-boot cloud-init** runs once in the prelude (untimed). The timed loop is `virsh start` → SSH-accept on the DHCP-assigned guest IP; cloud-init caches its provisioning state so subsequent boots skip it.
- **`aq_live` on M3 HVF** can't be measured today because of an upstream QEMU 11.0.0 regression in ARM-target migration. See the surrounding text.
- Cells marked "varies" or italicised depend on user choices outside the comparison's scope.
