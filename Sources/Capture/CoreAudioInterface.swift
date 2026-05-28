import AVFoundation
import CoreAudio
import Darwin

/// A protocol-based seam over the C-level Core Audio HAL functions that the
/// capture layer needs.
///
/// Two reasons this exists:
///
/// 1. The HAL functions are global C functions and difficult to mock at the
///    call site. Wrapping them in a protocol lets `CaptureController` and
///    `TapIOProcReader` be exercised against a `FakeCoreAudioInterface` in
///    unit tests without touching the real HAL.
/// 2. Each method is the smallest meaningful unit of failure for the state
///    machine. Callers can detect "tap created but aggregate device failed"
///    and unwind exactly the right resources.
///
/// The real implementation, `RealCoreAudioInterface`, follows the working
/// aggregate pattern proven empirically in EXP-026 (see
/// `docs/investigations/2026-05-audio-pipeline.md`) and documented in
/// `docs/specs/capture-v2.md`.
public protocol CoreAudioInterface {
    /// Resolves a Unix `pid_t` to the Core Audio HAL's `AudioObjectID` for
    /// that process. Throws `CaptureError.sourceNotFound` if the HAL does not
    /// know about the process (typically because it isn't producing audio).
    func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID

    /// Reads the CFString UID of a tap object. Tap UIDs are required when
    /// installing the tap on the aggregate device's tap list.
    func tapUID(for tapID: AudioObjectID) throws -> CFString

    /// Reads the tap's preferred stream format
    /// (`kAudioTapPropertyFormat`). The HAL fills the
    /// `AudioStreamBasicDescription` with the rate, channel count, and PCM
    /// shape the tap will deliver — typically 44.1 kHz × 2 ch Float32
    /// non-interleaved for stereo-mixdown taps.
    func tapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription

    /// Creates a stereo-mixdown process tap for the given audio-process
    /// object. The caller owns the returned tap and must destroy it via
    /// `destroyTap`.
    func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID

    /// Creates an aggregate device using the provided description dictionary.
    /// The caller owns the dictionary's structure; this protocol method is
    /// the seam through which tests can capture and verify the dictionary
    /// contents.
    ///
    /// Per `capture-v2.md` § "Aggregate device dictionary — exact form" the
    /// dictionary must include `kAudioAggregateDeviceSubDeviceListKey: []
    /// as CFArray` and `kAudioAggregateDeviceMasterSubDeviceKey: 0`, and
    /// must NOT include `kAudioAggregateDeviceTapListKey` or
    /// `kAudioAggregateDeviceTapAutoStartKey` at creation time. The tap
    /// list is set as a separate property write via
    /// `setAggregateTapList(_:tapUIDs:)`.
    func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID

    /// Sets the aggregate device's tap list to the given array of tap UIDs.
    /// The payload is `CFArray<CFString>` (UID strings only); the embedded-
    /// creation `CFArray<CFDictionary>` form does NOT work with the post-set
    /// path.
    func setAggregateTapList(_ aggregateID: AudioDeviceID, tapUIDs: CFArray) throws

    /// Destroys an aggregate device previously created by
    /// `createAggregateDevice`. Failure is propagated so callers can log; the
    /// HAL leaks a device entry if this is skipped.
    func destroyAggregateDevice(_ deviceID: AudioDeviceID) throws

    /// Destroys a tap previously created by `createTap`.
    func destroyTap(_ tapID: AudioObjectID) throws

    /// Registers a C-function IOProc on `deviceID`. `clientData` is
    /// opaque to the HAL and reaches the IOProc unchanged via its
    /// `inClientData` parameter. The IOProc itself MUST be a
    /// `@convention(c)` function pointer (not a closure) because the HAL
    /// uses the address as a stable identifier.
    func createIOProcID(
        deviceID: AudioDeviceID,
        ioProc: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws -> AudioDeviceIOProcID

    /// Destroys an IOProc registration previously created by
    /// `createIOProcID`.
    func destroyIOProcID(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws

    /// Starts the IOProc firing. Synchronous w.r.t. registration: returns
    /// after the HAL has scheduled the IOProc but the first invocation may
    /// not have happened yet.
    func startDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws

    /// Stops the IOProc. Synchronous w.r.t. the IOProc thread: no new
    /// IOProc invocations begin after this returns. Safe to destroy the
    /// IOProc ID and the device after this call returns.
    func stopDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws

    /// Enumerates every audio-active process the HAL knows about, paired with
    /// the `pid_t` reported on the process object. The caller is responsible
    /// for enriching this with `NSRunningApplication` metadata.
    func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)]

    // MARK: - Observability helpers (EXP-029)
    //
    // These three methods are pure-read diagnostic queries used by
    // TapIOProcReader to surface observable HAL state at each step of
    // the start path. They exist so that the IOProc-no-fire / 'nope'-
    // on-AudioDeviceStart investigation can compare a working control
    // (the minimal-reader path) against the failing production path
    // step-by-step. None of them have side effects on capture state.

    /// Number of streams the device exposes in the given scope. Returns
    /// `-1` if the property query itself fails (i.e., the device does
    /// not support `kAudioDevicePropertyStreams` in that scope, which
    /// is itself diagnostic).
    func streamCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int

    /// Reads `kAudioDevicePropertyDeviceIsRunning`. Returns `false` on
    /// query failure. Used as a pre-`AudioDeviceStart` sanity check —
    /// the device should NOT already be running.
    func deviceIsRunning(deviceID: AudioDeviceID) -> Bool

    /// Lists every process tap currently registered with the HAL.
    /// Returns an empty array on enumeration failure. Used to detect
    /// orphaned taps from previous runs (H13). The list of all
    /// process-tap-class objects via
    /// `kAudioHardwarePropertyProcessObjectList` is what we'd want
    /// here; if that property is the wrong one for taps we fall back
    /// to returning `[]` and log the error.
    func enumerateProcessTaps() -> [AudioObjectID]

    // MARK: - Orphan cleanup helpers (EXP-030)
    //
    // These four methods support the defensive cleanup at
    // `CaptureController.init` that destroys taps and aggregate devices
    // left behind by a force-killed prior run (H13). They are pure
    // diagnostic reads except for the destroy methods (which already
    // exist on the protocol — `destroyTap` and
    // `destroyAggregateDevice`).

    /// Lists every audio device the HAL knows about
    /// (`kAudioHardwarePropertyDevices`). Used by the orphan-cleanup
    /// path to find aggregate devices we created in a prior run.
    /// Returns an empty array on enumeration failure.
    func enumerateAllAudioDevices() -> [AudioDeviceID]

    /// Reads `kAudioDevicePropertyDeviceUID` from the given device.
    /// Returns `nil` on query failure. Used to identify aggregates we
    /// own by matching the `tap-n-filter.aggregate.*` UID prefix.
    func audioDeviceUID(_ deviceID: AudioDeviceID) -> String?

    /// Reads `kAudioObjectPropertyName` from the given tap object.
    /// Returns `nil` on query failure. Process taps we create in
    /// `createTap(for:)` are named `tap-n-filter.tap.<audioProcessID>`;
    /// the orphan-cleanup path uses this to identify our taps among
    /// any others the HAL exposes.
    func tapName(_ tapID: AudioObjectID) -> String?
}

// MARK: - Real implementation

/// Concrete `CoreAudioInterface` that calls the real Apple HAL.
///
/// Built on the aggregate pattern proven in EXP-026: aggregate created with
/// `kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
/// `kAudioAggregateDeviceMasterSubDeviceKey: 0`, with the tap list set after
/// creation as `CFArray<CFString>`. See `docs/specs/capture-v2.md` for the
/// architecture and `docs/investigations/2026-05-audio-pipeline.md` for the
/// empirical work that validated it.
public struct RealCoreAudioInterface: CoreAudioInterface {
    public init() {}

    // MARK: Permission-denied status detection

    /// Returns `true` when `status` most likely indicates the audio-capture
    /// permission was denied rather than some other HAL failure.
    ///
    /// Candidate codes:
    ///
    /// - `kAudioHardwareNotRunningError` (-66626): returned by some macOS
    ///   versions when the HAL cannot honour the request due to a policy
    ///   gate (permission not granted). The constant name is misleading —
    ///   the HAL *is* running, but it refuses the call.
    ///
    /// - The range −66731 … −66749 covers HAL permission/policy error
    ///   codes observed in beta builds and reported on the Apple Developer
    ///   Forums. The exact member of this range that surfaces for audio-
    ///   capture denial is macOS-version-dependent; the whole range is
    ///   matched conservatively.
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
        if status != noErr, isPermissionDeniedStatus(status) {
            throw CaptureError.permissionDenied
        }
        guard status == noErr, processID != kAudioObjectUnknown else {
            throw CaptureError.sourceNotFound(pid)
        }
        return processID
    }

    // MARK: Tap UID + format

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

    public func tapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &size,
            &asbd
        )
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
        return asbd
    }

    // MARK: Tap creation/destruction

    public func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID {
        let description = CATapDescription(stereoMixdownOfProcesses: [audioProcessID])
        description.uuid = UUID()
        description.name = "tap-n-filter.tap.\(audioProcessID)"
        description.isPrivate = true
        description.isExclusive = false
        // Mute the source process while we are reading the tap, so our
        // processed copy is what the user hears (not original + processed
        // overlapping). ADR-014 originally specified `.muted` (always
        // mute while the tap object exists); EXP-027 found that `.muted`
        // combined with the direct-IOProc architecture (ADR-018) makes
        // `AudioDeviceStart` return `kAudioHardwareIllegalOperationError`
        // ('nope' = 1852797029). `.mutedWhenTapped` (source muted while
        // a client is actively reading the tap) is behaviourally
        // identical for tap-n-filter's lifecycle — we always have a
        // reader between `start()` and `stop()` — and is what EXP-026
        // used successfully. ADR-014's documented reason for preferring
        // `.muted` was "no auto-unmute state machine"; with the new
        // architecture that distinction is irrelevant.
        description.muteBehavior = .mutedWhenTapped

        var tapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
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

    public func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }
        return deviceID
    }

    public func setAggregateTapList(_ aggregateID: AudioDeviceID, tapUIDs: CFArray) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The post-set tap list expects a `CFArray<CFString>` payload (UIDs
        // only). The pointer-to-the-CFArray-value pattern matches what
        // audiotee does at AudioTapManager.swift line 127; the
        // CFArray<CFDictionary> form is for the embedded-creation path and
        // does NOT work as a post-set property write.
        var arrayCopy = tapUIDs
        let status = withUnsafePointer(to: &arrayCopy) { ptr in
            AudioObjectSetPropertyData(
                aggregateID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFArray>.stride),
                ptr
            )
        }
        guard status == noErr else {
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }
    }

    public func destroyAggregateDevice(_ deviceID: AudioDeviceID) throws {
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        guard status == noErr else {
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }
    }

    // MARK: IOProc lifecycle

    public func createIOProcID(
        deviceID: AudioDeviceID,
        ioProc: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(deviceID, ioProc, clientData, &procID)
        guard status == noErr, let proc = procID else {
            throw CaptureError.engineConfigurationFailed(
                "AudioDeviceCreateIOProcID returned \(status)"
            )
        }
        return proc
    }

    public func destroyIOProcID(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
        let status = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "AudioDeviceDestroyIOProcID returned \(status)"
            )
        }
    }

    public func startDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
        let status = AudioDeviceStart(deviceID, ioProcID)
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "AudioDeviceStart returned \(status)"
            )
        }
    }

    public func stopDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
        let status = AudioDeviceStop(deviceID, ioProcID)
        guard status == noErr else {
            throw CaptureError.engineConfigurationFailed(
                "AudioDeviceStop returned \(status)"
            )
        }
    }

    // MARK: Process enumeration

    public func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)] {
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

        var result: [(pid: pid_t, audioProcessID: AudioObjectID)] = []
        result.reserveCapacity(processObjectIDs.count)
        for processObjectID in processObjectIDs {
            if let pid = pid(for: processObjectID) {
                result.append((pid: pid, audioProcessID: processObjectID))
            }
        }
        return result
    }

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

    // MARK: Observability helpers (EXP-029)

    public func streamCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { return -1 }
        return Int(dataSize) / MemoryLayout<AudioStreamID>.size
    }

    public func deviceIsRunning(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    public func enumerateProcessTaps() -> [AudioObjectID] {
        // Process taps live in `kAudioHardwarePropertyTapList` (macOS 14.4+).
        // We query the size, allocate, fetch. Return [] on any failure —
        // an empty list with a logged note is fine for diagnostic purposes.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
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
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let fetchStatus = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buf.baseAddress!
            )
        }
        guard fetchStatus == noErr else { return [] }
        return ids
    }

    // MARK: - Orphan cleanup helpers (EXP-030)

    public func enumerateAllAudioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        let fetchStatus = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buf.baseAddress!
            )
        }
        guard fetchStatus == noErr else { return [] }
        return ids
    }

    public func audioDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &uid
        )
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    public func tapName(_ tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &size,
            &name
        )
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
