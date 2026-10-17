#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
exec 'build/Switchboard.app/Contents/MacOS/Switchboard' --request-restart
