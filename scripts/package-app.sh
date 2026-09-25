#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Context Desk.app"
codesign --verify --deep --strict "$app"
python3 - "$app" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path.cwd()
app = pathlib.Path(sys.argv[1])
metadata = json.loads((app / 'Contents/Resources/build-info.json').read_text())
digest = hashlib.sha256()
for path in sorted([root / 'Package.swift', root / 'Package.resolved'] + list((root / 'Sources').rglob('*'))):
    if path.is_file():
        digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes())
if digest.hexdigest() != metadata['sourceSHA256']:
    sys.exit('App does not match current sources. Run zsh scripts/build-app.sh first.')
PY
mkdir -p dist
archive="$PWD/dist/Context-Desk-macOS.zip"
staging="$(mktemp -d "$PWD/dist/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/Context-Desk-macOS.zip"
unzip -tq "$staging/Context-Desk-macOS.zip"
mv "$staging/Context-Desk-macOS.zip" "$archive"
shasum -a 256 "$archive"
