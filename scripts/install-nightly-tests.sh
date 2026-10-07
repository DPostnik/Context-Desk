#!/bin/zsh
# Install (or with --uninstall remove) the daily launchd job for nightly-tests.sh.
# A Mac asleep at the scheduled time runs the job on wake.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.contextdesk.nightly-tests
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == --uninstall ]]; then rm -f "$PLIST"; echo "Removed $LABEL"; exit 0; fi
HOUR="${CONTEXTDESK_NIGHTLY_HOUR:-3}"
mkdir -p "${PLIST:h}" "$HOME/Library/Logs/ContextDesk/nightly-tests"
cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$REPO/scripts/nightly-tests.sh</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>30</integer></dict>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string></dict>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/ContextDesk/nightly-tests/launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ContextDesk/nightly-tests/launchd.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL: daily at $HOUR:30. Status: ~/Library/Logs/ContextDesk/nightly-tests/latest-status"
