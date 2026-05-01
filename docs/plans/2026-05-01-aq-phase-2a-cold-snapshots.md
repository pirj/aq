# Phase 2A — Cold Snapshots: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `aq snapshot create/ls/rm/tag/tree` and `aq new --from-snapshot=<tag>` so a provisioned VM's disk state can be saved and used as the starting point for new VMs, skipping re-provisioning.

**Architecture:** Snapshots are stored under `~/.local/share/aq/snapshots/<arch>/<tag>/`. Each contains a `disk.qcow2` (full copy of the source VM's storage), a `meta.json` (parent, base, vm config), and a `refcount` (small int file). A `tags/<arch>/<name>` directory holds symlinks for human-readable aliases. A new VM created from a snapshot uses `qemu-img create -b <snapshot-disk>` to layer a thin overlay on top, so disk usage stays `O(N × delta)`. The source VM must be **stopped** when snapshotting in 2A — capturing memory state of a running VM is Phase 2B.

**Tech Stack:** bash, qemu-img (for qcow2 backing chains and copies), POSIX flock/atomic file ops for refcount safety, Alpine guest (unchanged), JSON via `printf` (no jq dependency).

**Reference:** `docs/specs/2026-04-30-aq-ci-snapshots-design.md` (Layer 2 — Snapshot subsystem). This plan covers the parts of Layer 2 that don't require live memory state.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `aq` | Modify | Add `aq_snapshot` dispatcher, `aq_snapshot_create/ls/rm/tag/tree` functions, and `--from-snapshot` handling in `aq_new`. Add helpers: `snapshots_dir`, `tags_dir`, `snapshot_path`, `tag_path`, `read_meta`, `write_meta`, `bump_refcount`, `snapshot_exists`, `resolve_tag`. Wire `snapshot` into the command dispatcher (around line 670). |
| `tests/smoke.sh` | Modify | (No change in this plan — kept stable for Phase 1 regression.) |
| `tests/snapshots.sh` | Create | New e2e test: provision → stop → snapshot create → verify ls/tree/meta → new --from-snapshot → exec → verify state. |
| `tests/run.sh` | Modify | Add `bash tests/snapshots.sh` after the smoke test. |
| `.github/workflows/ci-linux.yml` | (No change) | Picks up new test via `tests/run.sh`. |
| `CHANGELOG.md` | Modify | 2.1.0 entry. |
| `aq` (VERSION) | Modify | `VERSION=2.1.0`. |

The `aq` script stays one file. Splitting into modules is still out of scope. The snapshot helpers go in their own clearly-marked section near the top, after `migrate_base_dir_to_arch`.

---

## CLI Surface (what the engineer is implementing)

```
aq snapshot create <vm-name> <tag>
    Snapshot a STOPPED VM. Stores disk state in
    ~/.local/share/aq/snapshots/<arch>/<tag>/.
    Refuses if VM is running (use `aq stop` first).
    Refuses if <tag> already exists (use a different tag, or `aq snapshot rm` first).

aq snapshot ls
    Table: tag, parent, arch, size, created, last-used.

aq snapshot rm <tag> [--force]
    Refuses if refcount > 0 unless --force.

aq snapshot tag <existing-tag> <new-tag>
    Creates an alias for an existing snapshot.

aq snapshot tree [<tag>]
    Visualise the backing chain (forest by default; subtree if <tag> given).

aq new --from-snapshot=<tag> [vm-name]
    Create a new VM whose disk overlays the given snapshot.
    The new VM cold-boots; `first_boot_setup` is skipped because the
    snapshot already contains a provisioned rootfs.
```

---

## Cache Layout

```
~/.local/share/aq/
├── snapshots/
│   ├── aarch64/
│   │   └── <tag>/
│   │       ├── disk.qcow2
│   │       ├── meta.json
│   │       └── refcount
│   └── x86_64/
│       └── ...
└── tags/
    ├── aarch64/
    │   └── <name> -> ../../snapshots/aarch64/<tag>/
    └── x86_64/
        └── ...
```

---

## meta.json Schema (Phase 2A subset)

```json
{
  "tag": "deps-abc123",
  "parent": "base",
  "arch": "x86_64",
  "base_image": "alpine-base-3.22.2-x86_64.raw",
  "created": "2026-05-01T13:23:11Z",
  "last_used": "2026-05-01T13:23:11Z",
  "source_vm": "myrails",
  "has_memory": false
}
```

Fields:
- `parent` — `"base"` if the snapshot's disk has the alpine base image as backing; otherwise the parent snapshot's tag.
- `has_memory` — always `false` in Phase 2A. Phase 2B adds memory.bin alongside.

---

## Task 0: Bootstrap branch and verify baseline

Set up an isolated branch and confirm Phase 1 still passes locally before adding any new code.

**Files:** none changed in this task.

- [ ] **Step 1: Create the feature branch from main**

```bash
git checkout main
git pull --ff-only
git checkout -b phase-2a-cold-snapshots
```

- [ ] **Step 2: Run baseline smoke test on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. Confirms we start from a clean slate.

- [ ] **Step 3: Sanity check helpers needed later are present**

Run: `grep -nE 'detect_host|migrate_base_dir|BASE_DIR=|ensure_base_image' aq | head -10`
Expected: lines for `detect_host()`, `migrate_base_dir_to_arch()`, `BASE_DIR=~/.local/share/aq`, `ensure_base_image()`. These are the integration points later tasks build on.

---

## Task 1: Snapshot helper functions

Pure-helpers section. No CLI yet. Each function does one thing.

**Files:**
- Modify: `aq` (insert new helpers after `migrate_base_dir_to_arch` and before `download_alpine_iso`, around line 140)

- [ ] **Step 1: Add directory and path helpers**

Insert into `aq` immediately after the `migrate_base_dir_to_arch` function (and its closing `}`):

```bash
# --- Snapshot helpers ---------------------------------------------------------

snapshots_dir() {
  echo "$BASE_DIR/snapshots/$ARCH"
}

tags_dir() {
  echo "$BASE_DIR/tags/$ARCH"
}

snapshot_path() {
  # Args: <tag>. Echoes the absolute directory of the snapshot.
  local tag=$1
  echo "$(snapshots_dir)/$tag"
}

tag_path() {
  # Args: <name>. Echoes the absolute path to the tag symlink (may not exist).
  local name=$1
  echo "$(tags_dir)/$name"
}

snapshot_exists() {
  # Args: <tag>. Returns 0 if the snapshot directory exists.
  local tag=$1
  [ -d "$(snapshot_path "$tag")" ]
}

resolve_tag() {
  # Args: <tag-or-alias>. Echoes the underlying snapshot tag.
  # If the input is itself a snapshot directory name, echoes it unchanged.
  # If it's a symlink under tags/, follows it.
  local input=$1
  if snapshot_exists "$input"; then
    echo "$input"
    return 0
  fi
  local link
  link=$(tag_path "$input")
  if [ -L "$link" ]; then
    # Symlink target is the snapshot directory; emit its basename.
    basename "$(readlink "$link")"
    return 0
  fi
  return 1
}
```

- [ ] **Step 2: Add meta.json read / write helpers**

Insert after the helpers from Step 1:

```bash
# Atomically write meta.json. Args: <tag> <parent> <source_vm>.
# Always emits has_memory=false and the current timestamp.
write_meta() {
  local tag=$1 parent=$2 source_vm=$3
  local dir
  dir=$(snapshot_path "$tag")
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Manually compose JSON. No jq dependency.
  printf '{\n' > "$dir/meta.json.tmp"
  printf '  "tag": "%s",\n'         "$tag"                   >> "$dir/meta.json.tmp"
  printf '  "parent": "%s",\n'      "$parent"                >> "$dir/meta.json.tmp"
  printf '  "arch": "%s",\n'        "$ARCH"                  >> "$dir/meta.json.tmp"
  printf '  "base_image": "%s",\n'  "$LATEST_ALPINE_BASE"    >> "$dir/meta.json.tmp"
  printf '  "created": "%s",\n'     "$now"                   >> "$dir/meta.json.tmp"
  printf '  "last_used": "%s",\n'   "$now"                   >> "$dir/meta.json.tmp"
  printf '  "source_vm": "%s",\n'   "$source_vm"             >> "$dir/meta.json.tmp"
  printf '  "has_memory": false\n'                           >> "$dir/meta.json.tmp"
  printf '}\n'                                               >> "$dir/meta.json.tmp"
  mv "$dir/meta.json.tmp" "$dir/meta.json"
}

# Read a single field from meta.json. Args: <tag> <field>.
# Field is one of: tag, parent, arch, base_image, created, last_used, source_vm, has_memory.
read_meta() {
  local tag=$1 field=$2
  local file
  file=$(snapshot_path "$tag")/meta.json
  [ -f "$file" ] || return 1
  # Match a "field": "value" line and extract the value.
  # has_memory is unquoted (true|false) so handle it separately.
  if [ "$field" = "has_memory" ]; then
    grep -E '"has_memory":' "$file" | sed -E 's/.*"has_memory": (true|false).*/\1/' | head -1
  else
    grep -E "\"$field\":" "$file" | sed -E "s/.*\"$field\": \"([^\"]*)\".*/\1/" | head -1
  fi
}
```

- [ ] **Step 3: Add refcount helpers**

Insert after the meta helpers:

```bash
# Increment refcount of <tag> by 1. Creates the file if missing.
bump_refcount() {
  local tag=$1
  local file
  file=$(snapshot_path "$tag")/refcount
  local cur=0
  [ -f "$file" ] && cur=$(cat "$file")
  printf '%d\n' "$((cur + 1))" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Decrement refcount of <tag> by 1 (clamped at 0).
drop_refcount() {
  local tag=$1
  local file
  file=$(snapshot_path "$tag")/refcount
  local cur=0
  [ -f "$file" ] && cur=$(cat "$file")
  local next=$((cur - 1))
  [ $next -lt 0 ] && next=0
  printf '%d\n' "$next" > "$file.tmp"
  mv "$file.tmp" "$file"
}

get_refcount() {
  local tag=$1
  local file
  file=$(snapshot_path "$tag")/refcount
  [ -f "$file" ] || { echo 0; return; }
  cat "$file"
}

# --- end snapshot helpers -----------------------------------------------------
```

- [ ] **Step 4: Run smoke to make sure nothing broke**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED`. Helpers are not yet called by anything; this verifies syntax.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Add snapshot directory, meta.json, and refcount helpers"
```

---

## Task 2: `aq snapshot create` (cold)

Implements the create path for a stopped VM.

**Files:**
- Modify: `aq` (add `aq_snapshot_create` near other `aq_*` functions, after `aq_rm`)

- [ ] **Step 1: Add aq_snapshot_create**

Insert into `aq`, after `aq_rm` and before `aq_ls`:

```bash
aq_snapshot_create() {
  local vm_name=${1:-}
  local tag=${2:-}
  [ -z "$vm_name" ] && stderr 'Error: VM name required: `aq snapshot create <vm-name> <tag>`.' && exit 1
  [ -z "$tag" ]     && stderr 'Error: tag required: `aq snapshot create <vm-name> <tag>`.' && exit 1
  ! vm_exists "$vm_name" && stderr "Error: VM '$vm_name' does not exist." && exit 1
  if is_vm_running "$vm_name"; then
    stderr "Error: VM '$vm_name' is running. Stop it first: aq stop $vm_name"
    exit 1
  fi
  if snapshot_exists "$tag"; then
    stderr "Error: snapshot '$tag' already exists. Pick a new tag or remove the existing one with: aq snapshot rm $tag"
    exit 1
  fi

  local source_disk="$BASE_DIR/$vm_name/storage.qcow2"
  [ -f "$source_disk" ] || { stderr "Error: source disk not found: $source_disk"; exit 1; }

  # Determine parent: read the qcow2 backing-file basename.
  # If it points to the base raw image, parent is "base".
  # Otherwise it's another snapshot's disk.qcow2; resolve to that snapshot's tag.
  local backing
  backing=$(qemu-img info --output=json "$source_disk" 2>/dev/null \
            | grep -E '"backing-filename":' \
            | sed -E 's/.*"backing-filename": "([^"]*)".*/\1/' \
            | head -1)
  local parent="base"
  if [ -n "$backing" ]; then
    case "$backing" in
      *"$LATEST_ALPINE_BASE") parent="base" ;;
      *snapshots/*/disk.qcow2)
        # Backing path of the form .../snapshots/<arch>/<tag>/disk.qcow2.
        # Extract the tag.
        parent=$(echo "$backing" | sed -E 's|.*/snapshots/[^/]+/([^/]+)/disk.qcow2|\1|')
        ;;
      *)
        parent="unknown"
        ;;
    esac
  fi

  local snap_dir
  snap_dir=$(snapshot_path "$tag")
  mkdir -p "$snap_dir"

  # Copy the qcow2. Source is not in use (we verified VM stopped).
  # Preserve the backing chain by default — qemu-img convert without -B flattens.
  cp "$source_disk" "$snap_dir/disk.qcow2"

  # Initialise refcount to 0.
  printf '0\n' > "$snap_dir/refcount"

  # Write meta.
  write_meta "$tag" "$parent" "$vm_name"

  # If parent is another snapshot, bump its refcount.
  if [ "$parent" != "base" ] && [ "$parent" != "unknown" ]; then
    bump_refcount "$parent"
  fi

  stderr "Snapshot created: $tag (parent: $parent)"
}
```

- [ ] **Step 2: Wire `snapshot` into the command dispatcher**

Find the dispatcher near the end of `aq`:

Old:
```bash
case $COMMAND in
  new) aq_new "$@" ;;
  start) aq_start "$@" ;;
  ...
  rm) aq_rm "$@" ;;
  ls) aq_ls ;;
  "--version") aq_version ;;
  "" | "help" | "-h" | "--help") aq_help ;;
  *) stderr "Error: Unknown command $COMMAND."; exit 1 ;;
esac
```

New:
```bash
case $COMMAND in
  new) aq_new "$@" ;;
  start) aq_start "$@" ;;
  ...
  rm) aq_rm "$@" ;;
  ls) aq_ls ;;
  snapshot) aq_snapshot "$@" ;;
  "--version") aq_version ;;
  "" | "help" | "-h" | "--help") aq_help ;;
  *) stderr "Error: Unknown command $COMMAND."; exit 1 ;;
esac
```

- [ ] **Step 3: Add the `aq_snapshot` subcommand dispatcher**

Insert into `aq`, near other `aq_*` functions (after `aq_ls`):

```bash
aq_snapshot() {
  local sub=${1:-}
  shift || true
  case "$sub" in
    create) aq_snapshot_create "$@" ;;
    *)
      stderr "Usage: aq snapshot create <vm-name> <tag>"
      exit 1
      ;;
  esac
}
```

(Tasks 3-6 add `ls`, `rm`, `tag`, `tree` to this case.)

- [ ] **Step 4: Smoke-check the create path manually**

```bash
# Use a small fresh VM
VM=snap-test-$$
./aq new "$VM"
./aq start "$VM"
./aq exec "$VM" 'apk add jq && touch /root/from-snapshot.marker'
./aq stop "$VM"
./aq snapshot create "$VM" snap-test-tag
ls "$BASE_DIR/snapshots/$ARCH/snap-test-tag/"
cat "$BASE_DIR/snapshots/$ARCH/snap-test-tag/meta.json"
./aq rm "$VM"
```

Expected: directory listing shows `disk.qcow2`, `meta.json`, `refcount`. `meta.json` contains the right tag, arch, parent ("base"), source_vm, has_memory: false. `disk.qcow2` is roughly the size of the original `storage.qcow2`.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Implement aq snapshot create (cold; requires VM stopped)"
```

---

## Task 3: `aq snapshot ls`

Tabular output showing all snapshots in the current arch.

**Files:**
- Modify: `aq` (add `aq_snapshot_ls`)

- [ ] **Step 1: Add aq_snapshot_ls**

Insert into `aq` after `aq_snapshot_create`:

```bash
aq_snapshot_ls() {
  local dir
  dir=$(snapshots_dir)
  [ -d "$dir" ] || return 0

  printf "%-30s %-20s %-7s %-6s %-20s %s\n" "TAG" "PARENT" "REFS" "SIZE" "CREATED" "SOURCE_VM"
  set +f
  for snap_dir in "$dir"/*/; do
    [ -d "$snap_dir" ] || continue
    local tag
    tag=$(basename "$snap_dir")
    local parent created source_vm refs size
    parent=$(read_meta "$tag" parent 2>/dev/null || echo "?")
    created=$(read_meta "$tag" created 2>/dev/null || echo "?")
    source_vm=$(read_meta "$tag" source_vm 2>/dev/null || echo "?")
    refs=$(get_refcount "$tag")
    size=$(du -h "$snap_dir/disk.qcow2" 2>/dev/null | awk '{print $1}')
    printf "%-30s %-20s %-7s %-6s %-20s %s\n" "$tag" "$parent" "$refs" "${size:-?}" "$created" "$source_vm"
  done
  set -f
}
```

- [ ] **Step 2: Wire `ls` into `aq_snapshot`**

Replace the `aq_snapshot` case statement:

Old:
```bash
case "$sub" in
  create) aq_snapshot_create "$@" ;;
  *)
    stderr "Usage: aq snapshot create <vm-name> <tag>"
    exit 1
    ;;
esac
```

New:
```bash
case "$sub" in
  create) aq_snapshot_create "$@" ;;
  ls)     aq_snapshot_ls "$@" ;;
  *)
    stderr "Usage: aq snapshot {create|ls} ..."
    exit 1
    ;;
esac
```

- [ ] **Step 3: Manual check**

```bash
./aq snapshot ls
```

Expected: header row plus one row per existing snapshot (the `snap-test-tag` from Task 2 if you didn't clean it up).

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Implement aq snapshot ls"
```

---

## Task 4: `aq snapshot rm`

**Files:**
- Modify: `aq` (add `aq_snapshot_rm`, wire into dispatcher)

- [ ] **Step 1: Add aq_snapshot_rm**

Insert into `aq` after `aq_snapshot_ls`:

```bash
aq_snapshot_rm() {
  local force=0
  if [ "${1:-}" = "--force" ]; then
    force=1
    shift
  fi
  local tag=${1:-}
  [ -z "$tag" ] && stderr 'Error: tag required: `aq snapshot rm [--force] <tag>`.' && exit 1
  if ! snapshot_exists "$tag"; then
    stderr "Error: snapshot '$tag' does not exist."
    exit 1
  fi
  local refs
  refs=$(get_refcount "$tag")
  if [ "$refs" -gt 0 ] && [ "$force" -eq 0 ]; then
    stderr "Error: snapshot '$tag' has $refs reference(s). Use --force to remove anyway, or remove dependents first."
    exit 1
  fi

  # If the snapshot's parent is another snapshot, drop its refcount.
  local parent
  parent=$(read_meta "$tag" parent 2>/dev/null || echo "")
  if [ -n "$parent" ] && [ "$parent" != "base" ] && [ "$parent" != "unknown" ]; then
    drop_refcount "$parent"
  fi

  # Remove any tag aliases pointing at this snapshot.
  set +f
  for link in "$(tags_dir)"/*; do
    [ -L "$link" ] || continue
    local target
    target=$(readlink "$link")
    if [ "$(basename "$target")" = "$tag" ]; then
      rm -f "$link"
    fi
  done
  set -f

  rm -rf "$(snapshot_path "$tag")"
  stderr "Snapshot removed: $tag"
}
```

- [ ] **Step 2: Wire `rm` into the dispatcher**

Replace the `aq_snapshot` case:

```bash
case "$sub" in
  create) aq_snapshot_create "$@" ;;
  ls)     aq_snapshot_ls "$@" ;;
  rm)     aq_snapshot_rm "$@" ;;
  *)
    stderr "Usage: aq snapshot {create|ls|rm} ..."
    exit 1
    ;;
esac
```

- [ ] **Step 3: Manual check**

```bash
./aq snapshot rm snap-test-tag
./aq snapshot ls
```

Expected: snapshot removed; `aq snapshot ls` no longer lists it.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Implement aq snapshot rm with refcount safety"
```

---

## Task 5: `aq snapshot tag`

**Files:**
- Modify: `aq` (add `aq_snapshot_tag`)

- [ ] **Step 1: Add aq_snapshot_tag**

Insert into `aq` after `aq_snapshot_rm`:

```bash
aq_snapshot_tag() {
  local existing=${1:-}
  local newname=${2:-}
  [ -z "$existing" ] && stderr 'Error: existing tag required: `aq snapshot tag <existing> <new>`.' && exit 1
  [ -z "$newname" ]  && stderr 'Error: new alias name required: `aq snapshot tag <existing> <new>`.' && exit 1

  local resolved
  resolved=$(resolve_tag "$existing") || {
    stderr "Error: snapshot or alias '$existing' does not exist."
    exit 1
  }

  if snapshot_exists "$newname"; then
    stderr "Error: '$newname' is itself a snapshot tag. Pick a different alias name."
    exit 1
  fi

  mkdir -p "$(tags_dir)"
  local link
  link=$(tag_path "$newname")
  ln -sfn "../../snapshots/$ARCH/$resolved" "$link"
  stderr "Tag '$newname' -> snapshot '$resolved'"
}
```

- [ ] **Step 2: Wire `tag` into the dispatcher**

```bash
case "$sub" in
  create) aq_snapshot_create "$@" ;;
  ls)     aq_snapshot_ls "$@" ;;
  rm)     aq_snapshot_rm "$@" ;;
  tag)    aq_snapshot_tag "$@" ;;
  *)
    stderr "Usage: aq snapshot {create|ls|rm|tag} ..."
    exit 1
    ;;
esac
```

- [ ] **Step 3: Manual check**

```bash
# Re-create snap-test-tag if you removed it
VM=snap-test-$$ && ./aq new "$VM" && ./aq start "$VM" && ./aq exec "$VM" "touch /root/x" && ./aq stop "$VM" && ./aq snapshot create "$VM" snap-test-tag && ./aq rm "$VM"

./aq snapshot tag snap-test-tag latest-deps
ls -l "$BASE_DIR/tags/$ARCH/"
```

Expected: `latest-deps -> ../../snapshots/<arch>/snap-test-tag` symlink. `aq snapshot ls` still shows the underlying tag.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Implement aq snapshot tag (alias creation)"
```

---

## Task 6: `aq snapshot tree`

**Files:**
- Modify: `aq` (add `aq_snapshot_tree`, wire into dispatcher)

- [ ] **Step 1: Add aq_snapshot_tree**

Insert into `aq` after `aq_snapshot_tag`:

```bash
aq_snapshot_tree() {
  local root=${1:-}
  local dir
  dir=$(snapshots_dir)
  [ -d "$dir" ] || { stderr "No snapshots."; return 0; }

  # Build (parent, child) edges by reading every meta.json.
  # Use a temp file as a small "table".
  local edges
  edges=$(mktemp)
  trap 'rm -f "$edges"' RETURN

  set +f
  for snap_dir in "$dir"/*/; do
    [ -d "$snap_dir" ] || continue
    local tag parent
    tag=$(basename "$snap_dir")
    parent=$(read_meta "$tag" parent 2>/dev/null || echo "?")
    printf '%s\t%s\n' "$parent" "$tag" >> "$edges"
  done
  set -f

  # If root is given, render only its subtree; otherwise render every tree
  # whose root parent is "base".
  if [ -n "$root" ]; then
    if ! snapshot_exists "$root"; then
      stderr "Error: snapshot '$root' does not exist."
      exit 1
    fi
    _render_subtree "$edges" "$root" 0
  else
    echo "base (alpine-$LATEST_ALPINE_VERSION-$ARCH)"
    # Find direct children of "base"
    local child
    awk -F'\t' '$1 == "base" { print $2 }' "$edges" | while read -r child; do
      _render_subtree "$edges" "$child" 1
    done
  fi
}

# Internal: indented one-line rendering. Args: <edges-file> <tag> <depth>.
_render_subtree() {
  local edges=$1 tag=$2 depth=$3
  local indent=""
  local i=0
  while [ $i -lt $depth ]; do
    indent="$indent    "
    i=$((i + 1))
  done

  local refs size last
  refs=$(get_refcount "$tag")
  size=$(du -h "$(snapshot_path "$tag")/disk.qcow2" 2>/dev/null | awk '{print $1}')
  last=$(read_meta "$tag" last_used 2>/dev/null | cut -dT -f1)
  printf '%s└── %s   [refs: %s, %s, %s]\n' "$indent" "$tag" "$refs" "${size:-?}" "${last:-?}"

  # Recurse into children.
  awk -F'\t' -v p="$tag" '$1 == p { print $2 }' "$edges" | while read -r child; do
    _render_subtree "$edges" "$child" "$((depth + 1))"
  done
}
```

- [ ] **Step 2: Wire `tree` into the dispatcher**

```bash
case "$sub" in
  create) aq_snapshot_create "$@" ;;
  ls)     aq_snapshot_ls "$@" ;;
  rm)     aq_snapshot_rm "$@" ;;
  tag)    aq_snapshot_tag "$@" ;;
  tree)   aq_snapshot_tree "$@" ;;
  *)
    stderr "Usage: aq snapshot {create|ls|rm|tag|tree} ..."
    exit 1
    ;;
esac
```

- [ ] **Step 3: Manual check**

```bash
./aq snapshot tree
```

Expected: forest with `base (alpine-3.22.2-aarch64)` and `└── snap-test-tag   [refs: 0, 100M-ish, 2026-05-01]`.

- [ ] **Step 4: Commit**

```bash
git add aq
git commit -m "Implement aq snapshot tree"
```

---

## Task 7: `aq new --from-snapshot=<tag>`

Make `aq new` accept a snapshot tag as the disk source for the new VM.

**Files:**
- Modify: `aq` (`aq_new` argument parsing and the `qemu-img create -b` line)

- [ ] **Step 1: Locate aq_new and review**

Run: `grep -n 'aq_new()\|qemu-img create -b\|.needs_first_boot_setup' aq | head`
Expected: aq_new starts around line 380; the `qemu-img create -b $BASE_DIR/$ARCH/$LATEST_ALPINE_BASE ...` line and the `touch .needs_first_boot_setup` line are both inside `aq_new`.

- [ ] **Step 2: Replace `aq_new` argument parsing and disk-creation**

Replace the existing `aq_new` body with:

```bash
aq_new() {
  forwards=()
  local from_snapshot=""
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
      *)
        break
        ;;
    esac
  done

  if [ $# -gt 0 ]; then
    VM_NAME=$1
  else
    VM_NAME=$(random_vm_name)
  fi

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

  (
    cd $BASE_DIR
    mkdir $VM_NAME
    cd $VM_NAME
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
      # Fresh VM from base needs partition resize on first boot.
      touch .needs_first_boot_setup
    fi
    # Snapshot-derived VMs: the snapshot already contains a provisioned rootfs;
    # no resize / hostname rewrite needed.
  )

  if [ -n "$from_snapshot" ]; then
    local resolved
    resolved=$(resolve_tag "$from_snapshot")
    bump_refcount "$resolved"
    # Persist the tag on the VM so aq_rm can decrement on cleanup.
    echo "$resolved" > "$BASE_DIR/$VM_NAME/.from_snapshot"
  fi

  stderr Created:
  echo $VM_NAME
}
```

- [ ] **Step 3: Update aq_rm to drop refcount on snapshot-derived VMs**

Find `aq_rm` (around the original line 611):

Old:
```bash
aq_rm() {
  VM_NAME=${1:-}
  [ -z "$VM_NAME" ] && stderr 'Error: VM name required: `aq rm <vm-name>`.' && exit 1
  ! vm_exists "$VM_NAME" && stderr "Error: VM '$VM_NAME' does not exist." && exit 1

  aq_stop $VM_NAME
  rm -rf $BASE_DIR/$VM_NAME
  stderr "Removed" $VM_NAME
}
```

New:
```bash
aq_rm() {
  VM_NAME=${1:-}
  [ -z "$VM_NAME" ] && stderr 'Error: VM name required: `aq rm <vm-name>`.' && exit 1
  ! vm_exists "$VM_NAME" && stderr "Error: VM '$VM_NAME' does not exist." && exit 1

  aq_stop $VM_NAME

  # If this VM was created from a snapshot, drop the snapshot's refcount.
  local from_marker="$BASE_DIR/$VM_NAME/.from_snapshot"
  if [ -f "$from_marker" ]; then
    local snap
    snap=$(cat "$from_marker")
    [ -n "$snap" ] && drop_refcount "$snap"
  fi

  rm -rf $BASE_DIR/$VM_NAME
  stderr "Removed" $VM_NAME
}
```

- [ ] **Step 4: Manual end-to-end check**

```bash
# Create a marker inside a VM, snapshot it, derive a new VM, verify the marker is there.
VM=snapsrc-$$
./aq new "$VM"
./aq start "$VM"
./aq exec "$VM" 'echo "hello from snapshot" > /root/snapmarker'
./aq stop "$VM"
./aq snapshot create "$VM" deps-test
./aq rm "$VM"

NEW=snapdst-$$
./aq new --from-snapshot=deps-test "$NEW"
./aq start "$NEW"
./aq exec "$NEW" 'cat /root/snapmarker'
./aq snapshot ls
./aq rm "$NEW"
./aq snapshot ls
./aq snapshot rm deps-test
```

Expected:
- `cat /root/snapmarker` outputs `hello from snapshot`.
- After `aq new --from-snapshot=deps-test ...`, `aq snapshot ls` shows `deps-test` with `REFS=1`.
- After `aq rm "$NEW"`, refs drop to 0.
- `aq snapshot rm deps-test` succeeds.

- [ ] **Step 5: Commit**

```bash
git add aq
git commit -m "Implement aq new --from-snapshot=<tag>"
```

---

## Task 8: e2e snapshot test

A scripted version of the manual flow from Task 7 that runs in CI.

**Files:**
- Create: `tests/snapshots.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Create `tests/snapshots.sh`**

```bash
#!/usr/bin/env bash
# E2E test for aq snapshots:
# - provision VM, leave a marker
# - stop, snapshot, remove source VM
# - new VM from snapshot
# - verify marker exists
# - verify refcount semantics

set -eu
set -o pipefail

AQ="${AQ:-./aq}"
SRC_VM="aq-snap-src-$$"
DST_VM="aq-snap-dst-$$"
TAG="aq-snap-test-$$"

cleanup() {
  set +e
  "$AQ" stop "$SRC_VM" 2>/dev/null
  "$AQ" rm   "$SRC_VM" 2>/dev/null
  "$AQ" stop "$DST_VM" 2>/dev/null
  "$AQ" rm   "$DST_VM" 2>/dev/null
  "$AQ" snapshot rm --force "$TAG" 2>/dev/null
}
trap cleanup EXIT

echo "[snap] aq new $SRC_VM"
"$AQ" new "$SRC_VM"
"$AQ" start "$SRC_VM"

echo "[snap] mark inside VM"
"$AQ" exec "$SRC_VM" 'echo "marker-$(uname -m)" > /root/snapmarker'

echo "[snap] stop source VM"
"$AQ" stop "$SRC_VM"

echo "[snap] aq snapshot create $SRC_VM $TAG"
"$AQ" snapshot create "$SRC_VM" "$TAG"

echo "[snap] aq snapshot ls"
"$AQ" snapshot ls | grep -q "$TAG" || { echo "[snap] FAIL: $TAG not in ls"; exit 1; }

echo "[snap] aq rm $SRC_VM (source VM no longer needed)"
"$AQ" rm "$SRC_VM"

echo "[snap] aq new --from-snapshot=$TAG $DST_VM"
"$AQ" new --from-snapshot="$TAG" "$DST_VM"
"$AQ" start "$DST_VM"

echo "[snap] verify marker survived"
out=$("$AQ" exec "$DST_VM" 'cat /root/snapmarker')
if ! echo "$out" | grep -q '^marker-'; then
  echo "[snap] FAIL: expected marker-*, got '$out'"
  exit 1
fi

echo "[snap] verify refcount = 1"
refs=$("$AQ" snapshot ls | awk -v t="$TAG" '$1 == t { print $3 }')
if [ "$refs" != "1" ]; then
  echo "[snap] FAIL: expected refcount 1, got '$refs'"
  exit 1
fi

echo "[snap] aq rm $DST_VM"
"$AQ" rm "$DST_VM"

echo "[snap] verify refcount = 0 after dst removed"
refs=$("$AQ" snapshot ls | awk -v t="$TAG" '$1 == t { print $3 }')
if [ "$refs" != "0" ]; then
  echo "[snap] FAIL: expected refcount 0 after rm, got '$refs'"
  exit 1
fi

echo "[snap] aq snapshot rm $TAG"
"$AQ" snapshot rm "$TAG"

echo "[snap] PASSED"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x tests/snapshots.sh`

- [ ] **Step 3: Add it to the test runner**

Old `tests/run.sh`:
```bash
#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
bash tests/smoke.sh
```

New `tests/run.sh`:
```bash
#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
bash tests/smoke.sh
bash tests/snapshots.sh
```

- [ ] **Step 4: Run on macOS**

Run: `bash tests/run.sh`
Expected: `[smoke] PASSED` then `[snap] PASSED`. Total time ~60-90 seconds (smoke + snapshot create/copy + restore boot).

- [ ] **Step 5: Commit**

```bash
git add tests/snapshots.sh tests/run.sh
git commit -m "Add e2e snapshot test"
```

---

## Task 9: README + CHANGELOG + version bump

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `aq` (VERSION line)

- [ ] **Step 1: Add a "Snapshots" section to `README.md`**

Find the "Cheat Sheet" section. Insert a new section right after it:

```markdown
### Snapshots

    aq new myrails
    aq start myrails
    # ... provision (apk add, bundle install, db:setup, ...)
    aq stop myrails
    aq snapshot create myrails rails-deps
    aq snapshot ls
    aq snapshot tree

    aq new --from-snapshot=rails-deps shard-1
    aq new --from-snapshot=rails-deps shard-2
    aq start shard-1
    aq start shard-2
    # Both shards start from the same provisioned state — no apk add, no bundle install.

Snapshots are stored under `~/.local/share/aq/snapshots/<arch>/<tag>/` and live in
the same architecture as the host. They are *cold* snapshots — disk state only,
no live memory. New VMs cold-boot from the snapshot's disk; the kernel boots
fresh, but everything you installed is already there.
```

- [ ] **Step 2: Add a `2.1.0` entry to `CHANGELOG.md`**

Replace the `## Unreleased` section:

```markdown
## Unreleased

## 2.1.0 "Frozen" 2026-05-XX

### New Features

- `aq snapshot create/ls/rm/tag/tree` for managing cold snapshots of stopped
  VMs. Snapshots store disk state under `~/.local/share/aq/snapshots/<arch>/<tag>/`
  and carry a `meta.json` (parent, source VM, base image, timestamps) and a
  refcount. Aliases under `tags/<arch>/<name>` are plain symlinks.
- `aq new --from-snapshot=<tag> [vm-name]` creates a new VM whose disk overlays
  a snapshot, skipping `first_boot_setup`. Multiple VMs can derive from one
  snapshot; their thin overlays only store deltas.
- `aq snapshot tree` visualises the backing chain as a forest rooted at the
  alpine base image.
- `aq rm <vm>` decrements the refcount on the snapshot a VM was derived from
  (if any), so `aq snapshot rm` can detect orphaned snapshots safely.

### Internal

- New helper section in `aq` for snapshot directory layout, `meta.json`
  read/write, and refcount management. JSON is read with grep/sed (no jq
  dependency).
- Backing chains use absolute paths, so snapshots remain valid across host
  directory moves of the parent VM but not across machines.

### Limitations (Phase 2A)

- Snapshots are cold (disk only). Phase 2B adds live memory state for
  millisecond restore.
- `aq snapshot create` requires the source VM to be stopped.
- `aq snapshot rm` does not yet auto-clean parent snapshots whose refcount
  reaches 0; that is a deliberate Phase 5 decision.
```

- [ ] **Step 3: Bump VERSION**

```bash
sed -i.bak 's/^VERSION=2\.0\.0/VERSION=2.1.0/' aq && rm aq.bak
grep '^VERSION=' aq
```

Expected: `VERSION=2.1.0`.

- [ ] **Step 4: Run smoke + snapshot tests one more time**

Run: `bash tests/run.sh`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add aq README.md CHANGELOG.md
git commit -m "Release 2.1.0 \"Frozen\" — cold snapshots"
```

---

## Task 10: Push, CI verification, merge, tag, release

**Files:** none (operational steps).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin phase-2a-cold-snapshots
```

- [ ] **Step 2: Wait for CI**

Run: `gh run list --branch phase-2a-cold-snapshots --limit 1`
Wait for the most recent run to finish. The smoke test must still pass; the new snapshot test must also pass on Ubuntu KVM.

If snapshot test fails on Linux but passes on macOS, expect the failure to be one of:
- A `qemu-img info --output=json` field-name difference between qemu versions (macOS brew vs Ubuntu apt). Fix: tweak the `grep`/`sed` extraction in `aq_snapshot_create`.
- A `du -h` short-format difference (BSD vs GNU). Fix: switch to `du -h | awk '{print $1}'` already in the plan; if still mismatched, use `qemu-img info --output=json` and parse `actual-size`.

- [ ] **Step 3: Merge to main**

After CI is green:

```bash
git checkout main
git pull --ff-only
git merge --ff-only phase-2a-cold-snapshots
git push origin main
git branch -d phase-2a-cold-snapshots
git push origin --delete phase-2a-cold-snapshots
```

- [ ] **Step 4: Tag and release**

```bash
git tag -a v2.1.0 -m 'aq 2.1.0 "Frozen" — cold snapshots'
git push origin v2.1.0
gh release create v2.1.0 --title 'aq 2.1.0 "Frozen"' \
  --notes "Cold snapshots: aq snapshot create/ls/rm/tag/tree, plus aq new --from-snapshot. See CHANGELOG.md."
```

---

## Self-Review Checklist

Run before declaring the plan done.

- **Spec coverage:**
  - `aq snapshot create` (cold subset) → Task 2 ✓
  - `aq snapshot ls` → Task 3 ✓
  - `aq snapshot rm` (with refcount) → Task 4 ✓
  - `aq snapshot tag` → Task 5 ✓
  - `aq snapshot tree` → Task 6 ✓
  - `aq new --from-snapshot=<tag>` → Task 7 ✓
  - Cache layout (`snapshots/<arch>/<tag>/disk.qcow2 + meta.json + refcount`, `tags/<arch>/<name>` symlinks) → Tasks 1, 2 ✓
  - Refcount inc/dec on child create / VM derive / VM rm → Tasks 1, 2, 7 ✓
  - **Phase 2B (live memory, `-incoming`, fan-out, `--count`)** → out of scope, deferred. ✓
- **Placeholder scan:** none — every step contains the actual code or the actual command. The "if Linux fails this way, fix that" hint in Task 10 lists concrete possibilities, not "tweak as needed".
- **Type / name consistency:**
  - `snapshot_path`, `tag_path`, `read_meta`, `write_meta`, `bump_refcount`, `drop_refcount`, `get_refcount`, `resolve_tag`, `snapshot_exists`, `snapshots_dir`, `tags_dir` are referenced identically across Tasks 1, 2, 3, 4, 5, 6, 7.
  - `meta.json` field names (`tag`, `parent`, `arch`, `base_image`, `created`, `last_used`, `source_vm`, `has_memory`) are written in Task 1 and read in Tasks 2, 3, 4, 6.
  - `--from-snapshot` is the same flag spelling across `aq_new` (Task 7), README (Task 9), and CHANGELOG (Task 9).

## Out of Scope (Phase 2B and beyond)

- **Live memory snapshots** (savevm + migrate to memory.bin, restore via `-incoming "exec:cat memory.bin"`). The spec's <500ms restore goal lives here.
- **Fan-out** (`aq new --from-snapshot --count=N`, `aq fanout`). Phase 3.
- **OCI artifact push/pull**. Phase 5.
- **`AQ_FACTORS` declarative cache invalidation**. Phase 5.
- **Snapshot of running VM** (Phase 2B will add this; Phase 2A requires `aq stop` first).
