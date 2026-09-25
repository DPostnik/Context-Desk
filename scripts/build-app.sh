#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/swift-task.py build "$@"
zsh scripts/build-icon.sh
staging="$(mktemp -d "$PWD/build/app-stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Context Desk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/local-build/ContextDesk "$app/Contents/MacOS/ContextDesk"
cp .build/local-build/build-info.json "$app/Contents/Resources/build-info.json"
cp Assets/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Context Desk</string>
<key>CFBundleDisplayName</key><string>Context Desk</string>
<key>CFBundleIdentifier</key><string>local.daniil.contextdesk</string>
<key>CFBundleExecutable</key><string>ContextDesk</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.contextdesk.project-order</string>
<key>UTTypeDescription</key><string>Context Desk project order</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 - "$app" <<'PY'
from pathlib import Path
import sys

staged = Path(sys.argv[1])
destination = Path('build/Context Desk.app')
backup = staged.parent / 'previous.app'
if destination.exists():
    destination.rename(backup)
try:
    staged.rename(destination)
except BaseException:
    if backup.exists():
        backup.rename(destination)
    raise
print(f'Updated: {destination.resolve()}')
print('Quit the running app with Cmd+Q and reopen it to load this build.')
PY
