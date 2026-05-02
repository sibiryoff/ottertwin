# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

OtterTwin is a macOS 14+ two-panel file manager (inspired by Total Commander) designed for safe file transfers to NAS devices over SMB. Its defining feature is SHA-256 checksum verification: the source hash is computed inline during copy with zero extra I/O, and the destination is verified afterward to guarantee data integrity.

## Build & Run

The `.xcodeproj` is generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen). Regenerate it after editing `project.yml`:

```bash
cd /Users/mas/projects/ottertwin
xcodegen generate
```

Build and run (no signing required for local dev):

```bash
xcodebuild -project OtterTwin.xcodeproj -scheme OtterTwin -configuration Debug \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
open build/Build/Products/Debug/OtterTwin.app
```

Or just open in Xcode:
```bash
open OtterTwin.xcodeproj
```

## Tests

```bash
xcodebuild test -project OtterTwin.xcodeproj -scheme OtterTwinTests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Run a single test class:
```bash
xcodebuild test -project OtterTwin.xcodeproj -scheme OtterTwinTests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:OtterTwinTests/ChecksumServiceTests
```

Tests use `XCTestCase` (not Swift Testing). The test target uses `TEST_HOST`/`BUNDLE_LOADER` pointing at the app binary. `OtterTwinApp` checks for `XCTestConfigurationFilePath` in env and renders `EmptyView` to prevent SwiftUI lifecycle from blocking the test runner.

## Architecture

### Layer overview

```
Views/ ──────── SwiftUI + AppKit
Services/ ───── Business logic (Swift actor / @Observable)
VFS/ ─────────── File system abstraction
Models/ ─────── Plain data types
```

### Key patterns

**`AppState`** (`Views/MainView.swift`) — `@Observable` class holding the two-panel state: left/right paths, selections, and active panel. `MainView` owns it as `@State`. Computed properties `sourcePath`, `destPath`, `sourceSelection` derive active-panel values.

**`SettingsService`** (`Services/SettingsService.swift`) — `@Observable` class backed by `UserDefaults`. Injected as `.environment(settings)` at the app root; consumed with `@Environment(SettingsService.self)`.

**VFS abstraction** (`VFS/VFSProvider.swift`) — `VFSProvider` protocol abstracts local and SMB file systems. `LocalProvider` uses `FileManager`/`FileHandle`. `SMBProvider` mounts a share via `SMBService` (NetFS) then delegates to `LocalProvider` at the mount point.

**`FileOperationService`** (`Services/FileOperationService.swift`) — Swift `actor` for thread-safe copy/move. Returns `AsyncThrowingStream<OperationState, Error>` for streaming progress. SHA-256 checksum is computed inline during copy (no extra I/O pass for source). A new instance is created per-operation call so live `SettingsService` values take effect immediately.

**`ChecksumService`** (`Services/ChecksumService.swift`) — Streams `ChecksumProgress` events (`.progress(Double)`, `.complete(hexDigest: String)`) via `AsyncThrowingStream`. Uses CryptoKit `SHA256`.

**`FileTableView`** (`Views/FileTableView.swift`) — `NSViewRepresentable` wrapping an `NSTableView`. Critical invariant: the `NSTableView` must **never be destroyed** between directory loads (destroying it resets first responder and breaks keyboard nav). `FilePanelView` keeps it permanently in the hierarchy using a `ZStack` and overlays the loading/error state on top. `makeFirstResponder` calls are deferred via `DispatchQueue.main.async` to fire after SwiftUI's render pass.

**`FileListView`** (private, `Views/FileTableView.swift`) — `NSTableView` subclass; overrides `keyDown` to intercept Return (36), numpad Enter (76), and Backspace (51).

### Entitlements

`OtterTwin/Resources/OtterTwin.entitlements` is managed **manually** — it is excluded from xcodegen's source glob and wired up via `CODE_SIGN_ENTITLEMENTS` build setting. Do not add `entitlements: path:` to `project.yml` as xcodegen will overwrite the file.

### Extensions

`VFS/Extensions.swift` — shared utilities: `URL.fileByteCount` and `Digest.hexString` (CryptoKit). After adding any new source file, re-run `xcodegen generate` so the `.xcodeproj` picks it up.
