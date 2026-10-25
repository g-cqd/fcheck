#!/bin/bash
# The full local gate: everything CI checks, runnable before every push.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests
swift test
swift run fcheck analyze Sources --strict
Scripts/lint-format.sh
Scripts/no-gcd.sh
echo "ci-local: all gates green"
