#!/bin/zsh
# Compatibility entry point; all provider-specific installation belongs to the plugin.
set -euo pipefail
exec zsh "$(dirname "$0")/../plugins/headroom/install.sh" "$@"
