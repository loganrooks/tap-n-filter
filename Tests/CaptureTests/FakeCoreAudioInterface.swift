import AVFoundation
import CoreAudio
import Darwin
@testable import Capture

/// Test double for `CoreAudioInterface`. Records every call, exposes
/// configurable return values and overridable error injection.
///
/// Each method has:
/// - A `*Calls` counter for ordering-and-arity assertions.
/// - A `*Result` closure (defaulting to a sensible canned value) so tests can
///   inject failures or specific IDs.
///
/// Sendable conformance is not claimed; tests run synchronously on a single
/// thread and the state mutation is intentional.
final class FakeCoreAudioInterface: CoreAudioInterface {

    // MARK: Call records

    private(set) var audioProcessIDCallPIDs: [pid_t] = []
    private(set) var tapUIDCallTapIDs: [AudioObjectID] = []
    private(set) var createTapCallProcessIDs: [AudioObjectID] = []
    private(set) var createAggregateDeviceCallTapIDs: [AudioObjectID] = []
    private(set) var destroyAggregateDeviceCallIDs: [AudioDeviceID] = []
    private(set) var destroyTapCallIDs: [AudioObjectID] = []
    private(set) var availableAudioProcessesCallCount = 0
    private(set) var configureEngineInputCallDeviceIDs: [AudioDeviceID] = []
    private(set) var resetEngineInputCallCount = 0

    // MARK: Stubbable behaviour

    /// Map from `pid_t` to the AudioObjectID returned by `audioProcessID(forPID:)`.
    /// Unmapped PIDs throw `CaptureError.sourceNotFound`.
    var audioProcessIDsByPID: [pid_t: AudioObjectID] = [:]

    /// Override-the-default closure for tap UID lookup. Returns a string by
    /// default ("fake.tap.<id>") so tests don't need to set it manually.
    var tapUIDResult: (AudioObjectID) throws -> CFString = { id in
        "fake.tap.\(id)" as CFString
    }

    /// Override-the-default closure for tap creation. Returns
    /// `processObjectID + 1000` so produced IDs are easy to recognise in
    /// debugging output.
    var createTapResult: (AudioObjectID) throws -> AudioObjectID = { processObjectID in
        processObjectID + 1000
    }

    /// Override-the-default closure for aggregate device creation. Returns
    /// `tapID + 1000` for the same legibility reason as `createTapResult`.
    var createAggregateDeviceResult: (
        _ tapID: AudioObjectID,
        _ uid: CFString,
        _ sourcePID: pid_t,
        _ displayName: String
    ) throws -> AudioDeviceID = { tapID, _, _, _ in tapID + 1000 }

    /// Hook for destroy-aggregate-device. Defaults to success.
    var destroyAggregateDeviceResult: (AudioDeviceID) throws -> Void = { _ in }

    /// Hook for destroy-tap. Defaults to success.
    var destroyTapResult: (AudioObjectID) throws -> Void = { _ in }

    /// Result for `availableAudioProcesses`. Defaults to an empty list.
    var availableAudioProcessesResult: () throws -> [(pid: pid_t, audioProcessID: AudioObjectID)]
        = { [] }

    /// Hook for `configureEngineInput`. Defaults to success.
    var configureEngineInputResult: (AVAudioEngine, AudioDeviceID) throws -> Void = { _, _ in }

    /// Hook for `resetEngineInput`. Defaults to success.
    var resetEngineInputResult: (AVAudioEngine) throws -> Void = { _ in }

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

    func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID {
        createTapCallProcessIDs.append(audioProcessID)
        return try createTapResult(audioProcessID)
    }

    func createAggregateDevice(
        containing tapID: AudioObjectID,
        uid: CFString,
        sourcePID: pid_t,
        displayName: String
    ) throws -> AudioDeviceID {
        createAggregateDeviceCallTapIDs.append(tapID)
        return try createAggregateDeviceResult(tapID, uid, sourcePID, displayName)
    }

    func destroyAggregateDevice(_ deviceID: AudioDeviceID) throws {
        destroyAggregateDeviceCallIDs.append(deviceID)
        try destroyAggregateDeviceResult(deviceID)
    }

    func destroyTap(_ tapID: AudioObjectID) throws {
        destroyTapCallIDs.append(tapID)
        try destroyTapResult(tapID)
    }

    func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)] {
        availableAudioProcessesCallCount += 1
        return try availableAudioProcessesResult()
    }

    func configureEngineInput(
        _ engine: AVAudioEngine,
        toReadFrom deviceID: AudioDeviceID
    ) throws {
        configureEngineInputCallDeviceIDs.append(deviceID)
        try configureEngineInputResult(engine, deviceID)
    }

    func resetEngineInput(_ engine: AVAudioEngine) throws {
        resetEngineInputCallCount += 1
        try resetEngineInputResult(engine)
    }
}
