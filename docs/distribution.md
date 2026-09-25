# Build, install, and package Context Desk

The repository is the app's source distribution: `Sources`, `Tests`, `Assets`, the Swift package files, and `scripts`. Git does not contain compiled bundles or application state. Private historical discussion exports referenced by the local improvement log are not part of the source distribution.

## Requirements and local installation

Use an Apple Silicon Mac running macOS 14 or later, a compatible Swift 6 toolchain, and the official Codex CLI installed separately. See `building.md` for SDK selection and the local toolchain repair. Intel builds and older supported macOS versions have not been validated.

```sh
git clone https://github.com/DPostnik/Context-Desk.git
cd Context-Desk
zsh scripts/build-app.sh
zsh scripts/test.sh
open 'build/Context Desk.app'
```

To install the built app, quit it with Cmd+Q, then copy `build/Context Desk.app` to your user Applications folder (`~/Applications`). Reopen the installed copy. The bundle is ad-hoc signed, not notarized; this is a local/developer distribution, not a notarized public release.

Direct mode does not install or launch Headroom. Its optional installer is `scripts/install-headroom.sh`; external dependencies and the runner are in `integrations/headroom`, and the Swift adapter is in `Sources/HeadroomIntegration`. See `headroom.md`. No automatic installation or replacement of external providers takes place.

## Packaging

After a successful build and verification, create a local archive:

```sh
zsh scripts/package-app.sh
```

The script validates the bundle signature and checks the source digest against the build manifest before archiving. It does not rebuild, run tests, commit, push, upload a release, or include private app data. The archive in `dist` is suitable for manual installation by extracting and copying the app bundle. Public distribution still needs signing/notarization and release validation.

The agreed publication order is: finish changes, build successfully, verify the result and relevant checks, commit, then push. Failed or blocked required validation must be reported before publication.
