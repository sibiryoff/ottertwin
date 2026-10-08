# Disclaimer

Hi everyone! As often happens, this app is the result of me looking for a free dual-pane file manager that looks good on macOS and, most importantly, supports integrity verification for copied files. I couldn’t find anything suitable, so I decided to try vibe-coding one myself — and at the same time test some “AI dark factory” scenarios.

So — **warning! — do not use this app yet!**  It is in a very early pre-pre-alpha version, and although you can run it, correct behavior and the advertised functionality are not guaranteed at all. Not yet.

<p align="center">
  <img src="ottertwin_logo.png" alt="OtterTwin logo" width="360">
</p>

# OtterTwin

A macOS two-panel file manager designed for safe file transfers to NAS devices over SMB. Inspired by Total Commander.

## Features

- **Two-panel layout** — side-by-side directory browsing with keyboard navigation (Tab to switch panels, arrows to move, Enter to open, Backspace to go up)
- **SHA-256 verification** — checksum is computed inline during copy with zero extra I/O, then verified on the destination to guarantee data integrity
- **SMB support** — connect to network shares via the built-in SMB connect dialog; credentials saved to Keychain
- **Column sorting** — click Name, Size, or Modified headers to sort; directories always listed first
- **Quick-access bar** — one-click navigation to Home, Desktop, Documents, Downloads, and /Volumes
- **Breadcrumb navigation** — click any path component to jump there
- **F5 Copy / F6 Move / F8 Delete** — standard commander-style file operations with live progress

## Requirements

- macOS 14.0+
- Xcode 16.4 (the version CI uses)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.42.0 (the version CI uses)

## Build

`OtterTwin.xcodeproj` is **not** tracked in git: it is generated from `project.yml`.
Only `OtterTwin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
is committed, so Swift package versions are reproducible. Regenerate the project after
pulling or after adding/removing source files:

```bash
brew install xcodegen   # make sure `xcodegen --version` prints 2.42.0
xcodegen generate
open OtterTwin.xcodeproj
```

For a command-line build (no code signing required):

```bash
xcodebuild -project OtterTwin.xcodeproj -scheme OtterTwin -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
open build/Build/Products/Debug/OtterTwin.app
```

## Tests

Unit and snapshot tests (the same command CI runs in the `build-and-test` job):

```bash
xcodegen generate
xcodebuild test -project OtterTwin.xcodeproj -scheme OtterTwinTests \
  -destination 'platform=macOS' -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Continuous integration

`.github/workflows/macos-ci.yml` runs on every pull request and every push to `main`
(`macos-15` runner, Xcode 16.4, XcodeGen 2.42.0):

- **`build-and-test`** (the check merges are gated on): generates the project, resolves packages strictly from
  `Package.resolved`, builds without signing secrets and runs `OtterTwinTests` (unit +
  snapshot tests). Snapshot recording is disabled, so a missing or different baseline fails
  the check. On failure the `.xcresult` bundle and the full log are uploaded as artifacts.
- **`ui-tests`** (non-blocking): runs the XCUITest suite and always uploads its results.
  It is informational only and is **not** counted as verified coverage.
- **`record-snapshots`** (manual, *Run workflow* with "record snapshots" checked): records
  snapshot baselines on the CI runner and uploads them as an artifact. Baselines are never
  committed automatically; changes go through a dedicated PR with before/after images.

Not covered by CI: real SMB/NAS transfers (need a real server) and anything that needs the
owner's machine. These are validated manually through the gate issues.
