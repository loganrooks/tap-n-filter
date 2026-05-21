# ADR-015: Phase 3 snapshot-test baselines accepted as environment-bounded deviation

## Status

Accepted

## Context

Phase 3's gate (`docs/orchestration/phases/03-ui-control.md` section 3.9, gate criterion 3) calls for SwiftUI snapshot tests on `ControlPanelView` in three states: idle, running, failed. The test target exists at `Tests/UISnapshotTests/ControlPanelViewSnapshotTests.swift` and uses a hand-rolled `SnapshotHelper` that renders through `ImageRenderer` and compares against PNG baselines under `Tests/UISnapshotTests/__Snapshots__/`.

No PNG baselines exist in the repository. The directory contains only `README.md`. Three constraints produce this state:

1. **The dev environment cannot run `swift test`.** Only Command Line Tools are installed on the build host; the full Xcode toolchain (which provides the `XCTest` module the snapshot target imports) is not. This is the same environmental constraint codified in ADR-010 and ADR-009 and surfaced in the Phase 1 / Phase 2 verification reports.

2. **CI runners differ enough in font rendering and color profile that a baseline captured on one runner is not byte-equal to a render on another.** Apple's macOS image releases on GitHub Actions change underlying CoreText behavior (font hinting tweaks, default sub-pixel rendering) often enough that pinning to `macos-latest` produces fragile baselines. This is uncertainty entry U-007's broader concern and the reason `SnapshotHelper`'s comparison is documented as "macOS-version drift will produce false negatives — the baselines are pinned to whatever runner first produces them."

3. **The round-1 Codex P1 finding correctly flagged that the original `write-on-missing` helper behaviour meant CI silently passed without asserting anything.** Round 2 changed the helper to `XCTSkip` on missing baseline so CI output is honest about "no assertion" rather than fake-passing. Codex's round-3 P1 reiterates that `XCTSkip` is still not enforcement — which is true, and what this ADR addresses.

The Phase 3 verifier (`docs/audits/verification/phase-3.md` criterion 3) flagged criterion 3 as Not met because skipped tests are not passing tests, and explicitly invoked the ADR-010 precedent: "if the orchestrator believes this should be treated as an env-bounded deviation analogous to ADR-010, that needs to be promoted from a U-log entry to an ADR before the verification subagent rules on it."

## Decision

Accept Phase 3 gate criterion 3 ("snapshot tests pass") as an environment-bounded deviation, with the following dispositions:

1. **`SnapshotHelper` defaults to strict mode.** Missing baseline → `XCTSkip` with regen instructions. The skip surfaces in CI as a skipped test, not a passed test, so the gap is honest in CI logs. Drift detection (mismatched baseline) still fails the test loudly with an `*-actual.png` written for inspection.

2. **Baselines are generated locally with `TNF_SNAPSHOT_REGEN=1` and committed by a maintainer.** The opt-in env var preserves the legacy write-on-missing behaviour for the one-time generation step. The dev environment cannot perform this step; the user can run `TNF_SNAPSHOT_REGEN=1 swift test --filter UISnapshotTests` on a machine with full Xcode and commit the three PNGs in a follow-up PR. The follow-up does not need to clear Phase 3 — it can land independently.

3. **The deviation does not block Phase 3 PASS.** The verification report cites this ADR for the criterion-3 disposition. `state.json`'s phase 3 → `passed` transition is gated on the verification subagent's overall PASS, not on the snapshot suite asserting anything.

4. **The failure modes the snapshot tests would catch — layout drift, spacing changes, accessibility-modifier omissions that surface as missing labels in the rendered tree — are partially covered by other tests.** `Tests/AccessibilityTreeTests/AccessibilityTreeTests.swift` validates `accessibilityLabel` / `accessibilityValue` literal discipline and the committed `phase-3-accessibility-tree.json` artifact (per ADR-011). Layout drift is not covered by any automated test in V0.1.0; it is a downstream risk the user encounters in interactive use, addressed by the manual VoiceOver pass and the smoke-test in the PR test plan.

## Considered

- **Generate baselines via a dedicated CI workflow and commit them via an automated PR.** The clean long-term answer. Rejected for V0.1.0 because building a `record-snapshots` workflow, pinning a runner image, and validating cross-run determinism is a multi-hour task that doesn't ship Phase 3 sooner. U-009's resolution path explicitly defers this to V0.2.

- **Generate baselines on the maintainer's machine right now and commit them.** Plausible. Possible to do if a maintainer has full Xcode locally. The orchestrator cannot perform this step (no XCTest module). If a maintainer does this before merging Phase 3, the snapshot tests upgrade from `XCTSkip` to passing, and this ADR could be revised to "Superseded" without any other code change. The ADR is written to accommodate that outcome without re-opening the verification.

- **Drop the snapshot tests entirely.** Rejected. The harness is in place, the cost to keep it is near zero, and once baselines exist (V0.2 at latest) the assertion becomes useful. Deleting it now would mean re-introducing the same infrastructure in V0.2.

- **Treat the deviation as a Critical failure and FAIL Phase 3.** Rejected. The verifier's framing-audit-lite explicitly identified two acceptable resolutions; an ADR mirroring ADR-010 is one of them. The risks the snapshot tests would catch are partially covered by `AccessibilityTreeTests` (structural completeness) and by the manual VoiceOver pass (qualitative); the residual risk (layout drift) is a deferrable V0.2 concern.

- **Promote U-009 to U-009-resolved without an ADR.** Rejected. The verifier explicitly called this out as the unsound substitution: U-009 records intent to defer, not an accepted deviation. ADR is the correct artifact per the project's decision-logging discipline (`CLAUDE.md` §"Decision logging").

## Consequences

- Phase 3's verification report (current rerun) points to this ADR for criterion 3.
- `Tests/UISnapshotTests/SnapshotHelper.swift` defaults to strict mode; the `TNF_SNAPSHOT_REGEN=1` opt-in is documented in the helper's doc-comment and here.
- `__Snapshots__/README.md` should be updated to reference this ADR and the `TNF_SNAPSHOT_REGEN=1` workflow so future maintainers know the one-time generation step.
- The U-009 entry in `docs/decisions/uncertainty-log.md` should be marked closed by this ADR.
- V0.2 work that ships PR-time snapshot enforcement (per U-009's resolution path: dedicated `record-snapshots` workflow + automated baseline PR) supersedes this ADR. When that lands, this ADR moves to "Superseded".
- Phase 4 release-prep should not pretend the snapshot tests are passing; the release-notes should mention the limitation as a known gap for V0.1.0.
