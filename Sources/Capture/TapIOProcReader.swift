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
/// EXP-029 diagnostic logger signature. Called at each observable step
/// of the tap → aggregate → IOProc → AudioDeviceStart path with a
/// pre-formatted message. The default value is a no-op so production
/// users that don't pass one pay nothing. The line format is structured
/// (`tag=value` pairs) so it can be grepped/diffed across runs.
@available(macOS 14.4, *)
public typealias TapIOProcReaderLogger = (String) -> Void

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

    /// True when the tap delivers *interleaved* samples — a single buffer
    /// holding `[L, R, L, R, …]` — rather than one buffer per channel.
    /// Resolved from the tap ASBD's `kAudioFormatFlagIsNonInterleaved` at
    /// init. macOS 26.3's stereo process tap is interleaved (flags=9:
    /// Float|Packed, no non-interleaved bit; bytesPerFrame=8). The ring
    /// buffer and render path are planar (one channel per buffer), so an
    /// interleaved tap must be de-interleaved in the IOProc — see
    /// `pushIOProcSamples` and EXP-034 / H17 channel-layout portion in
    /// `docs/investigations/2026-05-audio-pipeline.md`.
    fileprivate let isInterleaved: Bool

    /// Pre-allocated de-interleave scratch, non-nil only for interleaved
    /// multi-channel taps. Flat layout: channel `ch`'s planar samples live
    /// at `[ch * deinterleaveStride, (ch + 1) * deinterleaveStride)`. Lets
    /// the realtime IOProc split `[L, R, …]` into planar channels without
    /// allocating on the audio thread.
    fileprivate let deinterleaveScratch: UnsafeMutableBufferPointer<Float>?

    /// Per-channel stride (in frames) within `deinterleaveScratch`. Equal
    /// to the ring capacity, so a single IOProc payload can never overflow
    /// the scratch. Zero when `deinterleaveScratch` is nil.
    fileprivate let deinterleaveStride: Int

    /// Optional diagnostic logger. Called with structured `tag=value`
    /// messages at each observable step. Default: no-op.
    private let log: TapIOProcReaderLogger

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
        coreAudio: CoreAudioInterface,
        log: @escaping TapIOProcReaderLogger = { _ in }
    ) throws {
        self.audioProcessID = audioProcessID
        self.coreAudio = coreAudio
        self.log = log

        log("[EXP-029.input] audioProcessID=\(audioProcessID)")
        log("[EXP-029.tap.create] calling createTap(for:)")

        let tap: AudioObjectID
        do {
            tap = try coreAudio.createTap(for: audioProcessID)
            log("[EXP-029.tap.create] OK tapID=\(tap)")
        } catch {
            log("[EXP-029.tap.create] FAIL error=\(error)")
            throw error
        }

        do {
            let asbd = try coreAudio.tapStreamFormat(for: tap)
            log(
                "[EXP-029.tap.format] sampleRate=\(asbd.mSampleRate) "
                + "channels=\(asbd.mChannelsPerFrame) "
                + "formatID=\(asbd.mFormatID) "
                + "formatFlags=\(asbd.mFormatFlags) "
                + "bytesPerFrame=\(asbd.mBytesPerFrame)"
            )
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

            // Detect interleaving from the tap ASBD. The ring + render
            // path are planar; an interleaved tap is de-interleaved in the
            // IOProc, which needs a pre-allocated scratch buffer (realtime
            // thread — no allocations). Only allocate it when needed.
            let nonInterleavedBit =
                (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let interleaved = !nonInterleavedBit && channels > 1
            self.isInterleaved = interleaved
            if interleaved {
                self.deinterleaveStride = capacity
                let scratch = UnsafeMutableBufferPointer<Float>.allocate(
                    capacity: channels * capacity
                )
                scratch.initialize(repeating: 0)
                self.deinterleaveScratch = scratch
            } else {
                self.deinterleaveStride = 0
                self.deinterleaveScratch = nil
            }

            log(
                "[EXP-029.ring.alloc] channels=\(channels) capacity=\(capacity) "
                + "(frames per channel)"
            )
            log(
                "[EXP-034.layout] interleaved=\(interleaved) "
                + "formatFlags=\(asbd.mFormatFlags) "
                + "bytesPerFrame=\(asbd.mBytesPerFrame) "
                + "(planar pipeline; interleaved taps de-interleaved in IOProc)"
            )
        } catch {
            log("[EXP-029.init] FAIL during format probe; destroying tap")
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
            log("[EXP-029.start] already running; no-op")
            return
        }

        // Diagnostic: snapshot HAL state BEFORE we touch anything. This
        // lets us see whether an orphan from a previous run is present
        // (H13).
        let preTapEnum = coreAudio.enumerateProcessTaps()
        log("[EXP-029.prestart.taps] count=\(preTapEnum.count) ids=\(preTapEnum)")

        let uid = try coreAudio.tapUID(for: tap)
        log("[EXP-029.taplist.uid] uid=\(uid)")
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
        log(
            "[EXP-029.agg.desc] name=\"tap-n-filter aggregate \(audioProcessID)\" "
            + "uid=\(aggregateUID) "
            + "SubDeviceList=[](empty CFArray) "
            + "MasterSubDevice=0 "
            + "IsPrivate=true IsStacked=false "
            + "TapList=NOT_SET_AT_CREATION TapAutoStart=NOT_SET"
        )
        let aggregate = try coreAudio.createAggregateDevice(
            description: description as CFDictionary
        )
        log("[EXP-029.agg.create] OK aggregateID=\(aggregate)")
        let preInputStreams = coreAudio.streamCount(
            deviceID: aggregate,
            scope: kAudioObjectPropertyScopeInput
        )
        let preOutputStreams = coreAudio.streamCount(
            deviceID: aggregate,
            scope: kAudioObjectPropertyScopeOutput
        )
        log(
            "[EXP-029.agg.streams.pre] input=\(preInputStreams) "
            + "output=\(preOutputStreams) (expected before tap list set: 0,0)"
        )
        var didFinishSuccessfully = false
        defer {
            if !didFinishSuccessfully {
                log("[EXP-029.cleanup] destroying aggregate \(aggregate)")
                try? coreAudio.destroyAggregateDevice(aggregate)
            }
        }

        // Post-set the tap list as CFArray<CFString>. The array-of-dict
        // form does not work here per EXP-026 / audiotee.
        log("[EXP-029.taplist.set] payload=CFArray<CFString> count=1 uid=\(uid)")
        try coreAudio.setAggregateTapList(aggregate, tapUIDs: [uid] as CFArray)
        log("[EXP-029.taplist.set] OK")
        let postInputStreams = coreAudio.streamCount(
            deviceID: aggregate,
            scope: kAudioObjectPropertyScopeInput
        )
        let postOutputStreams = coreAudio.streamCount(
            deviceID: aggregate,
            scope: kAudioObjectPropertyScopeOutput
        )
        log(
            "[EXP-029.agg.streams.post] input=\(postInputStreams) "
            + "output=\(postOutputStreams) (expected after tap list set: 1,0)"
        )

        let cd = Unmanaged.passUnretained(self).toOpaque()
        let proc = try coreAudio.createIOProcID(
            deviceID: aggregate,
            ioProc: tapIOProcReaderIOProc,
            clientData: cd
        )
        log("[EXP-029.ioproc.create] OK")
        var didStartDevice = false
        defer {
            if !didFinishSuccessfully && !didStartDevice {
                log("[EXP-029.cleanup] destroying IOProc ID")
                try? coreAudio.destroyIOProcID(deviceID: aggregate, ioProcID: proc)
            }
        }

        let aggIsRunningPre = coreAudio.deviceIsRunning(deviceID: aggregate)
        log(
            "[EXP-029.prestart.agg] isRunning=\(aggIsRunningPre) "
            + "(expected false; AudioDeviceStart will flip it)"
        )

        do {
            try coreAudio.startDevice(deviceID: aggregate, ioProcID: proc)
            log("[EXP-029.start] OK AudioDeviceStart returned 0")
        } catch {
            log("[EXP-029.start] FAIL \(error) (FourCC translation: \(Self.fourCCErrorString(error)))")
            throw error
        }
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

    /// Pretty-print an OSStatus-style error as its FourCC. The HAL
    /// returns its policy/state errors as four-character codes packed
    /// into Int32. 1852797029 = 0x6E6F7065 = 'nope' =
    /// `kAudioHardwareIllegalOperationError`, for instance.
    private static func fourCCErrorString(_ error: Error) -> String {
        let captureError = error as? CaptureError
        let status: OSStatus
        switch captureError {
        case let .engineConfigurationFailed(message):
            // Extract trailing integer from "AudioDeviceStart returned N".
            let parts = message.split(separator: " ")
            if let last = parts.last, let parsed = OSStatus(last) {
                status = parsed
            } else {
                return "(no status in message: \(message))"
            }
        default:
            return "(not an engineConfigurationFailed)"
        }
        var s = status.bigEndian
        let bytes = withUnsafeBytes(of: &s) { Array($0) }
        let str = String(bytes: bytes, encoding: .ascii) ?? "?"
        return "\(status) ('\(str)')"
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
        deinterleaveScratch?.deallocate()
    }

    // MARK: IOProc payload (called from the C IOProc on Core Audio thread)

    /// Push samples from a tap's `AudioBufferList` into the ring buffer.
    /// Called from `tapIOProcReaderIOProc` on a Core Audio thread; must
    /// not allocate, block, or call into Swift runtime machinery. Uses
    /// `withUnsafeTemporaryAllocation` to lay the per-channel source
    /// pointers out in stack-resident contiguous storage, then hands a
    /// raw pointer to `AudioRingBuffer.write(fromChannelPointers:...)`
    /// — no Swift Array, no ARC traffic on the real-time path.
    fileprivate func pushIOProcSamples(
        _ inputData: UnsafePointer<AudioBufferList>
    ) {
        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard inputList.count > 0 else { return }

        if isInterleaved, let scratch = deinterleaveScratch {
            pushInterleaved(inputList, scratch: scratch)
        } else {
            pushPlanar(inputList)
        }
    }

    /// Interleaved path. The tap delivers one buffer of `[L, R, L, R, …]`;
    /// `inputList[0].mDataByteSize` covers ALL channels, so the real frame
    /// count is `totalFloats / channelCount`. De-interleave into the
    /// pre-allocated planar scratch (a strided copy — no allocation), then
    /// write the planar channels to the ring. Reading the interleaved
    /// stream as a single planar channel (the pre-EXP-034 bug) doubled the
    /// effective frame count and produced the octave-down, left-shifted,
    /// crackling artifact.
    private func pushInterleaved(
        _ inputList: UnsafeMutableAudioBufferListPointer,
        scratch: UnsafeMutableBufferPointer<Float>
    ) {
        guard let rawData = inputList[0].mData, channelCount > 0 else { return }
        let interleaved = rawData.assumingMemoryBound(to: Float.self)
        let totalFloats = Int(inputList[0].mDataByteSize) / MemoryLayout<Float>.size
        let frames = totalFloats / channelCount
        guard frames > 0, let scratchBase = scratch.baseAddress else { return }
        let clampedFrames = min(frames, deinterleaveStride)

        for ch in 0..<channelCount {
            let dst = scratchBase.advanced(by: ch * deinterleaveStride)
            var f = 0
            while f < clampedFrames {
                dst[f] = interleaved[f * channelCount + ch]
                f += 1
            }
        }

        withUnsafeTemporaryAllocation(
            of: UnsafePointer<Float>.self,
            capacity: channelCount
        ) { ptrs in
            for ch in 0..<channelCount {
                ptrs[ch] = UnsafePointer(scratchBase.advanced(by: ch * deinterleaveStride))
            }
            guard let base = ptrs.baseAddress else { return }
            _ = ring.write(
                fromChannelPointers: base,
                channelCount: channelCount,
                frames: clampedFrames
            )
        }
    }

    /// Planar / non-interleaved path. Each `inputList` buffer is one
    /// channel; `mDataByteSize` is per-channel, so `frames` is the true
    /// frame count. Hand the per-channel pointers straight to the ring.
    private func pushPlanar(_ inputList: UnsafeMutableAudioBufferListPointer) {
        let bytesPerChannel = Int(inputList[0].mDataByteSize)
        let frames = bytesPerChannel / MemoryLayout<Float>.size
        guard frames > 0 else { return }

        let activeChannels = min(inputList.count, channelCount)
        guard activeChannels > 0 else { return }

        withUnsafeTemporaryAllocation(
            of: UnsafePointer<Float>.self,
            capacity: activeChannels
        ) { scratch in
            var valid = 0
            for ch in 0..<activeChannels {
                guard let raw = inputList[ch].mData else { break }
                scratch[valid] = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
                valid += 1
            }
            guard valid > 0, let base = scratch.baseAddress else { return }
            _ = ring.write(
                fromChannelPointers: base,
                channelCount: valid,
                frames: frames
            )
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
