# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PluralMac is a native macOS app (SwiftUI, minimum macOS 14.0) that runs multiple isolated instances of the same macOS application simultaneously. Each instance gets its own data directory under `~/Library/PluralMac/Data/{uuid}/`. Isolation strategy varies by app type: `--user-data-dir` for Chromium, `-profile` for Firefox, `HOME` env var redirection for Electron/generic apps, `--mu` for Spotify.

## Build Commands

```bash
# Build (Release, ad-hoc signed)
xcodebuild clean build \
  -project PluralMac.xcodeproj \
  -scheme PluralMac \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

# Debug build
xcodebuild build \
  -project PluralMac.xcodeproj \
  -scheme PluralMac \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

No tests, linter, or formatter are configured.

## Architecture

**Pattern**: MVVM with SwiftUI. All services are Swift actors with `.shared` singletons. Cross-component communication via `NotificationCenter`. Structured concurrency (`async/await`) throughout.

**Data flow**: `PluralMacApp` → `ContentView` (owns `@State InstanceViewModel`) → delegates to service actors for persistence, launching, import/export.

**Key layers**:

- **Models** — `AppInstance` (instance config with UUID, paths, env vars, args), `AppType` (enum: chromium/firefox/electron/toDesktop/generic/sandboxed/system), `Application` (represents a macOS .app bundle, auto-detects type)
- **ViewModel** — `InstanceViewModel` is the single `@Observable` VM handling all CRUD, launch, search, import/export
- **Services** — All actors: `DirectLauncher` (NSWorkspace-based launch with env vars + args), `InstanceStore` (JSON persistence to `~/Library/PluralMac/instances.json`), `IconExtractor`/`IconCache`, `CompatibilityDatabase` (loads `compatibility.json`), `ProcessTracker`, `MenuBarManager`
- **Views** — `NavigationSplitView` with sidebar list + detail pane. Creation flow via sheet (`CreateInstanceView`). Settings via `SettingsView`.

**Launch mechanism**: `DirectLauncher` calls `NSWorkspace.openApplication()` with `createsNewApplicationInstance = true`, passing custom environment variables and arguments. No bundle creation needed.

**Note**: `BundleManager` is legacy dead code — the active path uses `DirectLauncher` exclusively. `AppTypeDetector` has overlapping logic with `Application.detectAppType`; the latter is what actually runs during app detection.

## Logging

Uses `OSLog` with subsystem `com.mtech.PluralMac` and per-service categories.
