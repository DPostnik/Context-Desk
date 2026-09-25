# Local builds

Run from the repository root:

```sh
zsh scripts/test.sh
zsh scripts/build-app.sh
open 'build/Context Desk.app'
```

If Context Desk is already running, quit with Cmd+Q before reopening. Closing its window does not terminate the process. A source edit alone never updates the app.

Both scripts use `scripts/swift-task.py`. It locates the selected compiler with `xcrun`, checks an SDK by type-checking Foundation/SwiftUI/AppKit, and prefers SwiftPM when `swift package --version` succeeds. Actual compilation or test failures stop the command; they do not trigger a fallback. An explicit SDK can be selected with `CONTEXTDESK_SDK=/absolute/path/to/MacOSX.sdk` (it must pass the same check).

The app script builds a complete temporary bundle, signs it and verifies the signature before replacing `build/Context Desk.app`. Compilation, icon or signing failures leave the previous bundle in place. The bundle contains `Contents/Resources/build-info.json` with build time, compiler, SDK, backend and a digest of sources and package files.

## Toolchain repair — 2026-09-25

Installed Apple’s `Command Line Tools for Xcode 27.0-27.0` using `softwareupdate --install`. The package completed successfully without a macOS update or restart. `xcrun swiftc --version` now reports Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), and `xcrun swift package --version` starts successfully (`Swift 6.4.0-dev`). The SDK probe now type-checks an actual SwiftUI view using `@State`, not only imports. CLT 27 lacks the `SwiftUIMacros` plugin needed by SDK 27, so this probe rejects that SDK and selects the installed compatible macOS 26.5 SDK. The app builds successfully with SwiftPM again. Test results are recorded in `improvements.md`.

## Previous toolchain problem (before repair)

Observed on this Mac on 2026-09-25:

- Swift 6.3.3 runs, but SwiftPM crashes loading a missing `BuildServerProtocol` symbol.
- `xcrun --show-sdk-path` selects macOS 27.0, whose Swift interfaces require a newer compiler.
- The installed macOS 26.5 SDK works with this compiler.
- Swift Testing's installed framework and macro plugin also disagree (`sourceBounds` versus `sourceLocation`). Before the repair, full tests were blocked; the test script detected this before compiling project targets.

When SwiftPM cannot start, the scripts print the reason and compile the current sources directly with `swiftc` in a fresh temporary directory. This is a project-specific workaround, not a repair of the system installation. The test path requires a working Swift Testing framework/macro pair and uses its real runner, including failing exit statuses. It does not replace tests with assertions or claim success when the test infrastructure fails.

The fallback requires the existing clean TOMLDecoder checkout at the exact revision in `Package.resolved` (0.4.5). It never downloads a substitute. On a fresh checkout, use a working SwiftPM installation to resolve dependencies first. If dependencies or target structure change, update the fallback recipe alongside `Package.swift`. `--direct` exercises this path even with a working SwiftPM. SDK and SwiftPM diagnostics are stored in `.build/local-build/`.

## Restore the standard toolchain

Install a complete, matching release of Command Line Tools or Xcode using [Apple's installation instructions](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools). Select that installation using [Apple's command-line tools settings](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings). Do not manually mix frameworks, compilers and SDKs from different releases.

Then check `xcrun swift --version`, `xcrun swift package --version` and run the two project scripts above. They automatically return to SwiftPM when it can start. The scripts never delete or change the system toolchain or global developer-directory selection.
