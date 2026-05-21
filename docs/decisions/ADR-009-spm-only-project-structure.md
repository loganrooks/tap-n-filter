# ADR-009: SPM-only project structure

## Status

Accepted

## Context

The Phase 0 spec (`docs/orchestration/phases/00-init.md` section 0.1) allows two ways to bootstrap the project: "Use `xcodebuild -create` or generate via `swift package init --type executable`, then add a macOS app target with SwiftUI lifecycle."

Two ways to organize the project follow from that choice:

1. **Xcode project (`.xcodeproj` or `.xcworkspace`)** — the traditional layout. Schemes, targets, build settings, and Info.plist managed by Xcode. Source files referenced explicitly in `project.pbxproj`.

2. **Swift Package Manager only (`Package.swift`)** — the source layout is filesystem-driven. Targets are declared in `Package.swift`. `xcodebuild` can build a Swift package directly when invoked from the package root.

The build machine for this project is running Apple's command-line developer tools (Swift 6.x toolchain) without a full Xcode.app install. `xcodebuild` against an `.xcodeproj` requires Xcode.app; `swift build` against a `Package.swift` does not. CI runners (`macos-14`) get a full Xcode via `maxim-lobanov/setup-xcode@v1`, so either path works in CI.

## Decision

Use **Swift Package Manager exclusively** for V1. Project layout:

```
Package.swift
Sources/
  tap-n-filter/      executable target (App entry, MenuBarExtra)
    App.swift
    Resources/
      Info.plist
  Capture/           library target
  Graph/             library target
  Effects/           library target
  Presets/           library target
Tests/
  CaptureTests/
  GraphTests/
  EffectsTests/
  PresetsTests/
```

CI uses `swift build` and `swift test` rather than `xcodebuild build` and `xcodebuild test`. The `xcodebuild` invocations in the original CI yaml are replaced. CI keeps the `setup-xcode` step so the Swift toolchain version on the runner matches a known-good Xcode SDK.

App bundling for release (`.app` structure with Info.plist) is performed by a shell script in `Build/` invoked during Phase 4. SPM does not produce `.app` bundles directly; the script wraps the built executable into an app bundle layout.

## Alternatives considered

### Xcode project (`.xcodeproj`)

Rejected for V1. Requires Xcode.app on the build machine; the current build machine has only command-line tools. Adding Xcode.app is a several-GB download and a sunk-cost configuration step the project does not need for V1's scope. SPM gives the same compile, run, and test capabilities for a Swift+SwiftUI macOS app, with simpler diffs (no `.pbxproj` churn) and cleaner version control.

The trade-off: Interface Builder, asset catalogs, and storyboard editing are absent. V1 uses no Interface Builder, no storyboards. The app icon (Phase 4) is built directly from PNGs into a `.icns` via `iconutil`; an asset catalog is not required.

### Hybrid (`Package.swift` consumed by an `.xcodeproj`)

Rejected for V1. The hybrid layout adds `.xcodeproj` overhead without adding capability that SPM-only lacks for this project's scope. If V1 ships and V2 needs Interface Builder for some new feature, the migration is `swift package generate-xcodeproj` (deprecated as a command but the layout pattern is well-understood) or an Xcode "Add Package Dependency" step.

## Consequences

**Enabled:**
- The build machine does not need Xcode.app installed.
- Source layout is filesystem-driven; no `.pbxproj` to diff or merge.
- New targets are one block in `Package.swift` and a new directory under `Sources/`.

**Precluded or constrained:**
- No Interface Builder. V1 has no storyboards or NIBs and doesn't need it.
- No asset catalog. App icons and resources are managed as flat files; the Phase 4 bundling script handles `.icns` generation.
- The Phase 0 CI yaml diverges from the bundled-as-scribed `xcodebuild` invocations. The replacement `swift build` / `swift test` invocations are functionally equivalent for SPM-only packages.

**Risks:**
- `MenuBarExtra` plus SPM-only macOS app bundling is a less common path. Some SwiftUI app lifecycle features that assume Xcode-driven Info.plist generation may need manual handling. Mitigation: the Info.plist is committed at `Sources/tap-n-filter/Resources/Info.plist` with `LSUIElement` set explicitly; the bundling script in Phase 4 copies it into the `.app/Contents/`.
- Future contributors familiar with the Xcode-project workflow will need to learn the SPM layout. Mitigation: the layout is standard; SPM is Apple's officially-supported path and is well-documented.

**Local test runs require a full Xcode install (not just Command Line Tools):**
Apple's `XCTest` framework is shipped with Xcode.app, not with the Command Line Tools. `swift test` against the package therefore needs Xcode locally. CI runners (`macos-14`) get a full Xcode via `setup-xcode` so CI runs the test suite normally. Developers without Xcode can still `swift build` and run the executable; they just cannot `swift test` until they install Xcode.

## References

- `docs/orchestration/phases/00-init.md` — Phase 0 spec; mentions both options.
- `docs/governance/coding-standards.md` — already specifies SPM for dependencies; this ADR extends that to the project structure itself.
