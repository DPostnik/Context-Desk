#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if ! xcodebuild -checkFirstLaunchStatus; then
  print -u2 'iOS build blocked: complete Xcode first-launch setup and license acceptance. The diagnostic above identifies the missing step.'
  exit 1
fi
if ! xcrun --sdk iphonesimulator --show-sdk-path; then
  print -u2 'iOS build blocked: the selected Xcode installation has no usable iOS Simulator SDK. Check DEVELOPER_DIR and Xcode components.'
  exit 1
fi
xcodebuild -project Mobile/ContextMobile.xcodeproj -scheme ContextMobile -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/mobile CODE_SIGNING_ALLOWED=NO build
