# Phase 1 Verification

**Verifier**: Claude (verification subagent, cold context)
**Date**: 2026-05-21
**Phase**: 1 — Capture Spike
**Verdict**: FAIL

## Gate criteria assessment

### Criterion 1: The `CaptureController` exists with the public surface specified in 1.1.

**Status**: Met

**Evidence**: All types from the spec's 1.1 public surface are present in `Sources/Capture/`:

- `CaptureControllerProtocol` in `CaptureControllerProtocol.swift` — `state`, `statePublisher`, `availableSources()`, `start(source:into:)`, `stop()` match the spec exactly.
- `CaptureState` in `CaptureState.swift` — `idle`, `starting`, `running(source:)`, `stopping`, `failed(_:)` with correct associated values, `Equatable` and `Sendable` conformances.
- `CaptureSource` in `CaptureSource.swift` — `pid: pid_t`, `audioProcessID: AudioObjectID`, `bundleIdentifier: String?`, `displayName: String`, `id: pid_t` (via `Identifiable`), `Equatable`, `Sendable`.
- `CaptureError` in `CaptureError.swift` — all seven cases from the spec are present: `permissionDenied`, `sourceNotFound(pid_t)`, `tapCreationFailed(OSStatus)`, `aggregateDeviceCreationFailed(OSStatus)`, `engineConfigurationFailed(String)`, `unsupportedOSVersion`, `captureInterrupted(reason: String)`. The enum is `Equatable` and `Sendable`.
- `CaptureController: CaptureControllerProtocol` in `CaptureController.swift` — a `public final class`, uses `CurrentValueSubject` for the publisher, holds `audioProcessID`, `aggregateDeviceID` (via `ActiveCapture` struct), and a reference to the `AVAudioEngine`.

The concrete class signature and the protocol both match the spec. The `CoreAudioInterface` seam and `RealCoreAudioInterface` implementation are additional infrastructure, not part of the spec's public surface, but they are consistent with it.

---

### Criterion 2: A documented test of "start → 5 seconds passthrough → stop" runs successfully on the orchestrator's machine. The recorded output is committed to `test-artifacts/phase-1-passthrough.wav`. The orchestrator's transcript log is at `docs/audits/verification/phase-1-passthrough.md`. The verification subagent runs a level check against the wav (RMS over the 5-second window > -60 dBFS) to confirm non-silent audio is present.

**Status**: Not met

**Gap**: Neither artifact exists at the required paths:

- `test-artifacts/phase-1-passthrough.wav` — absent. The `test-artifacts/` directory exists (it contains `ear-test-input.wav` and `ear-test-output.wav` from other phase work) but no passthrough wav is present.
- `docs/audits/verification/phase-1-passthrough.md` — absent. The `docs/audits/verification/` directory exists but contains only `phase-0.md`, `phase-0-rerun-1.md`, and `phase-minus-1.md`.

Per the task brief, this is expected: the passthrough test requires an interactive system permission dialog and a real audio-producing source process. The orchestrator could not perform it autonomously. The recommendation is that the orchestrator either implement a `tap-n-filter-passthrough-test` CLI target (runnable by the user with a single command) and escalate the permission grant to the user, or formally document the deviation with a scope-change ADR, and that the user performs the test and the orchestrator commits the resulting artifacts.

The RMS level check cannot be performed — there is no wav file to analyze.

---

### Criterion 3: Permission denial is handled gracefully (does not crash, surfaces a clear error).

**Status**: Not met

**Gap**: There are two separable gaps.

**Gap 3a — OSStatus-to-`permissionDenied` mapping absent in `RealCoreAudioInterface`.** `FakeCoreAudioInterface` can inject `CaptureError.permissionDenied` directly, and `CaptureControllerTests.test_permission_denied_surfaces_typed_error` exercises that path. However, `RealCoreAudioInterface.createTap` throws `CaptureError.tapCreationFailed(status)` for all non-success `OSStatus` values from `AudioHardwareCreateProcessTap`. There is no code path in the real implementation that maps any `OSStatus` to `CaptureError.permissionDenied`. The mapping is unimplemented and tracked as open under U-008. This means that in production, a permission-denied condition would surface as `.tapCreationFailed(someOSStatus)` rather than `.permissionDenied`, violating the criterion's "surfaces a clear error" requirement. The PR description acknowledges: "Permission-denied OSStatus mapping is unverified pending a live test on the build machine."

**Gap 3b — Debug UI not updated.** The spec (task 1.4) requires the debug UI to: surface `CaptureState` in a status line; include "Start" and "Stop" buttons; and offer "a link to System Settings" when permission is denied. `Sources/tap-n-filter/App.swift` is unchanged from the Phase 0 shell — it still shows `ContentView` with only a static text placeholder ("Phase 0 shell — full UI lands in Phase 3."). The diff shows no changes to `App.swift`. There is no bundleID text field, no start/stop buttons, and no error-surfacing path in the UI.

Gap 3a is a strict-mode criterion gap — "does not crash" may still hold for the fake path, but "surfaces a clear error" requires that a user who denies permission sees `permissionDenied` rather than a raw tap-creation OSStatus. Gap 3b means the only path to drive the capture lifecycle manually (and observe the permission flow) was not implemented.

---

### Criterion 4: Unit tests pass (CI green).

**Status**: Met

**Evidence**: `gh pr checks 2 --repo loganrooks/tap-n-filter` returns:
```
Build and test    pass    37s    ...
Integration tests (manual)    skipping    0    ...
```

The "Integration tests (manual)" job is gated by `RUN_INTEGRATION_TESTS=1` and is expected to skip in CI.

---

### Criterion 5: CodeRabbit and Codex have reviewed the Phase 1 PR and any High-severity findings are addressed.

**Status**: Not met — accepted with documented escalation

**Evidence**: `gh api repos/loganrooks/tap-n-filter/issues/2/comments` returns `[]`. `gh api repos/loganrooks/tap-n-filter/pulls/2/reviews` returns `[]`. No CodeRabbit or Codex reviews are present on PR #2.

This is the same `github-apps-not-installed` escalation documented in `state.json` under `human_inputs.other_escalations`. The escalation resolution in state.json reads: "Documented deviation — apps were not installed when the bundle was scribed; the gate criteria assume an installed-apps environment. Continuing with CI-based gating only for this build." Per the task brief, this criterion is treated as Not met but accepted with the documented escalation. It does not on its own cause a FAIL if the other criteria are met.

---

### Criterion 6: The capture module references AudioCap in code comments and the README acknowledgments.

**Status**: Met

**Evidence**:

- `Sources/Capture/CoreAudioInterface.swift`, line 19: `/// established by [insidegui/AudioCap](https://github.com/insidegui/AudioCap),`
- `Sources/Capture/CoreAudioInterface.swift`, line 78–80: `/// in [insidegui/AudioCap](https://github.com/insidegui/AudioCap), notably: / the per-process tap, the aggregate-device wrapper, and the / kAudioOutputUnitProperty_CurrentDevice setter on inputNode's audio unit.`
- `README.md`, Acknowledgments section, line 98: `The capture layer is built on the API documented by [insidegui/AudioCap](https://github.com/insidegui/AudioCap), which remains the best public reference...`

All three references are present and meet the criterion.

---

### Criterion 7: `state.json` has phase `1` status `passed`.

**Status**: Not met

**Reason**: `state.json` currently records phase `1` status as `pending`. This is expected — the orchestrator updates `state.json` to `passed` only after a PASS verification. Criterion 7 is structurally deferred to the moment of PASS, so it is counted as not-yet-met rather than failed on the orchestrator's part.

---

## Framing audit-lite

**Question**: Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?

**Answer**:

The implementation introduces two departures from the spec, one minor and one consequential.

The minor departure: `availableSources()` queries `kAudioHardwarePropertyProcessObjectList` and then cross-references `NSWorkspace.shared.runningApplications`. The spec describes querying `NSRunningApplication.runningApplications` first, then filtering to `activationPolicy == .regular`, and then optionally filtering to apps with `kAudioProcessPropertyIsRunning`. The implementation inverts this — it starts with the HAL's list of audio-active processes and joins to running applications by PID. This is actually a sound inversion: the HAL-first approach returns only processes the HAL knows about (which is closer to "audio-active" than "regular activation policy"), and dropping processes without a bundle identifier achieves a similar filter to "regular activation policy." The result is arguably tighter than the spec's primary flow. It is a reasonable addition, not a problematic one, though the dissent log does not record this option-between-options choice.

The consequential departure: the OSStatus-to-`permissionDenied` mapping is deferred under U-008. The spec is explicit that "If the user denies, `CaptureError.permissionDenied` is thrown." The implementation declares `permissionDenied` in `CaptureError` and exercises it in unit tests via the fake, but `RealCoreAudioInterface.createTap` throws `tapCreationFailed(status)` for all non-zero statuses, including the one that represents denial. This is not an innocent assumption — the spec states the behavior and the implementation does not deliver it in the real path. The PR description acknowledges the gap and defers to U-008. The uncertainty is real (the OSStatus for denial is not publicly documented), but the correct handling is to either map a known status value or implement a permission-check ahead of the tap call and throw `permissionDenied` proactively. Leaving the mapping entirely absent means the criterion is unmet, not just unverified.

The debug UI omission is not a reasoning departure — it is simply a task left undone. The spec (task 1.4) describes the debug UI as in-scope for Phase 1; the implementation does not build it, without documentation of the deferral in the dissent log or an ADR. This is a gap in delivery rather than an assumption.

## Verdict reasoning

Criteria 1, 4, and 6 are met. Criteria 2, 3, and 7 are not met.

Criterion 7 is structurally pending and is not a failure of the orchestrator's work — it is resolved by this report's verdict. Criterion 5 is not met but carries an accepted documented escalation that does not itself cause FAIL.

Criteria 2 and 3 are the determinative failures. Criterion 2's absence (no passthrough wav, no passthrough transcript) means the central empirical claim of Phase 1 — that the tap-to-aggregate-device-to-engine bridge works on real hardware — is unverified. Criterion 3 has two gaps: the OSStatus-to-`permissionDenied` mapping is unimplemented in `RealCoreAudioInterface`, and the debug UI required to drive and observe the permission flow was not built. The permission gap is a strict-mode criterion per the verification protocol.

The verdict is **FAIL**. The core capture implementation is well-structured and the unit test coverage of the state machine is thorough. The FAIL is not about code quality; it is that the two criteria requiring real-hardware or real-system evidence are unmet, and the one criterion about user-visible error surfacing is unmet in the production code path.

The recommended path to a PASS re-run:
1. Implement the OSStatus-to-`permissionDenied` mapping in `RealCoreAudioInterface.createTap`, or add a pre-tap permission check that throws `permissionDenied` before calling `AudioHardwareCreateProcessTap`. Document the chosen OSStatus value (or the pre-check approach) in code comments and update U-008 with the observation.
2. Implement the debug UI (task 1.4): bundle-ID text field, start/stop buttons, status line showing `CaptureState`, error display with System Settings link on permission denial. This is the environment needed to perform the passthrough test.
3. With the debug UI in place, perform the passthrough test on the build machine, commit the resulting wav to `test-artifacts/phase-1-passthrough.wav`, and write `docs/audits/verification/phase-1-passthrough.md` recording the session. Escalate the permission grant step to the user if the interactive dialog cannot be handled autonomously.
4. Re-run verification (this report gets suffix `phase-1.md`; the re-run will be `phase-1-rerun-1.md`).
