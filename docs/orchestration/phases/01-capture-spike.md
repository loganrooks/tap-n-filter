# Phase 1: Capture Spike

Get audio from a single chosen application captured via a Core Audio process tap, routed through `AVAudioEngine`, and played back to the default output device. No effects yet — passthrough only. This phase exists to retire the highest-uncertainty technical work before adding DSP complexity on top of it.

## Scope

In:
- A `CaptureController` module that, given a process identifier or bundle identifier, creates a Core Audio process tap targeting that process.
- Bridging from the tap into an `AVAudioEngine` input node via the aggregate-device pattern documented in [insidegui/AudioCap](https://github.com/insidegui/AudioCap).
- `AVAudioEngine` configured for pass-through: input → mainMixerNode → output.
- A trivial debug UI (a single text field for bundle ID, "start" and "stop" buttons in the menubar dropdown).
- Permission handling: prompt user for audio capture permission on first start, gracefully handle denial.
- Unit tests for the capture lifecycle (start, stop, error paths) using mock audio devices where possible.

Out:
- Any DSP effects (Phase 2).
- Source picker UI beyond a text field (Phase 3).
- Multi-source capture (deferred; V1 captures one source at a time).
- Recovery from device-change events mid-capture (deferred — log and stop is acceptable for V1).

## Reference implementation

The orchestrator MUST read [insidegui/AudioCap](https://github.com/insidegui/AudioCap) before writing capture code. That repo is the canonical public reference for the Core Audio process tap API, intentionally written because the official documentation is sparse. The capture module in tap-n-filter should follow AudioCap's overall structure with credit in code comments and in the README's acknowledgments.

Specifically, the orchestrator should understand from AudioCap:
- How `CATapDescription` is configured for per-process capture.
- How `AudioHardwareCreateProcessTap` is invoked and what its result objects represent.
- How an aggregate device is created that contains the tap, and how an `AVAudioEngine` input node is connected to that device.
- How permission is requested via `NSAudioCaptureUsageDescription` and what failure modes the permission flow has.

The orchestrator does not copy AudioCap's code verbatim. It writes tap-n-filter's own implementation, informed by AudioCap's example, with structure adapted to tap-n-filter's `EffectNode` graph model (see `docs/specs/effect-node-protocol.md`).

## Architecture

```
   Source app (Safari, Music, etc.)
            │
            │ audio output (intercepted)
            ▼
   ┌──────────────────────────┐
   │  Process Tap             │
   │  (CATapDescription,      │
   │   AudioHardwareCreate-   │
   │   ProcessTap)            │
   └──────────────┬───────────┘
                  │
                  ▼
   ┌──────────────────────────┐
   │  Aggregate device        │
   │  containing the tap as   │
   │  an input stream         │
   └──────────────┬───────────┘
                  │
                  ▼
   ┌──────────────────────────┐
   │  AVAudioEngine           │
   │  inputNode (reading from │
   │  the aggregate device)   │
   └──────────────┬───────────┘
                  │
                  ▼
            mainMixerNode
                  │
                  ▼
       outputNode (default speakers)
```

For Phase 1 the chain is bare: `inputNode → mainMixerNode → outputNode`. Phase 2 inserts the effect graph between input and mixer.

## Tasks

### 1.1 Implement `CaptureController`

A class (Swift `final class`) that owns:
- The current process tap (`AudioObjectID`).
- The aggregate device wrapping the tap (`AudioDeviceID`).
- A reference to the `AVAudioEngine` it's feeding (engine itself lives elsewhere).

Public surface:

```swift
public protocol CaptureControllerProtocol: AnyObject {
    var state: CaptureState { get }
    var statePublisher: AnyPublisher<CaptureState, Never> { get }

    func availableSources() throws -> [CaptureSource]
    func start(source: CaptureSource, into engine: AVAudioEngine) throws
    func stop() throws
}

public enum CaptureState: Equatable {
    case idle
    case starting
    case running(source: CaptureSource)
    case stopping
    case failed(CaptureError)
}

public struct CaptureSource: Equatable, Identifiable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let displayName: String
    public var id: pid_t { pid }
}

public enum CaptureError: Error, Equatable {
    case permissionDenied
    case sourceNotFound(pid_t)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case engineConfigurationFailed(String)
    case unsupportedOSVersion
}
```

### 1.2 Implement the bridge to `AVAudioEngine`

`CaptureController.start` configures the aggregate device, then prepares the `AVAudioEngine` by setting its input node's audio unit to read from the aggregate device. This involves CoreAudio HAL property setters that AudioCap demonstrates.

After configuration, the engine's input node is connected to `mainMixerNode` with the format matching the aggregate device's output format. The engine is then started.

### 1.3 Permission handling

The first call to `availableSources()` or `start()` triggers the audio capture permission prompt. If the user denies, `CaptureError.permissionDenied` is thrown. The debug UI should surface this clearly and offer a link to System Settings → Privacy & Security → Microphone (or wherever the audio capture permission is shown in macOS 14.4 — the orchestrator should verify the exact location).

### 1.4 Debug UI

In `MenuBarExtra`, a simple `VStack`:
- Text field for bundle ID (default: `com.apple.Safari`).
- "Start" button (disabled while running).
- "Stop" button (disabled while idle).
- A status line showing current `CaptureState`.

No source picker dropdown yet. No effect controls yet. This is just enough UI to drive the capture lifecycle manually.

### 1.5 Tests

Unit tests under `Tests/CaptureTests/`. The Core Audio APIs are hard to mock cleanly, so the test strategy is:
- Unit-test the `CaptureController`'s state machine using a protocol-based seam: inject a `CoreAudioInterface` protocol that wraps `AudioHardwareCreateProcessTap`, etc. The real implementation calls the real API; tests use a fake.
- Integration tests live in a separate target that actually invokes Core Audio. These require a real macOS environment and are gated behind a `RUN_INTEGRATION_TESTS=1` env var to keep CI fast.
- Test that `start()` followed by `stop()` followed by `start()` again returns to a working state (no lingering aggregate devices).
- Test that `stop()` on an idle controller is a no-op (does not throw).
- Test that permission denial surfaces as `.permissionDenied`, not as an opaque `OSStatus`.

## Gate criteria

Phase 1 PASSES when the verification subagent confirms all of the following:

1. The `CaptureController` exists with the public surface specified in 1.1.
2. A documented test of "start → 5 seconds passthrough → stop" runs successfully on the orchestrator's machine, recorded in `docs/audits/verification/phase-1-passthrough.md` as a transcript log (the orchestrator can verify by running the app via the integration test, capturing the engine's output to a file, and confirming non-silent audio is present).
3. Permission denial is handled gracefully (does not crash, surfaces a clear error).
4. Unit tests pass (CI green).
5. CodeRabbit and Codex have reviewed the Phase 1 PR and any High-severity findings are addressed.
6. The capture module references AudioCap in code comments and the README acknowledgments.
7. `state.json` has phase `1` status `passed`.

## Failure modes

- **AudioCap's pattern doesn't directly map.** Apple's API has subtle behaviors that may have changed since AudioCap's last update. If the orchestrator hits a wall on the bridge from tap to AVAudioEngine, the alternative is to skip AVAudioEngine and use a raw `AudioDeviceIOProcID` callback that feeds a ring buffer, with AVAudioEngine reading from that buffer via a manual input tap. This is more code but avoids the aggregate-device complexity. ADR-001 documents the default choice and the fallback.
- **Permission flow inconsistent across macOS minor versions.** macOS 14.4 introduced the audio capture permission; 14.5 and later may have changed UI or location. The orchestrator tests on the current macOS version (whatever the user is running) and documents observed behavior in code comments.
- **Audio device disappears mid-capture (AirPods disconnect, etc.).** Acceptable V1 behavior: stop the engine, transition to `.failed`, surface the error in the UI. V2 can add reconnection logic.

## Outputs

- `CaptureController` and supporting types in `Sources/Capture/`.
- Tests in `Tests/CaptureTests/`.
- Integration test target in `Tests/CaptureIntegrationTests/`.
- A passing PR titled `phase-1: capture spike`.
- An ADR (`ADR-006-capture-bridge-approach.md` or similar) documenting the chosen bridging strategy.
- `state.json` updated.
