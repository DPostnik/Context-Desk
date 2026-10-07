#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
# Builds the opt-in capture harness while leaving it disabled in ordinary checks.
# No model calls, app boot, scheduler startup or personal history are involved.
zsh scripts/test.sh
CONTEXTDESK_PUBLIC_CAPTURE="$PWD/media" xcrun swift test --skip-build --disable-xctest --filter publicDemoRenderProbe
