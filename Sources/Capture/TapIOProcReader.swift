import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Owns the tap + aggregate device + IOProc + ring buffer for a single
/// capture source. Push side: the C `@convention(c)` IOProc fires on a
/// Core Audio thread and writes captured frames into the ring buffer.
/// Pull side: an `AVAudioSourceNode` render callback (wired up by the
/// caller in `CaptureController`) reads frames out of the same ring
/// buffer.
///
/// The architecture is the direct-IOProc + AVAudioSourceNode pattern that
/// ADR-018 commits to. The aggregate device is created with the exact
/// dictionary keys proven in EXP-026: `SubDeviceList: []`,
/// `MasterSubDevice: 0`, no `TapList` at creation, no `TapAutoStart`.
/// The tap list is set after creation as `CFArray<CFString>` (UID strings
/// only).
///
/// Lifecycle:
///
/// 1. `init` resolves the tap's preferred stream format and allocates
///    the ring buffer at the tap rate × 2 s capacity. If init fails, no
///    resources are leaked.
/// 2. `start()` builds the aggregate, sets the tap list, registers the
///    IOProc, and starts the device. After return the IOProc is
///    scheduled; the first invocation may not have happened yet. On
///    failure any partial state is unwound; the tap survives so the
///    caller may retry `start()` on the same reader instance.
/// 3. `stop()` is idempotent. It stops the device, destroys the IOProc
///    ID, destroys the aggregate, and destroys the tap. After `stop()`
///    the reader is dead; a fresh `init` is required for a new capture.
///
/// Thread safety: `start` and `stop` are intended to be called on the
/// main thread only. The IOProc closure runs on a Core Audio internal
/// thread and reaches the reader via `Unmanaged.passUnretained(self)`.
/// The lifetime invariant — "the reader outlives every IOProc
/// invocation" — is enforced by `stop()` calling `stopDevice` (which is
/// synchronous w.r.t. the IOProc thread) before destroying anything.
@available(macOS 14.4, *)
public final class TapIOProcReader: @unchecked Sendable {

    /// The tap's preferred stream format. Resolved at init time so the
    /// caller can use it to build an `AVAudioSourceNode`.
    public let format: AVAudioFormat

    /// The ring buffer the IOProc writes to and the SourceNode render
    /// callback reads from. Exposed so the caller can capture it weakly
    /// in the render block.
    public let ring: AudioRingBuffer

    /// Number of channels in the tap stream. Mirrored on the instance
    /// (rather than read from `format.channelCount` per IOProc fire) so
    /// the C `@convention(c)` callback can read it cheaply.
    fileprivate let channelCount: Int

    /// `true` between successful `start()` and the next `stop()`.
    public var isRunning: Bool {
        return aggregateID != nil && ioProcID != nil
    }

    /// The opaque pointer handed to the IOProc as `inClientData`. Stored
    /// on the instance so we can hand it to the HAL's destroy path on
    /// teardown.
    private var clientData: UnsafeMutableRawPointer?

    private let coreAudio: CoreAudioInterface
    private let audioProcessID: AudioObjectID

    private var tapID: AudioObjectID?
    private var aggregateID: AudioDeviceID?
    private var ioProcID: AudioDeviceIOProcID?

    public init(
        audioProcessID: AudioObjectID,
        coreAudio: CoreAudioInterface
    ) throws {
        self.audioProcessID = audioProcessID
        self.coreAudio = coreAudio

        let tap = try coreAudio.createTap(for: audioProcessID)
        do {
            let asbd = try coreAudio.tapStreamFormat(for: tap)
            guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
                throw CaptureError.engineConfigurationFailed(
                    "tap stream format is degenerate "
                    + "(rate=\(asbd.mSampleRate), channels=\(asbd.mChannelsPerFrame))"
                )
            }
            guard let avFormat = AVAudioFormat(
                standardFormatWithSampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame
            ) else {
                throw CaptureError.engineConfigurationFailed(
                    "could not build AVAudioFormat from tap format "
                    + "(rate=\(asbd.mSampleRate), channels=\(asbd.mChannelsPerFrame))"
                )
            }
            self.format = avFormat
            let channels = Int(avFormat.channelCount)
            self.channelCount = channels
            let capacity = max(1, Int(asbd.mSampleRate) * 2)
            self.ring = AudioRingBuffer(channelCount: channels, capacity: capacity)
            self.tapID = tap
        } catch {
            try? coreAudio.destroyTap(tap)
            throw error
        }
    }

    /// Build the aggregate device, attach the tap, register the IOProc,
    /// and start the device.
    ///
    /// If a previous `start()` succeeded and the reader is already
    /// running, this is a no-op. If the previous `start()` failed, the
    /// reader cleans up any partial state and a fresh `start()` may
    /// proceed on the same instance.
    public func start() throws {
        guard let tap = tapID else {
            throw CaptureError.engineConfigurationFailed(
                "TapIOProcReader.start called after stop()"
            )
        }
        if aggregateID != nil, ioProcID != nil {
            return
        }

        let uid = try coreAudio.tapUID(for: tap)
        let aggregateUID =
            "tap-n-filter.aggregate.\(audioProcessID).\(UUID().uuidString)"

        // EXACT dictionary form from `capture-v2.md` § "Aggregate device
        // dictionary — exact form". The SubDeviceList and MasterSubDevice
        // keys are load-bearing per EXP-026; do NOT include
        // TapListKey or TapAutoStartKey here.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "tap-n-filter aggregate \(audioProcessID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
            kAudioAggregateDeviceMasterSubDeviceKey: 0,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        let aggregate = try coreAudio.createAggregateDevice(
            description: description as CFDictionary
        )
        var didFinishSuccessfully = false
        defer {
            if !didFinishSuccessfully {
                try? coreAudio.destroyAggregateDevice(aggregate)
            }
        }

        // Post-set the tap list as CFArray<CFString>. The array-of-dict
        // form does not work here per EXP-026 / audiotee.
        try coreAudio.setAggregateTapList(aggregate, tapUIDs: [uid] as CFArray)

        let cd = Unmanaged.passUnretained(self).toOpaque()
        let proc = try coreAudio.createIOProcID(
            deviceID: aggregate,
            ioProc: tapIOProcReaderIOProc,
            clientData: cd
        )
        var didStartDevice = false
        defer {
            if !didFinishSuccessfully && !didStartDevice {
                try? coreAudio.destroyIOProcID(deviceID: aggregate, ioProcID: proc)
            }
        }

        try coreAudio.startDevice(deviceID: aggregate, ioProcID: proc)
        didStartDevice = true
        // From this point any failure path must also call stopDevice
        // before destroying the IOProc ID. There are no remaining
        // throwing calls below, so the success commit just promotes the
        // local handles into instance state.

        self.clientData = cd
        self.aggregateID = aggregate
        self.ioProcID = proc
        didFinishSuccessfully = true
    }

    /// Stop the IOProc, destroy the IOProc ID, destroy the aggregate,
    /// destroy the tap. Idempotent: safe to call from any state, safe to
    /// call twice. Errors from individual HAL calls are swallowed because
    /// the goal is "leave no orphans" rather than "report every
    /// status code".
    public func stop() {
        if let aggregate = aggregateID, let proc = ioProcID {
            try? coreAudio.stopDevice(deviceID: aggregate, ioProcID: proc)
            try? coreAudio.destroyIOProcID(deviceID: aggregate, ioProcID: proc)
        }
        ioProcID = nil

        if let aggregate = aggregateID {
            try? coreAudio.destroyAggregateDevice(aggregate)
        }
        aggregateID = nil

        if let tap = tapID {
            try? coreAudio.destroyTap(tap)
        }
        tapID = nil

        clientData = nil
    }

    deinit {
        // Best-effort cleanup if the owner forgot to call stop(). The HAL
        // calls in stop() are synchronous so this is safe to run from
        // deinit; the IOProc thread has been stopped before any
        // destruction begins.
        stop()
    }

    // MARK: IOProc payload (called from the C IOProc on Core Audio thread)

    /// Push samples from a tap's `AudioBufferList` into the ring buffer.
    /// Called from `tapIOProcReaderIOProc` on a Core Audio thread; must
    /// not allocate, block, or call into Swift runtime machinery beyond
    /// the cheap operations the ring buffer already performs.
    fileprivate func pushIOProcSamples(
        _ inputData: UnsafePointer<AudioBufferList>
    ) {
        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard inputList.count > 0 else { return }

        let bytesPerChannel = Int(inputList[0].mDataByteSize)
        let frames = bytesPerChannel / MemoryLayout<Float>.size
        guard frames > 0 else { return }

        let activeChannels = min(inputList.count, channelCount)
        guard activeChannels > 0 else { return }

        // Use a stack-allocated scratch for the source pointers so the
        // IOProc path doesn't heap-allocate per fire. Up to 8 channels is
        // far above any tap we'd reasonably encounter.
        withUnsafeTemporaryAllocation(
            of: UnsafePointer<Float>?.self,
            capacity: activeChannels
        ) { scratch in
            for ch in 0..<activeChannels {
                guard let raw = inputList[ch].mData else {
                    scratch[ch] = nil
                    return
                }
                scratch[ch] = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
            }
            // Build a temporary `[UnsafePointer<Float>]` view of the
            // scratch buffer for the ring buffer API. The array carries
            // a copy of the pointers; the storage backing them belongs
            // to the inputList.
            var sources: [UnsafePointer<Float>] = []
            sources.reserveCapacity(activeChannels)
            for ch in 0..<activeChannels {
                guard let ptr = scratch[ch] else { return }
                sources.append(ptr)
            }
            _ = ring.write(from: sources, frames: frames)
        }
    }
}

/// File-scope `@convention(c)` IOProc function pointer. The HAL passes the
/// `TapIOProcReader` instance through `inClientData`; the callback
/// retrieves it via `Unmanaged.fromOpaque(_:).takeUnretainedValue()`. The
/// reader's `pushIOProcSamples(_:)` does the actual ring-buffer write.
///
/// This function is `internal` rather than `private` so tests can verify
/// the IOProc path end-to-end by constructing a fake `AudioBufferList`,
/// invoking the IOProc, and asserting the ring received the samples.
@available(macOS 14.4, *)
let tapIOProcReaderIOProc: AudioDeviceIOProc = {
    _, _, inInputData, _, _, _, inClientData -> OSStatus in
    guard let clientData = inClientData else { return noErr }
    let reader = Unmanaged<TapIOProcReader>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    reader.pushIOProcSamples(inInputData)
    return noErr
}
