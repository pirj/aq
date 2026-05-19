#!/usr/bin/env bash
# One-shot installer for a patched QEMU that fixes the v11.0.0 aarch64
# HVF live-restore assertion. Builds qemu-system-aarch64 from v11.0.0
# sources + Scott J. Goldman's upstream fix 06fd39e426 and symlinks it
# under ~/.local/bin so aq picks it up via PATH.
#
# Safe to re-run: skips clone/configure/build when the existing tree
# already has the expected commit + binary.
#
# Run with: bash install-patched-qemu.sh
# Override target dir: PATCHED_QEMU_DIR=/some/other/path bash install-patched-qemu.sh
#
# Removes nothing — to undo, `rm ~/.local/bin/qemu-system-aarch64` and
# unshadow the brew binary.

set -eu
set -o pipefail

QEMU_TAG="${QEMU_TAG:-v11.0.0}"
QEMU_BUILD_DIR="${PATCHED_QEMU_DIR:-$HOME/.local/share/aq-patched-qemu}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/0001-hvf-stop-prealloc-cpreg-vmstate.patch"

[ "$(uname -s)" = Darwin ] || { echo "This script targets macOS (Darwin). Linux KVM is unaffected." >&2; exit 1; }
[ "$(uname -m)" = arm64 ]  || { echo "This script targets Apple Silicon (arm64)." >&2; exit 1; }
[ -f "$PATCH_FILE" ] || { echo "Patch file not found at $PATCH_FILE" >&2; exit 1; }

mkdir -p "$BIN_DIR"

# Ensure build deps. Brew is idempotent on already-installed kegs.
echo "==> ensuring brew build deps"
for pkg in ninja pkg-config glib pixman python@3.13; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

# Clone if missing.
if [ ! -d "$QEMU_BUILD_DIR/.git" ]; then
  echo "==> cloning qemu $QEMU_TAG into $QEMU_BUILD_DIR"
  git clone --depth=1 --branch "$QEMU_TAG" https://gitlab.com/qemu-project/qemu.git "$QEMU_BUILD_DIR"
fi

cd "$QEMU_BUILD_DIR"

# Apply the patch if not already applied. Use the commit's first-line
# Subject as the idempotency marker.
if git log --oneline | grep -q 'Stop pre-allocating cpreg_vmstate arrays'; then
  echo "==> patch already applied"
else
  echo "==> applying upstream fix 06fd39e426"
  git am --keep-non-patch "$PATCH_FILE"
fi

# Configure if no build dir yet.
if [ ! -f build/build.ninja ]; then
  echo "==> configuring (aarch64-softmmu + hvf only)"
  ./configure --target-list=aarch64-softmmu --enable-hvf --disable-docs \
              --disable-gtk --disable-vnc --disable-curses --disable-sdl --disable-cocoa
fi

# Build incrementally.
echo "==> building qemu-system-aarch64"
ninja -C build qemu-system-aarch64

# Verify the binary is the patched one. QEMU_TAG already has a leading "v"
# (e.g. v11.0.0), so the suffix we look for is the bare tag with the
# git-describe trailer: "(v11.0.0-1-...".
ver_string=$(./build/qemu-system-aarch64 --version | head -1)
echo "==> $ver_string"
case "$ver_string" in
  *"($QEMU_TAG-"*)
    echo "    looks patched (git-suffix in version string)"
    ;;
  *)
    echo "    note: version string didn't include a git suffix — check this is the rebuilt binary" >&2
    ;;
esac

# Symlink under ~/.local/bin so aq picks it up via PATH.
ln -sf "$QEMU_BUILD_DIR/build/qemu-system-aarch64" "$BIN_DIR/qemu-system-aarch64"
echo "==> symlinked $BIN_DIR/qemu-system-aarch64 -> $QEMU_BUILD_DIR/build/qemu-system-aarch64"

# Final reminder.
if ! echo "$PATH" | tr ':' '\n' | grep -qFx "$BIN_DIR"; then
  cat <<HINT

Next step: prepend $BIN_DIR to PATH so aq finds the patched qemu:

  export PATH="$BIN_DIR:\$PATH"

Add the line to your ~/.zshrc (or ~/.bashrc) to make it permanent.
Then verify:

  which -a qemu-system-aarch64
  qemu-system-aarch64 --version           # expect a ($QEMU_TAG-...) suffix
HINT
else
  echo "==> $BIN_DIR already on PATH; new shells will pick up the patched binary"
fi
