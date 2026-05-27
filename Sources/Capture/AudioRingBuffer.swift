import Darwin
import Foundation
import os

/// Single-producer / single-consumer ring buffer for non-interleaved
/// Float32 audio.
///
/// `write` is the only call site that advances the head pointer and is
/// called from the Core Audio IOProc thread; `read` is the only call site
/// that advances the tail pointer and is called from the AVAudioEngine
/// render thread. Internal state is protected by a single
/// `OSAllocatedUnfairLock` — the critical sections are bounded
/// `update(from:count:)` copies, so the lock-vs-lock-free distinction is
/// not measurable at this audio rate (HFPSpike's experience). V0.2 may
/// upgrade to a true lock-free SPSC if measured glitches require it.
///
/// Buffer layout: one `UnsafeMutableBufferPointer<Float>` per channel.
/// This matches AVAudioEngine's standard internal format, so the
/// IOProc-side write and the SourceNode-side read both operate on the
/// same shape and no per-frame de/interleaving is needed.
@available(macOS 14.4, *)
public final class AudioRingBuffer: @unchecked Sendable {
    /// Number of audio channels the buffer can carry. Fixed at init.
    public let channelCount: Int

    /// Capacity in frames per channel. Fixed at init.
    public let capacity: Int

    private struct State {
        var head: Int = 0
        var tail: Int = 0
        var fill: Int = 0
    }

    private var channels: [UnsafeMutableBufferPointer<Float>]
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Allocates per-channel storage of `capacity` Float frames each. The
    /// storage is zero-initialised so a read before any write returns
    /// silence rather than uninitialised memory if the caller treats a
    /// short read as silence at the tail.
    public init(channelCount: Int, capacity: Int) {
        precondition(channelCount > 0, "channelCount must be positive")
        precondition(capacity > 0, "capacity must be positive")
        self.channelCount = channelCount
        self.capacity = capacity
        self.channels = (0..<channelCount).map { _ in
            let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
            buf.initialize(repeating: 0)
            return buf
        }
    }

    deinit {
        for buf in channels {
            buf.deallocate()
        }
    }

    /// Producer side. Writes up to `frames` frames of `sources` into the
    /// ring. Returns the number actually written; less than `frames` if
    /// the ring would overflow, zero if the ring is full. Real-time safe.
    ///
    /// `sources.count` may be less than `channelCount`; only the
    /// overlapping channels are written. Extra channels in `sources`
    /// beyond `channelCount` are ignored.
    ///
    /// Array overload kept for ergonomic test fixtures; the real-time
    /// IOProc path uses the pointer-based overload to avoid allocating.
    @discardableResult
    public func write(from sources: [UnsafePointer<Float>], frames: Int) -> Int {
        sources.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return write(fromChannelPointers: base, channelCount: buf.count, frames: frames)
        }
    }

    /// Pointer-based producer overload. The IOProc thread uses this
    /// variant with `withUnsafeTemporaryAllocation` for the source-
    /// pointer scratch so the hot path doesn't construct a Swift `Array`
    /// (which would allocate and run ARC on every callback). Real-time
    /// safe.
    @discardableResult
    public func write(
        fromChannelPointers sources: UnsafePointer<UnsafePointer<Float>>,
        channelCount sourceChannelCount: Int,
        frames: Int
    ) -> Int {
        guard frames > 0 else { return 0 }
        return lock.withLockUnchecked { state -> Int in
            let available = capacity - state.fill
            let toWrite = min(frames, available)
            guard toWrite > 0 else { return 0 }

            let firstChunk = min(toWrite, capacity - state.head)
            let secondChunk = toWrite - firstChunk
            let writableChannels = min(channelCount, sourceChannelCount)
            for ch in 0..<writableChannels {
                let src = sources[ch]
                let dest = channels[ch].baseAddress!
                dest.advanced(by: state.head).update(from: src, count: firstChunk)
                if secondChunk > 0 {
                    dest.update(from: src.advanced(by: firstChunk), count: secondChunk)
                }
            }
            state.head = (state.head + toWrite) % capacity
            state.fill += toWrite
            return toWrite
        }
    }

    /// Consumer side. Reads up to `frames` frames into `dests`. Returns
    /// the number actually read; less than `frames` on underrun. Caller
    /// zero-fills the tail and reports silence in that case. Real-time
    /// safe.
    ///
    /// `dests.count` may be less than `channelCount`; only the
    /// overlapping channels are read into. Extra channels in `dests`
    /// beyond `channelCount` are left untouched.
    ///
    /// Array overload kept for ergonomic test fixtures; the real-time
    /// SourceNode render path uses the pointer-based overload.
    @discardableResult
    public func read(into dests: [UnsafeMutablePointer<Float>], frames: Int) -> Int {
        dests.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return read(intoChannelPointers: base, channelCount: buf.count, frames: frames)
        }
    }

    /// Pointer-based consumer overload. The AVAudioSourceNode render
    /// callback uses this variant with `withUnsafeTemporaryAllocation`
    /// for the destination-pointer scratch so the hot path doesn't
    /// allocate. Real-time safe.
    @discardableResult
    public func read(
        intoChannelPointers dests: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount destChannelCount: Int,
        frames: Int
    ) -> Int {
        guard frames > 0 else { return 0 }
        return lock.withLockUnchecked { state -> Int in
            let toRead = min(frames, state.fill)
            guard toRead > 0 else { return 0 }

            let firstChunk = min(toRead, capacity - state.tail)
            let secondChunk = toRead - firstChunk
            let readableChannels = min(channelCount, destChannelCount)
            for ch in 0..<readableChannels {
                let dst = dests[ch]
                let src = channels[ch].baseAddress!
                dst.update(from: src.advanced(by: state.tail), count: firstChunk)
                if secondChunk > 0 {
                    dst.advanced(by: firstChunk).update(from: src, count: secondChunk)
                }
            }
            state.tail = (state.tail + toRead) % capacity
            state.fill -= toRead
            return toRead
        }
    }

    /// Number of frames currently available to read. Snapshot only; the
    /// value can be stale by the time the caller acts on it. Useful for
    /// diagnostics and tests; not used on the real-time path.
    public var fillCount: Int {
        lock.withLockUnchecked { $0.fill }
    }
}
