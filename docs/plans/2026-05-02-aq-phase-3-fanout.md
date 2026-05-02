# Phase 3 — Fan-out: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run N parallel VMs derived from one snapshot — disk overlays sharing the snapshot's `disk.qcow2` as backing, memory restores from the same `memory.bin` per VM. Two CLI affordances: `aq new --from-snapshot=<tag> --count=N [prefix]` to create the fleet, and `aq fanout <tag> <N> -- <command>` as a one-shot CI-style helper that creates the fleet, runs a command in each shard, aggregates exit codes, and tears down.

**Architecture:** Phase 2A's `aq new --from-snapshot` already creates one VM correctly (thin overlay over the snapshot disk; memory file staged for `-incoming`). Phase 3 wraps that in a counted loop with per-shard naming (`<prefix>-0`, `<prefix>-1`, …) and parallel start. `aq fanout` is a higher-level helper: builds the fleet, then runs the user command on each shard via SSH with `AQ_SHARD_INDEX` and `AQ_SHARD_TOTAL` injected. Output multiplexed with `[shard-N]` prefix per line. Exit code = max of children's. Default cleanup is on; `--keep` opts out.

**Tech Stack:** bash (background jobs + `wait`), SSH (for command execution in shards), `awk` for line-prefixed output multiplexing, no new external deps.

**Reference:** `docs/specs/2026-04-30-aq-ci-snapshots-design.md` (Layer 3 — Fan-out / parallelism).

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `aq` | Modify | Add `--count=N` arg parsing in `aq_new`, looping over N VM creations. Add `aq_fanout` and wire it into the dispatcher. |
| `tests/fanout.sh` | Create | E2E: snapshot a VM, fanout 4 shards running a command that emits `$AQ_SHARD_INDEX` to stdout, verify all 4 lines arrived with correct prefixes and that exit aggregation works. |
| `tests/run.sh` | Modify | Add `bash tests/fanout.sh` after live snapshots. |
| `README.md` | Modify | Add Fan-out section. |
| `CHANGELOG.md` | Modify | 2.3.0 entry. |
| `aq` (VERSION) | Modify | `VERSION=2.3.0`. |

The `aq` script stays one file. Phases 1-2B code paths preserved.

---

## CLI Surface

```
aq new --from-snapshot=<tag> --count=N [prefix]
    Create N VMs named <prefix>-0, <prefix>-1, ..., <prefix>-{N-1}.
    Without --count, behaves as today: one VM with the optional name argument.
    --count requires --from-snapshot (creating N fresh-bootstrap VMs is
    pointless — they'd all need first_boot_setup separately).

aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>
    1. aq new --from-snapshot=<tag> --count=N <prefix>  (default prefix: "shard-$$")
    2. aq start each shard in parallel, wait for all SSH to be ready.
    3. aq exec <command...> on each shard, with AQ_SHARD_INDEX (0..N-1)
       and AQ_SHARD_TOTAL (=N) in the environment.
    4. Multiplex stdout/stderr lines with "[shard-N] " prefix.
    5. Wait for all to finish; record per-shard exit codes.
    6. Unless --keep: aq stop + aq rm each shard.
    7. Exit with max of per-shard exit codes (0 if all succeeded).
```

---

## Task 0: Branch + baseline

**Files:** none changed.

- [ ] **Step 1: Branch from main**

```bash
git checkout main
git pull --ff-only
git checkout -b phase-3-fanout
```

- [ ] **Step 2: Baseline tests**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`, `[snap] PASSED`, `[live] PASSED`.

---

## Task 1: `--count=N` in `aq_new`

Loop the existing single-VM creation N times. Constraint: `--count` requires `--from-snapshot`.

**Files:**
- Modify: `aq` (`aq_new` argument parsing + body)

- [ ] **Step 1: Replace `aq_new`**

Find `aq_new` in `aq`. Replace its body with:

```bash
aq_new() {
  forwards=()
  local from_snapshot=""
  local count=1
  local prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -p)
        forwards+=("$2"); shift; shift
        ;;
      --from-snapshot=*)
        from_snapshot="${1#--from-snapshot=}"; shift
        ;;
      --from-snapshot)
        from_snapshot="$2"; shift; shift
        ;;
      --count=*)
        count="${1#--count=}"; shift
        ;;
      --count)
        count="$2"; shift; shift
        ;;
      *)
        break
        ;;
    esac
  done

  if [ "$count" -lt 1 ] 2>/dev/null; then
    stderr 'Error: --count must be a positive integer.'; exit 1
  fi

  if [ "$count" -gt 1 ] && [ -z "$from_snapshot" ]; then
    stderr 'Error: --count requires --from-snapshot=<tag>.'
    stderr 'Creating N VMs from a fresh base would still need first_boot_setup on each — use a snapshot.'
    exit 1
  fi

  # Single-VM path (same as Phase 2A/2B).
  if [ "$count" -eq 1 ]; then
    if [ $# -gt 0 ]; then
      VM_NAME=$1
    else
      VM_NAME=$(random_vm_name)
    fi
    _aq_new_one "$from_snapshot" "$VM_NAME"
    stderr Created:
    echo $VM_NAME
    return 0
  fi

  # Counted path: <prefix>-0 .. <prefix>-(N-1).
  if [ $# -gt 0 ]; then
    prefix=$1
  else
    prefix="shard-$$"
  fi

  local i=0
  while [ $i -lt $count ]; do
    _aq_new_one "$from_snapshot" "$prefix-$i"
    echo "$prefix-$i"
    i=$((i + 1))
  done
}

# Inner: create exactly one VM. Args: <from_snapshot-or-empty> <vm-name>.
# Encapsulates the disk-creation, uefi-vars-copy, and snapshot-marker steps
# so the counted loop can call it cleanly.
_aq_new_one() {
  local from_snapshot=$1
  local vm_name=$2

  local backing_file backing_fmt
  if [ -n "$from_snapshot" ]; then
    local resolved
    resolved=$(resolve_tag "$from_snapshot") || {
      stderr "Error: snapshot or alias '$from_snapshot' does not exist."
      exit 1
    }
    backing_file="$(snapshot_path "$resolved")/disk.qcow2"
    backing_fmt=qcow2
    [ -f "$backing_file" ] || { stderr "Error: snapshot disk not found: $backing_file"; exit 1; }
  else
    ensure_base_image
    backing_file="$BASE_DIR/$ARCH/$LATEST_ALPINE_BASE"
    backing_fmt=raw
  fi

  if [ -d "$BASE_DIR/$vm_name" ]; then
    stderr "Error: VM '$vm_name' already exists."
    exit 1
  fi

  (
    cd $BASE_DIR
    mkdir $vm_name
    cd $vm_name
    touch hostfwd.conf
    if [ ${#forwards[@]} -gt 0 ]; then
      for forward in "${forwards[@]}"; do
        echo $forward >> hostfwd.conf
      done
    fi
    qemu-img create -b "$backing_file" -F "$backing_fmt" -f qcow2 storage.qcow2 2G 1>/dev/null

    case "$UEFI_VARS_FLAVOR" in
      sysbus_json)
        cp $BASE_DIR/$ARCH/uefi-vars.json .
        chmod +w uefi-vars.json
        ;;
      pflash_fd)
        cp $BASE_DIR/$ARCH/uefi-vars.fd .
        chmod +w uefi-vars.fd
        ;;
    esac

    if [ -z "$from_snapshot" ]; then
      touch .needs_first_boot_setup
    fi
  )

  if [ -n "$from_snapshot" ]; then
    local resolved
    resolved=$(resolve_tag "$from_snapshot")
    echo "$resolved" > "$BASE_DIR/$vm_name/.from_snapshot"

    local has_memory
    has_memory=$(read_meta "$resolved" has_memory 2>/dev/null || echo false)
    if [ "$has_memory" = "true" ]; then
      local src="$(snapshot_path "$resolved")/memory.bin"
      local dst="$BASE_DIR/$vm_name/incoming-memory.bin"
      ln "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
    fi
  fi
}
```

- [ ] **Step 2: Smoke + snapshot tests**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`, `[snap] PASSED`, `[live] PASSED`. The single-VM path is now routed through `_aq_new_one`; existing behaviour preserved.

- [ ] **Step 3: Manual --count probe**

```bash
VM=src-$$
./aq new "$VM"
./aq start "$VM"
./aq exec "$VM" 'echo M > /dev/shm/m'
./aq snapshot create "$VM" fan-test-tag
./aq stop "$VM"
./aq rm "$VM"

./aq new --from-snapshot=fan-test-tag --count=3 myshard
./aq ls | grep myshard
./aq rm myshard-0; ./aq rm myshard-1; ./aq rm myshard-2
./aq snapshot rm --force fan-test-tag
```

Expected: `aq new --count=3 myshard` outputs three lines (`myshard-0`, `myshard-1`, `myshard-2`). `aq ls` shows all three. Each VM's storage.qcow2 backs onto the snapshot's disk.qcow2.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Add --count=N to aq new --from-snapshot for fan-out fleet creation"
```

---

## Task 2: `aq fanout`

The high-level helper. Creates the fleet, starts in parallel, runs the command per shard with env, multiplexes output, aggregates exits, cleans up.

**Files:**
- Modify: `aq` (add `aq_fanout`, wire dispatcher)

- [ ] **Step 1: Add `aq_fanout`**

Insert into `aq` after `aq_snapshot`:

```bash
aq_fanout() {
  local tag=""
  local n=""
  local keep=0
  local prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep) keep=1; shift ;;
      --prefix=*) prefix="${1#--prefix=}"; shift ;;
      --prefix) prefix="$2"; shift; shift ;;
      --) shift; break ;;
      *)
        if [ -z "$tag" ]; then
          tag="$1"; shift
        elif [ -z "$n" ]; then
          n="$1"; shift
        else
          break
        fi
        ;;
    esac
  done

  [ -z "$tag" ] && { stderr 'Usage: aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>'; exit 1; }
  [ -z "$n" ]   && { stderr 'Usage: aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>'; exit 1; }
  [ $# -eq 0 ]  && { stderr 'Usage: aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>'; exit 1; }

  if ! [ "$n" -gt 0 ] 2>/dev/null; then
    stderr "Error: N must be a positive integer (got '$n')."; exit 1
  fi

  if ! resolve_tag "$tag" >/dev/null; then
    stderr "Error: snapshot or alias '$tag' does not exist."; exit 1
  fi

  [ -z "$prefix" ] && prefix="shard-$$"

  # Build the fleet (Task 1).
  stderr "[fanout] creating $n VM(s) from snapshot '$tag' as '$prefix-0'..'$prefix-$((n-1))'"
  aq_new --from-snapshot="$tag" --count="$n" "$prefix" >/dev/null

  # Capture cleanup so a Ctrl-C / failure still removes the fleet
  # (unless --keep). Note: this trap fires on any function-scope return path.
  local cleanup_cmd=""
  if [ "$keep" -eq 0 ]; then
    cleanup_cmd="_aq_fanout_cleanup '$prefix' '$n'"
  fi
  trap "$cleanup_cmd" EXIT

  # Start all N in parallel.
  stderr "[fanout] starting all $n shards in parallel"
  local i=0
  while [ $i -lt $n ]; do
    "$0" start "$prefix-$i" >/dev/null 2>&1 &
    i=$((i + 1))
  done
  wait

  # Run command in each shard, multiplex output, collect exit codes.
  local cmd=("$@")
  stderr "[fanout] dispatching command to $n shards"
  local pids=()
  local exit_files=()
  i=0
  while [ $i -lt $n ]; do
    local exit_file
    exit_file=$(mktemp)
    exit_files+=("$exit_file")
    (
      _aq_fanout_run_shard "$prefix" "$i" "$n" "${cmd[@]}"
      echo $? > "$exit_file"
    ) &
    pids+=($!)
    i=$((i + 1))
  done
  wait "${pids[@]}" 2>/dev/null || true

  # Aggregate exit codes.
  local max_exit=0
  i=0
  while [ $i -lt $n ]; do
    local code
    code=$(cat "${exit_files[$i]}" 2>/dev/null || echo 1)
    rm -f "${exit_files[$i]}"
    [ "$code" -gt "$max_exit" ] && max_exit=$code
    i=$((i + 1))
  done

  stderr "[fanout] all shards finished (max exit $max_exit)"
  exit "$max_exit"
}

# Run user command in one shard via SSH with AQ_SHARD_INDEX/AQ_SHARD_TOTAL,
# prefixing every output line with [shard-<i>].
# Args: <prefix> <i> <total> <cmd...>
_aq_fanout_run_shard() {
  local prefix=$1 i=$2 total=$3
  shift 3
  local vm="$prefix-$i"
  vm_ssh "$vm" "AQ_SHARD_INDEX=$i AQ_SHARD_TOTAL=$total $*" 2>&1 \
    | awk -v tag="$vm" '{ print "[" tag "] " $0 }'
  return ${PIPESTATUS[0]}
}

# Stop and remove every shard in the fleet. Args: <prefix> <count>.
_aq_fanout_cleanup() {
  local prefix=$1 n=$2
  local i=0
  while [ $i -lt $n ]; do
    "$0" rm "$prefix-$i" >/dev/null 2>&1 &
    i=$((i + 1))
  done
  wait
}
```

- [ ] **Step 2: Wire `fanout` into the dispatcher**

Find the dispatcher near the bottom of `aq`:

Old:
```bash
case $COMMAND in
  new) aq_new "$@" ;;
  start) aq_start "$@" ;;
  ...
  snapshot) aq_snapshot "$@" ;;
  "--version") aq_version ;;
```

New:
```bash
case $COMMAND in
  new) aq_new "$@" ;;
  start) aq_start "$@" ;;
  ...
  snapshot) aq_snapshot "$@" ;;
  fanout) aq_fanout "$@" ;;
  "--version") aq_version ;;
```

- [ ] **Step 3: Manual `aq fanout` probe**

```bash
# Re-create fan-test-tag if needed
VM=src-$$
./aq new "$VM"
./aq start "$VM"
./aq exec "$VM" 'echo M > /dev/shm/m'
./aq snapshot create "$VM" fan-test-tag
./aq stop "$VM"
./aq rm "$VM"

./aq fanout fan-test-tag 4 -- 'echo "shard $AQ_SHARD_INDEX of $AQ_SHARD_TOTAL"'
echo "exit was: $?"

./aq snapshot rm --force fan-test-tag
```

Expected: 4 lines, one per shard, each prefixed `[shard-PID-N]`, with body `shard 0 of 4`, `shard 1 of 4`, etc. Exit code 0. Order may vary (parallel). After fanout returns, `aq ls` shows no leftover shards.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Implement aq fanout for parallel command execution across N shards"
```

---

## Task 3: e2e fanout test

**Files:**
- Create: `tests/fanout.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Create `tests/fanout.sh`**

```bash
#!/usr/bin/env bash
# E2E test for aq fanout:
# - snapshot a provisioned VM
# - fanout N=4 shards running a command that emits a unique line per shard
# - verify all 4 prefixed lines are in the output
# - verify aggregated exit code matches max child exit
# - verify cleanup removed all shards

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
SRC_VM="aq-fan-src-$$"
TAG="aq-fan-test-$$"
PREFIX="aq-fan-shard-$$"
N=4

cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" 2>/dev/null
  "$AQ" rm   "$SRC_VM" 2>/dev/null
  local i=0
  while [ $i -lt $N ]; do
    "$AQ" stop "$PREFIX-$i" 2>/dev/null
    "$AQ" rm   "$PREFIX-$i" 2>/dev/null
    i=$((i + 1))
  done
  "$AQ" snapshot rm --force "$TAG" 2>/dev/null
}
trap cleanup EXIT

echo "[fan] aq new + provision $SRC_VM"
"$AQ" new "$SRC_VM"
"$AQ" start "$SRC_VM"
"$AQ" exec "$SRC_VM" 'echo provisioned > /root/state'

echo "[fan] aq snapshot create (live, so shards inherit running state)"
"$AQ" snapshot create "$SRC_VM" "$TAG"

echo "[fan] aq stop + rm $SRC_VM"
"$AQ" stop "$SRC_VM"
"$AQ" rm "$SRC_VM"

echo "[fan] aq fanout $TAG $N (success path)"
out=$("$AQ" fanout "$TAG" "$N" --prefix="$PREFIX" -- 'echo "I am $AQ_SHARD_INDEX of $AQ_SHARD_TOTAL"; cat /root/state' 2>&1)
echo "$out"

# All N shards should have emitted "I am <i> of N"
i=0
while [ $i -lt $N ]; do
  if ! echo "$out" | grep -q "\[$PREFIX-$i\] I am $i of $N"; then
    echo "[fan] FAIL: missing line for shard $i"
    exit 1
  fi
  i=$((i + 1))
done

# All N should have echoed the inherited /root/state
if [ "$(echo "$out" | grep -c 'provisioned')" != "$N" ]; then
  echo "[fan] FAIL: expected $N occurrences of 'provisioned', got $(echo "$out" | grep -c 'provisioned')"
  exit 1
fi

# Cleanup happened
if "$AQ" ls | grep -q "^$PREFIX-"; then
  echo "[fan] FAIL: shards not cleaned up after fanout"
  "$AQ" ls
  exit 1
fi

echo "[fan] aq fanout exit-code aggregation"
set +e
"$AQ" fanout "$TAG" "$N" --prefix="$PREFIX-fail" -- 'exit $AQ_SHARD_INDEX' >/dev/null 2>&1
fanout_exit=$?
set -e
# Per-shard exit codes are 0,1,2,3 — max is 3
if [ "$fanout_exit" != "3" ]; then
  echo "[fan] FAIL: expected fanout exit 3 (max of 0..3), got $fanout_exit"
  exit 1
fi

echo "[fan] PASSED"
```

- [ ] **Step 2: Make executable + add to runner**

```bash
chmod +x tests/fanout.sh
```

Edit `tests/run.sh`:

Old:
```bash
bash tests/smoke.sh
bash tests/snapshots.sh
bash tests/live-snapshots.sh
```

New:
```bash
bash tests/smoke.sh
bash tests/snapshots.sh
bash tests/live-snapshots.sh
bash tests/fanout.sh
```

- [ ] **Step 3: Full suite**

Run: `bash tests/run.sh`
Expected: all four `[smoke|snap|live|fan] PASSED` lines.

- [ ] **Step 4: Commit**

```bash
git add tests/fanout.sh tests/run.sh
git commit -m "Add e2e test for aq fanout"
```

---

## Task 4: README + CHANGELOG + version bump

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `aq` (VERSION)

- [ ] **Step 1: Add a "Fan-out" section to `README.md`**

Find the "Snapshots" section (Phase 2A/2B). Insert a new section right after it:

```markdown
### Fan-out

Run N parallel VMs derived from one snapshot, executing a command per shard:

    aq fanout rails-deps 8 -- /root/repo/bin/test-shard

Each shard receives `AQ_SHARD_INDEX` (0..N-1) and `AQ_SHARD_TOTAL` (=N) in its
environment, so a test runner can pick its slice. All shards back onto the same
`disk.qcow2` (delta-only writes per shard); if the snapshot has memory state,
each shard restores from the same `memory.bin`. Output is multiplexed with a
`[shard-<name>]` line prefix, exit code is the max of children's, and shards
are torn down after the command finishes (use `--keep` to opt out).

For a finer-grained pipeline you can also use `aq new --from-snapshot=<tag>
--count=N <prefix>` to create the fleet and drive it yourself with `aq start`,
`aq exec`, `aq stop`, `aq rm`.
```

- [ ] **Step 2: Add a `2.3.0` entry to `CHANGELOG.md`**

Replace the `## Unreleased` line:

```markdown
## Unreleased

## 2.3.0 "Swarm" 2026-05-XX

### New Features

- `aq new --from-snapshot=<tag> --count=N [prefix]` creates N VMs named
  `<prefix>-0` ... `<prefix>-(N-1)`, each backing onto the snapshot's
  `disk.qcow2`. Default prefix is `shard-$$` if omitted.
- `aq fanout <tag> <N> [--keep] [--prefix=<name>] -- <command...>` is the
  CI-style helper: builds the fleet, starts all shards in parallel, runs the
  user command in each shard with `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` set,
  multiplexes per-shard output with a `[shard-<name>]` prefix, waits for all
  to finish, aggregates exit codes (max), and tears the fleet down (unless
  `--keep`).

### Internal

- `aq_new` body refactored into a `_aq_new_one` inner function so the counted
  loop can call it without duplication.
- `aq_fanout` uses `awk` for line-prefixed output multiplexing (no per-line
  fork overhead); per-shard exit codes are written to mktemp files and read
  back after `wait`.

### Limitations

- All shards share the same host directory (no inter-shard FS isolation
  beyond the qcow2 overlay). Anything written to the shared backing snapshot
  disk is by-design only-readable for shards (qcow2 backing is read-only);
  delta writes go to each shard's overlay.
- No CPU / memory caps per shard yet — relies on Linux KSM / macOS page
  cache to dedup the read-only snapshot pages across shards.
```

- [ ] **Step 3: Bump VERSION**

```bash
sed -i.bak 's/^VERSION=2\.2\.0/VERSION=2.3.0/' aq && rm aq.bak
grep '^VERSION=' aq
```

Expected: `VERSION=2.3.0`.

- [ ] **Step 4: Final test pass**

Run: `bash tests/run.sh`
Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add aq README.md CHANGELOG.md
git commit -m "Release 2.3.0 \"Swarm\" — fan-out"
```

---

## Task 5: Push, CI, merge, tag, release

**Files:** none (operational).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin phase-3-fanout
```

- [ ] **Step 2: Wait for CI**

Run: `gh run list --branch phase-3-fanout --limit 1`
Wait until success. The fanout test exercises 4 parallel x86_64 VMs on the CI runner — memory will be tight, expect ~1-2 GB used by qemus combined.

If CI fails, expected categories:
- **CI runner OOM**: 4 × 1 GB VM = 4 GB. Ubuntu-latest runners have 7 GB RAM, should fit. If it doesn't, drop the test to N=3.
- **`vm_ssh` shell quoting**: the user command goes through `vm_ssh "$vm" "AQ_SHARD_INDEX=… $*"` which assembles a shell command line. If the user command contains awkward quoting it may need escaping; for the test command (`echo "I am $AQ_SHARD_INDEX of $AQ_SHARD_TOTAL"; cat /root/state`) this should work because the `$AQ_SHARD_INDEX` evaluates inside the shell on the guest, not the host.
- **awk line buffering**: macOS awk and gawk both line-buffer by default; should be fine.

Iterate by editing, committing, pushing.

- [ ] **Step 3: Merge to main**

After CI is green:

```bash
git checkout main
git pull --ff-only
git merge --ff-only phase-3-fanout
git push origin main
git branch -d phase-3-fanout
git push origin --delete phase-3-fanout
```

- [ ] **Step 4: Tag and release**

```bash
git tag -a v2.3.0 -m 'aq 2.3.0 "Swarm" — fan-out'
git push origin v2.3.0
gh release create v2.3.0 --title 'aq 2.3.0 "Swarm"' \
  --notes "Fan-out: aq new --from-snapshot --count=N for fleet creation, aq fanout for the CI-style helper that runs a command across N parallel shards. See CHANGELOG.md."
```

---

## Self-Review Checklist

- **Spec coverage:**
  - `aq new --from-snapshot=<tag> --count=N` → Task 1 ✓
  - `aq fanout <tag> <N> -- <cmd>` → Task 2 ✓
  - `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` env injection → Task 2 ✓
  - Output multiplexing with `[shard-N]` prefix → Task 2 ✓
  - Aggregate exit codes (max) → Task 2, verified in Task 3 ✓
  - Auto-cleanup with `--keep` opt-out → Task 2 ✓
  - Disk backing chain (`O(N × delta)`) → falls out of Task 1 (each VM's `qemu-img create -b` reuses snapshot's disk.qcow2) ✓
  - **Memory mmap / KSM dedup** (Phase 3 spec mentioned) — left to the OS by design; documented as such in CHANGELOG. v1 acceptable, real measurement deferred to Phase 5 if it bites.
- **Placeholder scan:** no "TBD"/"TODO"/"add validation" — every step has actual code or commands.
- **Type / name consistency:**
  - `_aq_new_one` (Task 1), `_aq_fanout_run_shard` and `_aq_fanout_cleanup` (Task 2) all use the same `<prefix>-<i>` naming.
  - `--from-snapshot`, `--count`, `--prefix`, `--keep` flag spellings consistent across Task 1, Task 2, README (Task 4), CHANGELOG (Task 4).
  - `AQ_SHARD_INDEX` / `AQ_SHARD_TOTAL` env names consistent in Task 2 (impl), Task 3 (test), Task 4 (docs).

## Out of Scope (Phase 4 and beyond)

- **Demo blogpost on a real OSS project** (Rails monorepo CI replacement). Phase 4.
- **OCI artifact push/pull** for snapshots and snapshot-image distribution. Phase 5.
- **`AQ_FACTORS` declarative cache invalidation**. Phase 5.
- **Bootstrapped base image cache in CI** (separate from snapshot fleet). Phase 5 mini.
