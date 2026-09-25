#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
plugin_root="${CONTEXTDESK_PLUGINS_DIR:-$HOME/Library/Application Support/Context Desk/plugins}/headroom"
uv_bin="${UV_BIN:-$HOME/.local/bin/uv}"
if [[ ! -x "$uv_bin" ]]; then uv_bin="$(command -v uv)"; fi
# Install only while this plugin is stopped; do not mutate a live runtime.
if [[ -d "$plugin_root/data" ]]; then
  for ready in "$plugin_root"/data/ready-*.json(N); do
    print -u2 'Stop Context Desk before updating the Headroom plugin.'
    exit 1
  done
fi
mkdir -p "$plugin_root"
chmod 700 "$plugin_root"
if [[ ! -x "$plugin_root/venv/bin/python" ]]; then
  "$uv_bin" venv --python 3.12 "$plugin_root/venv"
fi
"$uv_bin" pip sync --python "$plugin_root/venv/bin/python" --require-hashes headroom.lock
cp headroom_server.py "$plugin_root/headroom_server.py"
chmod 600 "$plugin_root/headroom_server.py"
# Publish the manifest last so incomplete new installs are not discovered.
cp plugin.json "$plugin_root/plugin.json.tmp"
mv "$plugin_root/plugin.json.tmp" "$plugin_root/plugin.json"
print 'Плагин Headroom установлен. Обнови список плагинов и переподключись в Context Desk.'
