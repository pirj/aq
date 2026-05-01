#!/usr/bin/env bash
# Test entry point. Add new test scripts as we grow the suite.
set -eu
cd "$(dirname "$0")/.."
bash tests/smoke.sh
bash tests/snapshots.sh
bash tests/live-snapshots.sh
