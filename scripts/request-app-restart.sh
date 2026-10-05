#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
exec 'build/Context Desk.app/Contents/MacOS/ContextDesk' --request-restart
