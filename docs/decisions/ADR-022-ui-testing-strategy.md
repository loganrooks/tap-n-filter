# ADR-022: UI testing strategy after V0.1

## Status

Accepted. Extends ADR-011 (accessibility audit without XCUITest) and opens the
V0.2 path that ADR-015 anticipated for layout-regression coverage.

## Context

A layout regression shipped undetected: on macOS 27 the `MenuBarExtra(.window)`
panel collapsed and the effect list disappeared. The root cause was a
`ScrollView` constrained only by `maxHeight` inside a window that sizes itself to
the content's fitting height. Nothing floored the scroll region, so macOS 27's
fitting-size pass collapsed it to its minimum; macOS 26 had resolved it to a
usable height. Details are in `dissent-log.md` (2026-06-15) and PR #17.

Two existing ADRs had already named this exact gap as accepted risk:

- **ADR-011** deferred XCUITest under the SPM-only structure and noted that its
  replacement "does not exercise the actual menubar window lifecycle
  (`MenuBarExtra` is not instantiated)."
- **ADR-015** accepted the snapshot suite as an environment-bounded deviation and
  stated plainly: "Layout drift is not covered by any automated test in V0.1.0;
  it is a downstream risk the user encounters in interactive use."

The regression is that deferred risk materializing. This ADR closes it.

A research pass on 2026-06-15 (sources in References) established the constraints
that shape the decision:

- SwiftPM still cannot host an XCUITest target natively. XCUITest needs a host
  `.app` plus a UI-test bundle driven by `xcodebuild test`, which needs an Xcode
  project (generated or checked in).
- GitHub-hosted runners offer `macos-14`, `macos-15`, and `macos-26` only. A
  macOS major version reaches the runner fleet roughly five to six months after
  public release, and there is no `macos-27` image. CI therefore cannot catch a
  macOS-27-day-one regression.
- ViewInspector inspects the SwiftUI logical tree but exposes no geometry, so it
  cannot detect a layout collapse. swift-snapshot-testing can, if snapshots
  render at real size, at the cost of a new top-level dependency and per-OS
  baseline maintenance.
- XCUITest against a `MenuBarExtra` status item is the highest-fragility surface:
  an agent app's status bar is not always hittable, the workaround queries
  `com.apple.systemuiserver`, and SwiftUI menu accessibility identifiers are
  frequently dropped. The proven mitigation is to factor the panel content into a
  plain view that can also be hosted in a normal window for the bulk of
  assertions.

## Decision

Adopt a layered UI-testing strategy, ordered cheapest-and-most-leveraged first.
The primary defense is deterministic layout; the tests are regression guards
around it.

1. **Deterministic layout (primary).** The panel must not depend on the OS
   window-fitting heuristic that diverged between macOS 26 and 27. Step one is the
   `minHeight` floors on the chain `ScrollView` and the root panel (PR #17). The
   follow-up is to compute the panel height from state rather than leaving it to
   the fitting-size pass, so the rendered layout is identical across OS versions.
   A layout that cannot diverge is worth more than a test that detects divergence
   after the fact.

2. **Layout-contract tests, no new dependency (CI floor guard).** A test hosts
   `ControlPanelView` in an `NSHostingView`, constrains width to 380, and asserts
   the measured height stays within contract (at or above the floor, at or below
   the cap) for empty and populated chains. This supersedes ADR-015's "layout
   drift is not covered" gap. It runs under `swift test` with first-party APIs
   only. Caveat: it catches a collapse only on the macOS version it runs on, so on
   CI (macOS 26 and below) it guards the supported floor, not macOS-27-specific
   behavior.

3. **Real-size snapshot rendering.** Fix `SnapshotHelper` to render at the view's
   intrinsic height instead of a forced fixed size, so any future committed
   baselines exercise vertical layout. Whether to adopt swift-snapshot-testing —
   which handles diffing and per-OS baselines properly — is deferred to its own
   ADR, because it is a new top-level dependency with a per-OS baseline-maintenance
   cost.

4. **One XCUITest smoke lane (end-to-end).** Stand up a generated Xcode project
   (XcodeGen from a checked-in spec, or a minimal checked-in `.xcodeproj`) hosting
   a thin runner app plus a UI-test bundle, run via `xcodebuild test` in a
   dedicated CI lane. Keep the status-item interaction to a single thin smoke
   test; factor the panel content into a view hostable in a normal window and
   drive that for the substantive assertions. This revises ADR-011's "no
   `.xcodeproj`" stance: the V0.1 deferral was correct, but the regression shows
   the end-to-end gap is now worth the project-generation cost. Scoped to M1/M2 in
   the roadmap.

5. **CI matrix, best-effort.** Add `macos-15` (and the newest available image as
   GitHub ships it) alongside `macos-14`. Pin labels explicitly; never trust
   `macos-latest`. This guards the supported floor, not the bleeding edge.

6. **Local pre-merge verification on the dev OS (mandatory bleeding-edge guard).**
   Because no CI runner tracks the newest macOS, a manual pre-merge check on the
   maintainer's macOS-27 machine — open the menu, confirm the effect list renders
   and scrolls — is the only guard for day-one-of-new-OS regressions. A
   self-hosted macOS-27 runner is the optional automation of this. The standing
   gate is recorded in `../governance/review-tiers.md` for any PR touching UI
   layout.

## Alternatives considered

- **CI matrix alone.** Rejected as sufficient: no `macos-27` runner exists or
  will for months, so it cannot catch the class of bug that motivated this ADR.
- **ViewInspector for layout assertions.** Rejected: no geometry API, so it
  cannot detect a collapse. It addresses a different (logic) gap.
- **swift-snapshot-testing now.** Deferred: a new top-level dependency needs its
  own ADR, and per-OS baseline maintenance is a real cost. The no-dependency
  `NSHostingView` contract test covers the immediate need.
- **Full XCUITest against the real status item only.** Rejected as the primary
  surface: highest fragility per the research. Kept as a thin smoke test behind
  the window-hostable-view pattern.
- **Keep deferring (the status quo of ADR-015).** Rejected: the deferred risk has
  materialized in a user-visible regression.

## Consequences

Enabled: a regression guard for the exact failure that shipped; an honest,
documented account of what CI can and cannot catch; a path to end-to-end UI
coverage.

Constrained: an XCUITest lane reintroduces a generated or checked-in Xcode
project, partially walking back ADR-009's SPM-only purity. The walk-back is
bounded to test infrastructure, with `Package.swift` remaining the source of
truth for library code. swift-snapshot-testing stays gated behind a future ADR.

Risks: per-OS rendering differences make any pixel-baseline approach noisy; the
contract tests use measured geometry to avoid that. The manual macOS-27 gate
depends on maintainer discipline until a self-hosted runner exists.

## References

- PR #17 (the layout fix); `dissent-log.md` (2026-06-15).
- ADR-009 (SPM-only project structure), ADR-011 (accessibility audit without
  XCUITest), ADR-015 (snapshot baseline environment deviation).
- `../roadmap/roadmap.md` (epic E1), `../governance/review-tiers.md` (standing UI
  gate).
- Research 2026-06-15: `actions/runner-images` available-images table (no
  `macos-27`); Swift Forums "How do you UI test a Swift package?"; Apple Developer
  forum thread 773715 (status bar not hittable under XCUITest); ViewInspector and
  pointfreeco/swift-snapshot-testing READMEs.
