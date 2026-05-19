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
| Warm subsequent start | **~4 s (M3) / ~5.4 s (GH KVM)** measured | **113 ms (GH KVM)** measured | ~1–2 s | ~1–2 s | ~5–10 s | sub-second | ~5–10 s |
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

### Cold/warm start time — measured on the same runner

All four numbers below come from the same GitHub `ubuntu-latest` runner with KVM enabled. Both image pulls and the size-2G aq base are pre-warmed. Each side ran n=10 with the same 100 ms TCP-accept probe cadence. Source: `.github/workflows/bench-vs-docker-sshd.yml` + the four `tests/bench-*.sh` scripts.

| target | min | **median** | max | vs `aq_cold` |
|---|---|---|---|---|
| `aq_cold` — `aq new --size=2G` + `aq start` | 6363 ms | **6695 ms** | 7127 ms | 1× (baseline) |
| `aq_live` — `aq new --from-snapshot=<live-tag>` + `aq start` | 678 ms | **680 ms** | 687 ms | **~10× faster** |
| `docker_sshd` — `docker run -d -p :22 panubo/sshd` → TCP-accept | 137 ms | **142 ms** | 353 ms | ~47× faster |
| `podman_sshd` — `podman run -d -p :22 docker.io/panubo/sshd` → TCP-accept | 92 ms | **96 ms** | 815 ms | ~70× faster |

Three things worth pointing out:

1. **aq live-snapshot restore is genuinely sub-second.** 680 ms median, *9 ms spread* across 10 runs — the most stable bench in the table. QEMU's `-incoming` reads the captured memory image straight back into RAM, skipping the whole kernel-boot + OpenRC + sshd-start path. The remaining 680 ms is QEMU init + memory replay + `cont` + the SSH probe round.
2. **Live snapshots close the cost-of-VM gap from ~47× to ~5×.** Once you've provisioned a VM and snapshotted it running, every subsequent fan-out lands in ~0.7 s — competitive with containers for workflows where you can amortise the provision-once cost. The aq fanout primitive (v2.3.0) does exactly this, spawning N parallel VMs from one live snapshot.
3. **Podman is a touch faster than Docker** here (96 vs 142 ms median), with one outlier run (815 ms — likely first-run storage initialization). Both run-to-TCP-accept times are dominated by sshd binding to port 22 inside the container, not by the container runtime itself.

Cold-cold (image pull / base build) is excluded from the loop because both sides amortise it indefinitely:

- **aq cold first build per size**: ~30 s. Caches per `(alpine-version, arch, size)`; subsequent same-size `aq new` skips it.
- **`panubo/sshd` first pull**: ~3–5 s on a fast connection. Cached by the container runtime; subsequent runs skip it.
- **virsh / libvirt**: not benched here yet; see `.github/workflows/bench-vs-virsh.yml` (TODO).

The takeaway:

- "Fastest from zero to interactive shell": containers (~100 ms).
- "Fastest once you've provisioned": still containers, but aq's gap collapses to ~5× via live snapshots.
- "Fastest *and* I want a full kernel + the host kernel not to be exposed to whatever runs inside": aq live restore, no contender in the table.

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

- aq numbers come from `tests/bench-aq-start.sh` on real hardware: M3 / Apple HVF for the "macOS" column and GH-hosted ubuntu-latest KVM for the "GH KVM" column. n=10, 100 ms TCP-accept probe granularity, size-2G base pre-built.
- The `panubo/sshd` row comes from `.github/workflows/bench-vs-docker-sshd.yml` running `tests/bench-docker-sshd.sh` on the *same* GH runner as the aq column, with the image pre-pulled and the same 100 ms probe cadence — apples-to-apples on the same hardware so the 47× gap reflects boot architecture, not measurement noise.
- Numbers for plain Docker, Podman, macpine, OrbStack, and virsh are conservative estimates from upstream docs and common configurations — not benched here. PRs welcome if you want to wire one of those up the same way docker-sshd is.
- Cells marked "varies" depend on user choices that fall outside the comparison's scope (e.g. base image choice for virsh).
