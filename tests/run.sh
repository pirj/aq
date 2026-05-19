#!/usr/bin/env bash
# Test entry point. Add new test scripts as we grow the suite.
set -eu
cd "$(dirname "$0")/.."
bash tests/unit-helpers.sh
bash tests/smoke.sh
bash tests/snapshots.sh
bash tests/live-snapshots.sh
bash tests/fanout.sh
bash tests/direct-kernel-boot.sh
bash tests/size-base-catalog.sh
bash tests/skip-fast-boot.sh
bash tests/guest-cleanup.sh
