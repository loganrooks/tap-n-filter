# Capture

> **Status: superseded for V0.1 by [`capture-v2.md`](capture-v2.md).**
>
> This document specifies the V1 capture architecture that Phase 1 originally
> implemented: bind a tap-wrapping aggregate device to
> `AVAudioEngine.inputNode` via `kAudioOutputUnitProperty_CurrentDevice`. On
> macOS 26.3 that pattern is structurally broken (the engine uses a unified
> IO AU; setting `CurrentDevice` for input also sets it for output, and the
> tap aggregate has no output streams). See
> `docs/investigations/2026-05-audio-pipeline.md` for the diagnosis and
> [ADR-018](../decisions/ADR-018-direct-ioproc-capture-architecture.md) for
> the architectural shift to direct IOProc + `AVAudioSourceNode`.
>
> This document is retained as historical context for Phase 1's
> implementation. New work should follow `capture-v2.md`.

This document specifies the capture layer: how tap-n-filter intercepts audio from a chosen application and delivers it to the audio engine for processing.

## Approach

V1 uses the Core Audio process tap API introduced in macOS 14.4 (`AudioHardwareCreateProcessTap` with `CATapDescription`). This is Apple's officially recommended path for per-process audio capture when video is not also being captured.

The decision is recorded in `docs/decisions/ADR-001-capture-api.md`. The key rationale, in brief:

- Apple's own forum guidance: for audio-only capture, prefer Core Audio taps to ScreenCaptureKit.
- No screen-recording permission prompt, no "this app accessed your screen" notifications.
- Lower overhead — no video pipeline machinery.
- Direct path into the existing Core Audio HAL.

The reference implementation we anchor on is [insidegui/AudioCap](https://github.com/insidegui/AudioCap). The orchestrator reads that repo during Phase 1 before writing capture code.

## Lifecycle

```
   idle ──start()──> starting ──>  running ──stop()──> stopping ──> idle
                          │                                              
                          └──── (error) ──> failed ──reset()──> idle
```

States:
- **idle** — no tap, no aggregate device, engine not configured for capture input.
- **starting** — tap and aggregate device being created.
- **running** — audio flowing from source through tap through engine to output.
- **stopping** — tearing down tap and aggregate device.
- **failed** — error during setup or runtime. Held until `stop()` resets to idle.

Transitions are published as Combine `AnyPublisher<CaptureState, Never>` so the view model can observe.

## Public surface

```swift
public protocol CaptureControllerProtocol: AnyObject {
    var state: CaptureState { get }
    var statePublisher: AnyPublisher<CaptureState, Never> { get }
    
    /// List applications currently producing audio that can be captured.
    func availableSources() throws -> [CaptureSource]
    
    /// Begin capturing from the given source, routing into the provided engine.
    /// The engine's input node will be reconfigured to read from the tap's
    /// aggregate device.
    func start(source: CaptureSource, into engine: AVAudioEngine) throws
    
    /// Stop the current capture. Releases the tap and aggregate device.
    func stop() throws
}
```

The orchestrator implements a concrete `CaptureController: CaptureControllerProtocol` using the protocol-based seam to enable mocking in tests.

## Internals

### Process tap creation

The Core Audio Process Tap API takes `AudioObjectID`s representing audio process objects, not raw `pid_t`s. The translation from a `pid_t` to the corresponding audio-process `AudioObjectID` is a HAL property lookup against the system object, using `kAudioHardwarePropertyTranslatePIDToProcessObject`. AudioCap performs this translation explicitly; tap-n-filter follows the same pattern.

```swift
/// Translates a Unix process identifier to the AudioObjectID representing
/// that process in the Core Audio HAL. Throws if the process is not known
/// to Core Audio (e.g., it is not producing audio).
private func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID {
    var pidCopy = pid
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var processID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &pidCopy,
        &size,
        &processID
    )
    guard status == noErr, processID != kAudioObjectUnknown else {
        throw CaptureError.sourceNotFound(pid)
    }
    return processID
}

/// Creates a Core Audio process tap for the given audio-process AudioObjectID.
///
/// The caller is responsible for translating from a `pid_t` to an
/// AudioObjectID via `audioProcessID(forPID:)` before calling this.
private func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID {
    let description = CATapDescription(stereoMixdownOfProcesses: [audioProcessID])
    description.uuid = UUID()
    description.name = "tap-n-filter.tap.\(audioProcessID)" as CFString
    description.isPrivate = true
    description.isExclusive = false

    var tapID: AudioObjectID = kAudioObjectUnknown
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr else {
        throw CaptureError.tapCreationFailed(status)
    }
    return tapID
}
```

`stereoMixdownOfProcesses:` is the constructor AudioCap uses; it produces a 2-channel mixdown of the source process's output. For tap-n-filter's V1 stereo-only model this is the right choice. Note that `CATapDescription`'s property is `isPrivate` (not `privateTap`); verify against the AudioCap source at implementation time.

### Aggregate device creation

The tap on its own is not directly readable by `AVAudioEngine`. We create an aggregate device that contains the tap as one of its sub-streams. The tap's UID is a CFString fetched from the tap object via `kAudioTapPropertyUID` — there is no `.uid` property on `AudioObjectID`, which is a typealias for `UInt32`.

```swift
/// Reads the UID (a CFString) of a Core Audio tap object.
private func tapUID(for tapID: AudioObjectID) throws -> CFString {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

    let status = AudioObjectGetPropertyData(
        tapID,
        &address,
        0,
        nil,
        &size,
        &uid
    )
    guard status == noErr, let uid else {
        throw CaptureError.tapCreationFailed(status)
    }
    return uid.takeRetainedValue()
}

private func createAggregateDevice(containing tapID: AudioObjectID,
                                    forSource source: CaptureSource) throws -> AudioDeviceID {
    let uid = try tapUID(for: tapID)
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey as String: "tap-n-filter.aggregate.\(source.pid)",
        kAudioAggregateDeviceNameKey as String: "tap-n-filter for \(source.displayName)",
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceIsStackedKey as String: false,
        kAudioAggregateDeviceTapListKey as String: [
            [
                kAudioSubTapDriftCompensationKey as String: false,
                kAudioSubTapUIDKey as String: uid
            ]
        ]
    ]

    var deviceID: AudioDeviceID = kAudioObjectUnknown
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
    guard status == noErr else {
        throw CaptureError.aggregateDeviceCreationFailed(status)
    }
    return deviceID
}
```

This is the central trick: the aggregate device is read by `AVAudioEngine` as if it were a normal input device, while internally it reads from the process tap. The exact property selectors and key names must be verified against AudioCap's source at implementation time; the API is sparsely documented and the strings above are written from the Apple-Framework reference rather than from a running build.

### Bridging to `AVAudioEngine`

`AVAudioEngine` exposes its input via the `inputNode` property. By default `inputNode` reads from the system default input device. To redirect it to read from our aggregate device, we set the underlying audio unit's `kAudioOutputUnitProperty_CurrentDevice` property:

```swift
private func configureEngineInput(_ engine: AVAudioEngine,
                                   toReadFrom device: AudioDeviceID) throws {
    let inputUnit = engine.inputNode.audioUnit!
    var deviceID = device
    let status = AudioUnitSetProperty(
        inputUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        throw CaptureError.engineConfigurationFailed("Failed to set input device: \(status)")
    }
}
```

After this, `engine.inputNode` reads from our aggregate device, which reads from the process tap.

### Permission handling

The first call to `AudioHardwareCreateProcessTap` triggers the audio capture permission prompt. The text in the prompt comes from `Info.plist`'s `NSAudioCaptureUsageDescription`.

If the user denies, subsequent calls return an error. The orchestrator detects this and throws `CaptureError.permissionDenied`. The UI surfaces the error with a link to System Settings.

The exact path in System Settings for the audio capture permission must be verified against the orchestrator's current macOS version before being included in user-facing text. The relevant pane in macOS 14.4+ is reported by Apple Developer Forum threads to be a distinct "Audio Capture" or "Audio recording" pane separate from "Microphone," though Apple's terminology has shifted across minor releases. The orchestrator runs the app once on the build machine, confirms which pane controls the permission, and updates any user-facing text and any deep-link URL (e.g., `x-apple.systempreferences:com.apple.preference.security?Privacy_<PaneIdentifier>`) to match. This verification step is recorded in `docs/audits/verification/phase-1.md`.

Until the verification step is performed in Phase 1, user-facing text refers generically to "the audio capture permission in System Settings → Privacy & Security" without naming a specific sub-pane. Uncertainty entry U-008 tracks the verification.

### Enumeration of sources

`availableSources()` returns running applications whose audio is capturable. Implementation:

1. List `NSRunningApplication.runningApplications`.
2. Filter to `activationPolicy == .regular` (excludes background-only apps and helpers).
3. Map each to a `CaptureSource`.
4. Optionally filter further to applications with active audio output (via `kAudioProcessPropertyIsRunning` on process objects, if discoverable).

For V1, step 4 is optional — showing all regular apps is acceptable even if some aren't actually producing audio. The UI can show all and let the user pick.

## Error model

```swift
public enum CaptureError: Error, Equatable {
    /// User denied audio capture permission.
    case permissionDenied
    
    /// The target process no longer exists or is not capturable.
    case sourceNotFound(pid_t)
    
    /// AudioHardwareCreateProcessTap returned non-success.
    case tapCreationFailed(OSStatus)
    
    /// AudioHardwareCreateAggregateDevice returned non-success.
    case aggregateDeviceCreationFailed(OSStatus)
    
    /// Engine configuration failed (most often a HAL property setter).
    case engineConfigurationFailed(String)
    
    /// Running on macOS earlier than 14.4.
    case unsupportedOSVersion
    
    /// The capture stopped unexpectedly (e.g., source app quit).
    case captureInterrupted(reason: String)
}
```

The UI maps each case to a user-friendly message.

## Cleanup

When `stop()` is called or the controller is deinit'd:

1. The engine input node is reset to the default input device.
2. The aggregate device is destroyed via `AudioHardwareDestroyAggregateDevice`.
3. The process tap is destroyed via `AudioHardwareDestroyProcessTap`.
4. The state transitions to `idle`.

Failure to clean up leaves orphaned aggregate devices in the system, which can appear in macOS's Audio MIDI Setup utility. The orchestrator ensures all `start()` paths have corresponding cleanup in `defer` blocks or via a structured teardown method.

## Known issues

- **Level attenuation on multi-pair output devices.** When the user's output device exposes more than 2 stereo output pairs (rare on a MacBook Air, common on professional interfaces like the RME Fireface), the tap produces audio attenuated by approximately `20 * log10(N_pairs)` dB. The orchestrator documents this in code comments and adds an output gain compensation hook in the architecture, but does not enable compensation by default in V1. See the Apple Developer forum thread referenced in the uncertainty log.

- **Tap stops when source process quits.** Expected behavior, surfaced as `.captureInterrupted`. The UI offers a "select another source" path.

- **Device-change events during capture.** If the user changes their default output device while a capture is running, the engine may need to be restarted. V1 handles this by stopping the capture and surfacing the state change; V2 may add transparent re-routing.

## Testing

- Unit-test the state machine via a `CoreAudioInterface` protocol that wraps the C-level APIs. The real implementation calls real APIs; tests use a fake.
- Integration tests under `Tests/CaptureIntegrationTests/` gated by `RUN_INTEGRATION_TESTS=1` env var. These actually create taps and aggregate devices. They are slow and machine-dependent.
- A passthrough verification test: start capture on a known-good audio-producing app (e.g., a small Python script playing a sine wave), record the engine's output to a file, verify the recorded audio matches the source within tolerance.
