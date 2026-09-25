#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
runtime_root="$HOME/Library/Application Support/Context Desk/headroom"
uv_bin="${UV_BIN:-$HOME/.local/bin/uv}"
if [[ ! -x "$uv_bin" ]]; then uv_bin="$(command -v uv)"; fi
mkdir -p "$runtime_root"
chmod 700 "$runtime_root"
if [[ ! -x "$runtime_root/venv/bin/python" ]]; then
  "$uv_bin" venv --python 3.12 "$runtime_root/venv"
fi
"$uv_bin" pip sync --python "$runtime_root/venv/bin/python" --require-hashes integrations/headroom/headroom.lock
cp integrations/headroom/headroom_server.py "$runtime_root/headroom_server.py"
chmod 600 "$runtime_root/headroom_server.py"
printf '%s\n' "Headroom 0.38.0 installed for Context Desk. No Codex configuration changed."
