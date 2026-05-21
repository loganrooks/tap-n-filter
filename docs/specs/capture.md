# Capture

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

```swift
private func createTap(for pid: pid_t) throws -> AudioObjectID {
    let description = CATapDescription(stereoMixdownOfProcesses: [pid])
    description.uuid = UUID()
    description.name = "tap-n-filter.tap.\(pid)" as CFString
    description.privateTap = true
    description.isExclusive = false
    
    var tapID: AudioObjectID = 0
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr else {
        throw CaptureError.tapCreationFailed(status)
    }
    return tapID
}
```

`stereoMixdownOfProcesses:` is the constructor pattern AudioCap uses; it produces a 2-channel mixdown of the source process's output. For tap-n-filter's V1 stereo-only model, this is the right choice.

### Aggregate device creation

The tap on its own is not directly readable by `AVAudioEngine`. We create an aggregate device that contains the tap as one of its sub-streams:

```swift
private func createAggregateDevice(containing tapID: AudioObjectID,
                                    forSource source: CaptureSource) throws -> AudioDeviceID {
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey as String: "tap-n-filter.aggregate.\(source.pid)",
        kAudioAggregateDeviceNameKey as String: "tap-n-filter for \(source.displayName)",
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceIsStackedKey as String: false,
        kAudioAggregateDeviceTapListKey as String: [
            [
                kAudioSubTapDriftCompensationKey as String: false,
                kAudioSubTapUIDKey as String: tapID.uid
            ]
        ]
    ]
    
    var deviceID: AudioDeviceID = 0
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
    guard status == noErr else {
        throw CaptureError.aggregateDeviceCreationFailed(status)
    }
    return deviceID
}
```

This is the central trick. The aggregate device is read by `AVAudioEngine` as if it were a normal input device, while internally it reads from the process tap.

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

The exact path in System Settings as of macOS 14.4 is **Privacy & Security → Microphone**. (This conflates the audio capture permission with microphone access in the UI even though they are technically separate. Apple's UI organization here may change in future macOS versions; the orchestrator verifies during implementation and updates the user-facing text accordingly.)

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
