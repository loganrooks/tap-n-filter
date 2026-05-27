import AVFoundation
import CoreAudio
import Darwin
@testable import Capture

/// Test double for `CoreAudioInterface`. Records every call, exposes
/// configurable return values and overridable error injection.
///
/// Each method has:
/// - A call record (counter, parameter array, or both) for ordering /
///   arity assertions.
/// - A `*Result` closure (with a sensible canned default) so tests can
///   inject failures or specific IDs.
///
/// Sendable conformance is not claimed; tests run synchronously on a
/// single thread and the state mutation is intentional.
final class FakeCoreAudioInterface: CoreAudioInterface {

    // MARK: Call records

    private(set) var audioProcessIDCallPIDs: [pid_t] = []
    private(set) var tapUIDCallTapIDs: [AudioObjectID] = []
    private(set) var tapStreamFormatCallTapIDs: [AudioObjectID] = []
    private(set) var createTapCallProcessIDs: [AudioObjectID] = []
    private(set) var createAggregateDeviceCallDescriptions: [CFDictionary] = []
    private(set) var setAggregateTapListCalls: [(aggregateID: AudioDeviceID, tapUIDs: CFArray)] = []
    private(set) var destroyAggregateDeviceCallIDs: [AudioDeviceID] = []
    private(set) var destroyTapCallIDs: [AudioObjectID] = []
    private(set) var createIOProcIDCalls: [(deviceID: AudioDeviceID, clientData: UnsafeMutableRawPointer?)] = []
    private(set) var destroyIOProcIDCalls: [(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID)] = []
    private(set) var startDeviceCalls: [(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID)] = []
    private(set) var stopDeviceCalls: [(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID)] = []
    private(set) var availableAudioProcessesCallCount = 0

    // MARK: Stubbable behaviour

    /// Map from `pid_t` to the AudioObjectID returned by
    /// `audioProcessID(forPID:)`. Unmapped PIDs throw
    /// `CaptureError.sourceNotFound`.
    var audioProcessIDsByPID: [pid_t: AudioObjectID] = [:]

    var tapUIDResult: (AudioObjectID) throws -> CFString = { id in
        "fake.tap.\(id)" as CFString
    }

    /// Default tap stream format: 48 kHz × 2 ch Float32 non-interleaved.
    /// Tests that need a different format override this.
    var tapStreamFormatResult: (AudioObjectID) throws -> AudioStreamBasicDescription = { _ in
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48_000
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        asbd.mBytesPerPacket = 4
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 4
        asbd.mChannelsPerFrame = 2
        asbd.mBitsPerChannel = 32
        return asbd
    }

    var createTapResult: (AudioObjectID) throws -> AudioObjectID = { processObjectID in
        processObjectID + 1_000
    }

    /// Aggregate ID returned on success. Tests may override to inject
    /// failures or specific IDs.
    var createAggregateDeviceResult: (CFDictionary) throws -> AudioDeviceID = { _ in
        // A stable arbitrary AudioDeviceID; tests that need a particular
        // value can override.
        2_000
    }

    var setAggregateTapListResult: (AudioDeviceID, CFArray) throws -> Void = { _, _ in }

    var destroyAggregateDeviceResult: (AudioDeviceID) throws -> Void = { _ in }

    var destroyTapResult: (AudioObjectID) throws -> Void = { _ in }

    /// Next IOProc ID to hand back. Bumped on each call so tests can
    /// distinguish multiple registrations.
    var nextIOProcID: AudioDeviceIOProcID? = {
        // AudioDeviceIOProcID is a function-pointer-like opaque type;
        // tests don't dereference it. We synthesise an arbitrary
        // non-nil pointer for ergonomics.
        let raw = UnsafeMutableRawPointer(bitPattern: 0xCAFE_BABE)!
        return unsafeBitCast(raw, to: AudioDeviceIOProcID.self)
    }()

    /// Default closure for `createIOProcID`. Resolved lazily so it can
    /// read `nextIOProcID` off `self` — a property-default closure can't
    /// capture `self`, which is why the closure is constructed in init.
    /// Tests may overwrite this with their own closure.
    lazy var createIOProcIDResult: (AudioDeviceID, AudioDeviceIOProc, UnsafeMutableRawPointer?) throws -> AudioDeviceIOProcID = { [weak self] _, _, _ in
        guard let id = self?.nextIOProcID else {
            throw CaptureError.engineConfigurationFailed("fake: nextIOProcID is nil")
        }
        return id
    }

    var destroyIOProcIDResult: (AudioDeviceID, AudioDeviceIOProcID) throws -> Void = { _, _ in }

    var startDeviceResult: (AudioDeviceID, AudioDeviceIOProcID) throws -> Void = { _, _ in }

    var stopDeviceResult: (AudioDeviceID, AudioDeviceIOProcID) throws -> Void = { _, _ in }

    var availableAudioProcessesResult: () throws -> [(pid: pid_t, audioProcessID: AudioObjectID)]
        = { [] }

    // MARK: CoreAudioInterface

    func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID {
        audioProcessIDCallPIDs.append(pid)
        if let id = audioProcessIDsByPID[pid] {
            return id
        }
        throw CaptureError.sourceNotFound(pid)
    }

    func tapUID(for tapID: AudioObjectID) throws -> CFString {
        tapUIDCallTapIDs.append(tapID)
        return try tapUIDResult(tapID)
    }

    func tapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        tapStreamFormatCallTapIDs.append(tapID)
        return try tapStreamFormatResult(tapID)
    }

    func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID {
        createTapCallProcessIDs.append(audioProcessID)
        return try createTapResult(audioProcessID)
    }

    func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID {
        createAggregateDeviceCallDescriptions.append(description)
        return try createAggregateDeviceResult(description)
    }

    func setAggregateTapList(_ aggregateID: AudioDeviceID, tapUIDs: CFArray) throws {
        setAggregateTapListCalls.append((aggregateID, tapUIDs))
        try setAggregateTapListResult(aggregateID, tapUIDs)
    }

    func destroyAggregateDevice(_ deviceID: AudioDeviceID) throws {
        destroyAggregateDeviceCallIDs.append(deviceID)
        try destroyAggregateDeviceResult(deviceID)
    }

    func destroyTap(_ tapID: AudioObjectID) throws {
        destroyTapCallIDs.append(tapID)
        try destroyTapResult(tapID)
    }

    func createIOProcID(
        deviceID: AudioDeviceID,
        ioProc: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws -> AudioDeviceIOProcID {
        createIOProcIDCalls.append((deviceID, clientData))
        return try createIOProcIDResult(deviceID, ioProc, clientData)
    }

    func destroyIOProcID(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
        destroyIOProcIDCalls.append((deviceID, ioProcID))
        try destroyIOProcIDResult(deviceID, ioProcID)
    }

    func startDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
        startDeviceCalls.append((deviceID, ioProcID))
        try startDeviceResult(deviceID, ioProcID)
    }

    func stopDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
        stopDeviceCalls.append((deviceID, ioProcID))
        try stopDeviceResult(deviceID, ioProcID)
    }

    func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)] {
        availableAudioProcessesCallCount += 1
        return try availableAudioProcessesResult()
    }
}
