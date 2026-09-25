#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
plugin_dist="${1:-$PWD/../../dist}"
mkdir -p "$plugin_dist"
plugin_dist="$(cd "$plugin_dist" && pwd)"
staging="$(mktemp -d "$plugin_dist/headroom-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/headroom"
cp plugin.json install.sh headroom_server.py headroom.in headroom.lock README.md "$staging/headroom/"
ditto -c -k --keepParent "$staging/headroom" "$staging/Headroom-1.0.0.contextdesk-plugin.zip"
unzip -tq "$staging/Headroom-1.0.0.contextdesk-plugin.zip"
mv "$staging/Headroom-1.0.0.contextdesk-plugin.zip" "$plugin_dist/Headroom-1.0.0.contextdesk-plugin.zip"
shasum -a 256 "$plugin_dist/Headroom-1.0.0.contextdesk-plugin.zip"
