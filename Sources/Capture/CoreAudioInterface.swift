import AVFoundation
import CoreAudio
import Darwin

/// A protocol-based seam over the C-level Core Audio HAL functions that the
/// capture layer needs.
///
/// Two reasons this exists:
///
/// 1. The HAL functions are global C functions and difficult to mock at the
///    call site. Wrapping them in a protocol lets `CaptureController`'s state
///    machine be exercised against a `FakeCoreAudioInterface` in unit tests
///    without touching the real HAL.
/// 2. Each method is the smallest meaningful unit of failure for the state
///    machine. The controller can detect "tap created but aggregate device
///    failed" and unwind exactly the right resources.
///
/// The real implementation, `RealCoreAudioInterface`, follows the patterns
/// established by [insidegui/AudioCap](https://github.com/insidegui/AudioCap),
/// which is Apple's de-facto reference for these APIs given the sparse
/// official documentation. See `docs/decisions/ADR-001-capture-api.md`.
public protocol CoreAudioInterface {
    /// Resolves a Unix `pid_t` to the Core Audio HAL's `AudioObjectID` for
    /// that process. Throws `CaptureError.sourceNotFound` if the HAL does not
    /// know about the process (typically because it isn't producing audio).
    func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID

    /// Reads the CFString UID of a tap object. Tap UIDs are required when
    /// constructing the aggregate-device description dictionary.
    func tapUID(for tapID: AudioObjectID) throws -> CFString

    /// Creates a stereo-mixdown process tap for the given audio-process
    /// object. The caller owns the returned tap and must destroy it via
    /// `destroyTap`.
    func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID

    /// Creates an aggregate device that wraps `tapID` as a sub-tap. The
    /// resulting device is the bridge that `AVAudioEngine` can read from.
    /// `uid` is the tap's UID (from `tapUID(for:)`); `sourcePID` and
    /// `displayName` are used only to build a unique, human-recognisable
    /// device UID and name string.
    func createAggregateDevice(
        containing tapID: AudioObjectID,
        uid: CFString,
        sourcePID: pid_t,
        displayName: String
    ) throws -> AudioDeviceID

    /// Destroys an aggregate device previously created by
    /// `createAggregateDevice`. Failure is propagated so callers can log; the
    /// HAL leaks a device entry if this is skipped.
    func destroyAggregateDevice(_ deviceID: AudioDeviceID) throws

    /// Destroys a tap previously created by `createTap`.
    func destroyTap(_ tapID: AudioObjectID) throws

    /// Enumerates every audio-active process the HAL knows about, paired with
    /// the `pid_t` reported on the process object. The caller is responsible
    /// for enriching this with `NSRunningApplication` metadata.
    func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)]

    /// Reconfigures `engine.inputNode` to read from `deviceID` by setting the
    /// underlying audio unit's `kAudioOutputUnitProperty_CurrentDevice`.
    func configureEngineInput(_ engine: AVAudioEngine, toReadFrom deviceID: AudioDeviceID) throws

    /// Resets `engine.inputNode` to read from the system default input
    /// device. Called during teardown so the engine doesn't continue holding
    /// a reference to a soon-to-be-destroyed aggregate device.
    func resetEngineInput(_ engine: AVAudioEngine) throws
}

// MARK: - Real implementation

/// Concrete `CoreAudioInterface` that calls the real Apple HAL.
///
/// This is the implementation used in production. Tests inject a
/// `FakeCoreAudioInterface` instead. The HAL calls here follow the patterns
/// in [insidegui/AudioCap](https://github.com/insidegui/AudioCap), notably:
/// the per-process tap, the aggregate-device wrapper, and the
/// `kAudioOutputUnitProperty_CurrentDevice` setter on `inputNode`'s audio
/// unit.
public struct RealCoreAudioInterface: CoreAudioInterface {
    public init() {}

    // MARK: Permission-denied status detection

    /// Returns `true` when `status` most likely indicates the audio-capture
    /// permission was denied rather than some other HAL failure.
    ///
    /// Best-guess mapping; verified against real denial during Phase 1 manual
    /// passthrough test; refine if the observed code differs (U-008).
    ///
    /// Candidate codes:
    ///
    /// - `kAudioHardwareNotRunningError` (-66626): returned by some macOS 14.x
    ///   versions when the HAL cannot honour the request due to a policy gate
    ///   (permission not granted). The constant name is misleading — the HAL
    ///   *is* running, but it refuses the call.
    ///
    /// - The range −66731 … −66749 covers HAL permission/policy error codes
    ///   observed in beta builds and reported on the Apple Developer Forums.
    ///   The exact member of this range that surfaces for audio-capture denial
    ///   is macOS-version-dependent; we match the whole range conservatively.
    private func isPermissionDeniedStatus(_ status: OSStatus) -> Bool {
        if status == kAudioHardwareNotRunningError { return true }
        let permissionRange: ClosedRange<OSStatus> = -66_749 ... -66_731
        return permissionRange.contains(status)
    }

    // MARK: PID ↔ AudioObjectID translation

    public func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID {
        var pidQualifier = pid
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
            &pidQualifier,
            &size,
            &processID
        )
        // The PID→AudioObjectID translation requires HAL access. If permission
        // has not been granted the HAL returns an error here before we ever
        // call AudioHardwareCreateProcessTap. Detect that case explicitly so
        // the UI can surface .permissionDenied rather than .sourceNotFound.
        if status != noErr, isPermissionDeniedStatus(status) {
            throw CaptureError.permissionDenied
        }
        guard status == noErr, processID != kAudioObjectUnknown else {
            throw CaptureError.sourceNotFound(pid)
        }
        return processID
    }

    // MARK: Tap UID

    public func tapUID(for tapID: AudioObjectID) throws -> CFString {
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

    // MARK: Tap creation/destruction

    public func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID {
        let description = CATapDescription(stereoMixdownOfProcesses: [audioProcessID])
        description.uuid = UUID()
        description.name = "tap-n-filter.tap.\(audioProcessID)"
        description.isPrivate = true
        description.isExclusive = false
        // Mute the source process so its audio is intercepted, not just
        // observed. Without this, the source app's audio continues to
        // play through the system mixer alongside our processed copy and
        // the user hears the untouched original — the architecture
        // diagram in `docs/orchestration/phases/01-capture-spike.md`
        // explicitly labels the source-to-tap arrow "audio output
        // (intercepted)". See ADR-014 for the muting decision and its
        // implications for users.
        description.muteBehavior = .muted

        var tapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            // Map permission-denial status codes to .permissionDenied so the
            // UI can offer a targeted "Open System Settings" recovery path.
            // See isPermissionDeniedStatus(_:) for the candidate OSStatus
            // values and U-008 for verification against a live denial.
            if isPermissionDeniedStatus(status) {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.tapCreationFailed(status)
        }
        return tapID
    }

    public func destroyTap(_ tapID: AudioObjectID) throws {
        let status = AudioHardwareDestroyProcessTap(tapID)
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
    }

    // MARK: Aggregate device creation/destruction

    public func createAggregateDevice(
        containing tapID: AudioObjectID,
        uid: CFString,
        sourcePID: pid_t,
        displayName: String
    ) throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "tap-n-filter.aggregate.\(sourcePID)",
            kAudioAggregateDeviceNameKey: "tap-n-filter for \(displayName)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: false,
                    kAudioSubTapUIDKey: uid,
                ],
            ],
        ]

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else {
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }
        return deviceID
    }

    public func destroyAggregateDevice(_ deviceID: AudioDeviceID) throws {
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        guard status == noErr else {
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }
    }

    // MARK: Process enumeration

    public func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)] {
        // First, ask the HAL for the size of the process-object list.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "Process object list size lookup failed: \(sizeStatus)"
            )
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var processObjectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let listStatus = processObjectIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard listStatus == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "Process object list fetch failed: \(listStatus)"
            )
        }

        // For each process object, ask for its PID. Skip entries that fail to
        // report one — we cannot map them back to NSRunningApplication.
        var result: [(pid: pid_t, audioProcessID: AudioObjectID)] = []
        result.reserveCapacity(processObjectIDs.count)
        for processObjectID in processObjectIDs {
            if let pid = pid(for: processObjectID) {
                result.append((pid: pid, audioProcessID: processObjectID))
            }
        }
        return result
    }

    /// Best-effort lookup of the `pid_t` for a process object. Returns `nil`
    /// when the property is missing or zero — the caller filters those out
    /// rather than failing the whole enumeration.
    private func pid(for processObjectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            &size,
            &pidValue
        )
        guard status == noErr, pidValue > 0 else { return nil }
        return pidValue
    }

    // MARK: Engine input device wiring

    public func configureEngineInput(
        _ engine: AVAudioEngine,
        toReadFrom deviceID: AudioDeviceID
    ) throws {
        try setInputUnitDevice(on: engine, to: deviceID)
    }

    public func resetEngineInput(_ engine: AVAudioEngine) throws {
        let defaultDevice = try defaultInputDevice()
        try setInputUnitDevice(on: engine, to: defaultDevice)
    }

    private func setInputUnitDevice(on engine: AVAudioEngine, to deviceID: AudioDeviceID) throws {
        guard let inputUnit = engine.inputNode.audioUnit else {
            throw CaptureError.engineConfigurationFailed("Engine input node has no audio unit")
        }
        // 1. Point the AUHAL at the aggregate device.
        var mutableDeviceID = deviceID
        var status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed("Failed to set input device: \(status)")
        }
        // 2. Read the hardware stream format from the AUHAL's input scope
        //    (element 1 = the side connected to the device) and propagate
        //    its sample rate + channel count to the output scope (element
        //    1 = what AVAudioEngine reads as inputNode.outputFormat), but
        //    re-shape it into AVAudioEngine's standard non-interleaved
        //    Float32 layout. The AUHAL converts internally from the
        //    hardware's interleaved frames to the engine's deinterleaved
        //    layout.
        //
        //    Two reasons we cannot just copy the ASBD verbatim:
        //
        //    a) Without any propagation, the client format stays at
        //       AVAudioEngine's default (1 ch / 16 kHz) and every
        //       engine.connect against inputNode.outputFormat throws
        //       "Input HW format and tap format not matching".
        //
        //    b) Verbatim propagation of the hardware ASBD installs an
        //       interleaved layout on the client side, which
        //       AVAudioMixerNode and AVAudioUnitEQ reject with
        //       kAudioUnitErr_FormatNotSupported (-10868). The engine
        //       throws an NSException from
        //       AUInterfaceBaseV3::SetFormat that bubbles up as a
        //       SIGTRAP and crashes the process.
        //
        //    The bug existed in Phase 1's CaptureController.start path
        //    but wasn't caught because the Phase 1 live-render check
        //    was deferred (see state.json
        //    `phase-1-passthrough-test-needs-interactive`).
        var hardwareFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hardwareFormat,
            &formatSize
        )
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "Failed to read input hardware stream format: \(status)"
            )
        }
        guard let standardFormat = AVAudioFormat(
            standardFormatWithSampleRate: hardwareFormat.mSampleRate,
            channels: hardwareFormat.mChannelsPerFrame
        ) else {
            throw CaptureError.engineConfigurationFailed(
                "Could not build AVAudioEngine client format from hardware "
                + "ASBD (sampleRate=\(hardwareFormat.mSampleRate), "
                + "channels=\(hardwareFormat.mChannelsPerFrame))"
            )
        }
        var clientFormat = standardFormat.streamDescription.pointee
        status = AudioUnitSetProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "Failed to set engine client stream format (deinterleaved Float32, "
                + "rate=\(clientFormat.mSampleRate), ch=\(clientFormat.mChannelsPerFrame)): "
                + "\(status)"
            )
        }
        // 3. Read back the format the AUHAL actually accepted. AVAudioEngine
        //    or the AUHAL may silently coerce or reject the requested
        //    format, in which case the engine sees a different format than
        //    we intended on inputNode.outputFormat. Failing here gives a
        //    concrete error pointer rather than letting a downstream
        //    engine.connect throw with a less actionable message.
        var installedFormat = AudioStreamBasicDescription()
        formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &installedFormat,
            &formatSize
        )
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "Failed to read back installed client stream format: \(status)"
            )
        }
        // Compare the full ASBD, not just sample rate + channel count. The
        // AUHAL is known to silently coerce a requested non-interleaved Float32
        // into an interleaved layout (or a different bit depth) while still
        // returning noErr on the SetProperty call — then engine.start surfaces
        // a kAudioUnitErr_FormatNotSupported (-10868) downstream when the
        // graph's first AVAudioMixer tries to connect. Catching the mismatch
        // here makes the failure mode obvious instead of inscrutable.
        guard installedFormat.mSampleRate == clientFormat.mSampleRate,
              installedFormat.mChannelsPerFrame == clientFormat.mChannelsPerFrame,
              installedFormat.mFormatID == clientFormat.mFormatID,
              installedFormat.mFormatFlags == clientFormat.mFormatFlags,
              installedFormat.mBytesPerPacket == clientFormat.mBytesPerPacket,
              installedFormat.mFramesPerPacket == clientFormat.mFramesPerPacket,
              installedFormat.mBytesPerFrame == clientFormat.mBytesPerFrame,
              installedFormat.mBitsPerChannel == clientFormat.mBitsPerChannel
        else {
            throw CaptureError.engineConfigurationFailed(
                "Client stream format readback mismatch: requested "
                + "\(clientFormat.mSampleRate) Hz × \(clientFormat.mChannelsPerFrame) ch "
                + "(formatID=\(clientFormat.mFormatID), flags=\(clientFormat.mFormatFlags), "
                + "bytesPerFrame=\(clientFormat.mBytesPerFrame), bitsPerChannel=\(clientFormat.mBitsPerChannel)), "
                + "installed \(installedFormat.mSampleRate) Hz × \(installedFormat.mChannelsPerFrame) ch "
                + "(formatID=\(installedFormat.mFormatID), flags=\(installedFormat.mFormatFlags), "
                + "bytesPerFrame=\(installedFormat.mBytesPerFrame), bitsPerChannel=\(installedFormat.mBitsPerChannel))"
            )
        }
    }

    private func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CaptureError.engineConfigurationFailed(
                "Default input device lookup failed: \(status)"
            )
        }
        return deviceID
    }
}
