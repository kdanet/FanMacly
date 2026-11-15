#!/bin/bash
# Local CI: build every product and run the unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test 2>&1 | tee build/test.log | grep -E "Executed .* tests|error:" || true
if grep -qE "error:|with [1-9][0-9]* failures?" build/test.log || ! grep -q "with 0 failures" build/test.log; then
    echo "FAILED (see build/test.log)" >&2
    exit 1
fi
echo "OK"
