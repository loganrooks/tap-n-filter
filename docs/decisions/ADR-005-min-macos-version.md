# ADR-005: Minimum macOS Version

## Status

Accepted

## Context

The project needs to declare a minimum deployment target. Lower targets reach more users; higher targets unlock more APIs and reduce conditional-availability code.

Constraints from prior decisions:

- ADR-001 commits to Core Audio Process Taps, available since **macOS 14.4**.
- The user runs on a MacBook Air M4 (Apollo) on a current macOS version. No legacy constraint from the user's own machine.
- The V1 audience is users of the user's circle and people who find the project on GitHub. Not enterprise customers with deployment-version lockdown.

The Core Audio Process Tap API is the binding constraint. Without it, the entire capture layer needs a different approach (ScreenCaptureKit, or a different architecture). With it, the deployment target is at least 14.4.

## Decision

Minimum deployment target is **macOS 14.4**.

Both the SwiftUI app target and the Swift Package Manager configuration declare `macOS(.v14_4)` (or `macOS "14.4"` in `Package.swift`).

## Alternatives considered

### macOS 14.0 (Sonoma initial release)

Rejected because Core Audio Process Taps are not available until 14.4. Targeting 14.0 would force `@available(macOS 14.4, *)` guards around the entire capture layer, with no plan for what to do on 14.0–14.3.

### macOS 15.0 (Sequoia)

Tempting because 15.0 may have bug fixes for the Core Audio Process Tap API. Rejected because:

1. Excluding 14.x users gives up some real audience without a concrete win. The orchestrator does not know of specific 15.0-only fixes that would justify the cut.
2. 15.0 was released in late 2024; some users hadn't migrated by 2026 scribing time.

If specific 15.0-only fixes turn out to matter, the deployment target can be bumped in V1.x with an updating ADR. Bumping is forward-compatible (drops some users); lowering would require backfilling APIs and is the riskier change to leave for later.

### macOS 16.0 (or whatever is current in 2026)

Same logic as 15.0, more extreme. Rejected for the same reasons.

## Consequences

**Enabled:**
- Core Audio Process Taps are available unconditionally; no `@available` guards in the capture layer.
- SwiftUI's `MenuBarExtra` (introduced in macOS 13) and other modern UI APIs are available.
- Swift Concurrency is mature.
- Modern `AVAudioEngine` features are available.

**Precluded or constrained:**
- Users on macOS 14.0–14.3 cannot run the app. Estimated at scribing: this excludes a meaningful but minor fraction of the macOS user base by 2026.
- Users on macOS 13.x and earlier cannot run the app. Larger fraction, but the API constraint is binding.

**Risks:**
- The Core Audio Process Tap API may have behavioral differences across 14.4, 14.5, 14.6, 14.7, 15.0+, etc. The orchestrator tests on the user's current macOS during Phase 1 and notes any version-specific quirks in code comments. Mitigation: behavior tests catch regressions; the README documents the supported macOS range.
- A future macOS may deprecate or change the API. Mitigation: ADR-001 documents the fallback path (ScreenCaptureKit) if the tap API becomes untenable.

## Verification

The deployment target is declared in two places:

1. `Package.swift` (if SPM-managed): `platforms: [.macOS(.v14_4)]`.
2. The Xcode project's deployment target setting.

A test in `Tests/PlatformTests/` asserts that the runtime macOS version is `>= 14.4`; the test is informational (it should always pass on supported systems) but documents the assumption.

The README's "Requirements" section states the minimum version. CHANGELOG entries note macOS version changes.

## References

- `docs/decisions/ADR-001-capture-api.md` — the API that drives this version requirement.
- `docs/specs/capture.md` — known issues across macOS versions.
- Apple's `AudioHardwareCreateProcessTap` documentation page (the availability annotation confirms the 14.4 floor).
