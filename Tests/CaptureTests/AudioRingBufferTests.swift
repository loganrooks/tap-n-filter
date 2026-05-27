import Darwin
import XCTest
@testable import Capture

/// Unit tests for `AudioRingBuffer`. The tests are framed in terms of the
/// public surface (write / read / fillCount) and the TDD anchors T1.1
/// through T1.8 from `docs/orchestration/phases/01-capture-spike-rework-1.md`.
@available(macOS 14.4, *)
final class AudioRingBufferTests: XCTestCase {

    // MARK: Helpers

    /// Allocate a per-channel buffer filled with a known pattern. Useful
    /// to verify that read returns the same values write put in. The
    /// caller is responsible for deallocating each buffer.
    private func makeChannels(_ count: Int, frames: Int, baseValue: Float) -> [UnsafeMutablePointer<Float>] {
        (0..<count).map { ch in
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames {
                buf[i] = baseValue + Float(ch * frames + i)
            }
            return buf
        }
    }

    private func emptyChannels(_ count: Int, frames: Int) -> [UnsafeMutablePointer<Float>] {
        (0..<count).map { _ in
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buf.initialize(repeating: -1, count: frames)
            return buf
        }
    }

    private func free(_ ptrs: [UnsafeMutablePointer<Float>]) {
        for p in ptrs { p.deallocate() }
    }

    // MARK: T1.1

    func test_empty_ring_read_returns_zero_no_zero_fill() {
        let ring = AudioRingBuffer(channelCount: 2, capacity: 1024)
        let dests = emptyChannels(2, frames: 64)
        defer { free(dests) }

        let readFrames = ring.read(
            into: dests.map { UnsafeMutablePointer<Float>($0) },
            frames: 64
        )
        XCTAssertEqual(readFrames, 0)
        // The caller-supplied destination buffers must NOT have been
        // touched: we initialised them to -1 above; if the ring wrote
        // anything (including zero-fill), this assertion catches it.
        for d in dests {
            for i in 0..<64 {
                XCTAssertEqual(d[i], -1, "ring zero-filled or wrote outside its contract")
            }
        }
    }

    // MARK: T1.2

    func test_write_N_read_N_identical_samples() {
        let frames = 128
        let ring = AudioRingBuffer(channelCount: 2, capacity: 512)
        let sources = makeChannels(2, frames: frames, baseValue: 100)
        defer { free(sources) }

        let written = ring.write(
            from: sources.map { UnsafePointer($0) },
            frames: frames
        )
        XCTAssertEqual(written, frames)

        let dests = emptyChannels(2, frames: frames)
        defer { free(dests) }
        let readBack = ring.read(
            into: dests.map { UnsafeMutablePointer($0) },
            frames: frames
        )
        XCTAssertEqual(readBack, frames)

        for ch in 0..<2 {
            for i in 0..<frames {
                XCTAssertEqual(dests[ch][i], sources[ch][i], "channel \(ch) frame \(i)")
            }
        }
    }

    // MARK: T1.3

    func test_write_2N_at_capacity_N_truncates_at_N_then_returns_zero() {
        let capacity = 256
        let ring = AudioRingBuffer(channelCount: 2, capacity: capacity)
        let sources = makeChannels(2, frames: 2 * capacity, baseValue: 0)
        defer { free(sources) }

        let firstWrite = ring.write(
            from: sources.map { UnsafePointer($0) },
            frames: 2 * capacity
        )
        XCTAssertEqual(firstWrite, capacity, "first write must truncate at capacity")
        XCTAssertEqual(ring.fillCount, capacity)

        let secondWrite = ring.write(
            from: sources.map { UnsafePointer($0) },
            frames: capacity
        )
        XCTAssertEqual(secondWrite, 0, "second write must return 0 when ring is full")
    }

    // MARK: T1.4

    func test_wrap_around_write_N_read_half_write_half_reads_back_full_N() {
        // Capacity equals N, so the second half-write wraps the head.
        let capacity = 256
        let ring = AudioRingBuffer(channelCount: 1, capacity: capacity)
        let firstBatch = makeChannels(1, frames: capacity, baseValue: 1)
        let secondBatch = makeChannels(1, frames: capacity / 2, baseValue: 1000)
        defer {
            free(firstBatch)
            free(secondBatch)
        }

        XCTAssertEqual(
            ring.write(from: firstBatch.map { UnsafePointer($0) }, frames: capacity),
            capacity
        )

        let halfDests = emptyChannels(1, frames: capacity / 2)
        defer { free(halfDests) }
        XCTAssertEqual(
            ring.read(
                into: halfDests.map { UnsafeMutablePointer($0) },
                frames: capacity / 2
            ),
            capacity / 2
        )
        // After: ring has capacity/2 frames from firstBatch (the second half).
        XCTAssertEqual(ring.fillCount, capacity / 2)

        // Now write capacity/2 frames from secondBatch — head wraps around 0.
        XCTAssertEqual(
            ring.write(from: secondBatch.map { UnsafePointer($0) }, frames: capacity / 2),
            capacity / 2
        )
        XCTAssertEqual(ring.fillCount, capacity)

        // Read all N back: first half is the second half of firstBatch, second
        // half is secondBatch.
        let fullDests = emptyChannels(1, frames: capacity)
        defer { free(fullDests) }
        XCTAssertEqual(
            ring.read(
                into: fullDests.map { UnsafeMutablePointer($0) },
                frames: capacity
            ),
            capacity
        )
        for i in 0..<(capacity / 2) {
            XCTAssertEqual(fullDests[0][i], firstBatch[0][i + capacity / 2])
        }
        for i in 0..<(capacity / 2) {
            XCTAssertEqual(fullDests[0][i + capacity / 2], secondBatch[0][i])
        }
    }

    // MARK: T1.5

    func test_write_N_read_Nplus1_returns_N_then_next_read_returns_zero() {
        let frames = 64
        let ring = AudioRingBuffer(channelCount: 1, capacity: 256)
        let sources = makeChannels(1, frames: frames, baseValue: 5)
        defer { free(sources) }

        ring.write(from: sources.map { UnsafePointer($0) }, frames: frames)

        let dests = emptyChannels(1, frames: frames + 1)
        defer { free(dests) }
        let read = ring.read(
            into: dests.map { UnsafeMutablePointer($0) },
            frames: frames + 1
        )
        XCTAssertEqual(read, frames)
        // The (frames+1)th destination slot must not have been written
        // because the ring delivered only `frames` samples.
        XCTAssertEqual(dests[0][frames], -1)

        // Next read returns 0 — ring is now empty.
        let dests2 = emptyChannels(1, frames: 8)
        defer { free(dests2) }
        XCTAssertEqual(
            ring.read(
                into: dests2.map { UnsafeMutablePointer($0) },
                frames: 8
            ),
            0
        )
    }

    // MARK: T1.6

    func test_multi_channel_per_channel_write_read_does_not_cross_channels() {
        let frames = 32
        let ring = AudioRingBuffer(channelCount: 2, capacity: 128)

        // Channel 0: ramp from 0..frames-1. Channel 1: 1000..(1000+frames-1).
        let ch0 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let ch1 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            ch0.deallocate()
            ch1.deallocate()
        }
        for i in 0..<frames {
            ch0[i] = Float(i)
            ch1[i] = Float(1000 + i)
        }

        ring.write(from: [UnsafePointer(ch0), UnsafePointer(ch1)], frames: frames)

        let dch0 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let dch1 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            dch0.deallocate()
            dch1.deallocate()
        }
        dch0.initialize(repeating: -1, count: frames)
        dch1.initialize(repeating: -1, count: frames)

        XCTAssertEqual(ring.read(into: [dch0, dch1], frames: frames), frames)
        for i in 0..<frames {
            XCTAssertEqual(dch0[i], Float(i), "ch0 leaked at frame \(i)")
            XCTAssertEqual(dch1[i], Float(1000 + i), "ch1 leaked at frame \(i)")
        }
    }

    // MARK: T1.7

    func test_concurrent_producer_and_consumer_one_second_at_48khz_two_channels() {
        // Real-world shape: 48 kHz × 2 ch for 1 second. The ring has 2s
        // headroom, so a perfectly-paced producer never overflows. The
        // consumer drains in chunks of typical AVAudioEngine frame counts
        // (~1024) so the test exercises the same partial-read / wrap
        // path the real render callback hits.
        let sampleRate = 48_000
        let channelCount = 2
        let secondsToRun = 1
        let ring = AudioRingBuffer(channelCount: channelCount, capacity: sampleRate * 2)

        // Per-channel test pattern: ramp 0..(N-1) repeating, so the
        // consumer can validate ordering by checking that successive
        // reads return a strictly monotonic sequence modulo N.
        let chunkFrames = 480 // 10 ms at 48 kHz, a realistic IOProc chunk
        let totalFrames = sampleRate * secondsToRun
        let chunkCount = totalFrames / chunkFrames

        let producer = DispatchQueue(label: "tnf.test.ring.producer")
        let consumer = DispatchQueue(label: "tnf.test.ring.consumer")
        let producerDone = expectation(description: "producer done")
        let consumerDone = expectation(description: "consumer done")

        // Producer: write chunkCount ramps of chunkFrames each, sleeping
        // ~10 ms between chunks to roughly mimic an IOProc cadence.
        producer.async {
            var sequence: Float = 0
            let ch0 = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
            let ch1 = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
            defer {
                ch0.deallocate()
                ch1.deallocate()
            }
            for _ in 0..<chunkCount {
                for i in 0..<chunkFrames {
                    ch0[i] = sequence
                    ch1[i] = sequence + 100_000 // distinguish channel
                    sequence += 1
                }
                var written = 0
                while written < chunkFrames {
                    let n = ring.write(
                        from: [
                            UnsafePointer(ch0.advanced(by: written)),
                            UnsafePointer(ch1.advanced(by: written)),
                        ],
                        frames: chunkFrames - written
                    )
                    written += n
                    if n == 0 {
                        // Ring full; let consumer drain a bit.
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            producerDone.fulfill()
        }

        // Consumer: drain chunkFrames at a time, verifying monotonicity.
        consumer.async {
            var nextExpected: Float = 0
            var framesRead = 0
            let dch0 = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
            let dch1 = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
            defer {
                dch0.deallocate()
                dch1.deallocate()
            }
            let deadline = Date().addingTimeInterval(5.0)
            while framesRead < totalFrames && Date() < deadline {
                let n = ring.read(into: [dch0, dch1], frames: chunkFrames)
                if n == 0 {
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }
                for i in 0..<n {
                    XCTAssertEqual(dch0[i], nextExpected, "ch0 out of order at frame \(framesRead + i)")
                    XCTAssertEqual(dch1[i], nextExpected + 100_000, "ch1 out of order at frame \(framesRead + i)")
                    nextExpected += 1
                }
                framesRead += n
            }
            XCTAssertEqual(framesRead, totalFrames, "consumer did not drain all frames within deadline")
            consumerDone.fulfill()
        }

        wait(for: [producerDone, consumerDone], timeout: 10.0)
    }

    // MARK: T1.8

    func test_zero_frame_write_and_read_are_noops_returning_zero() {
        let ring = AudioRingBuffer(channelCount: 1, capacity: 256)
        let src = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer {
            src.deallocate()
            dst.deallocate()
        }
        src.initialize(to: 42)
        dst.initialize(to: -1)

        XCTAssertEqual(ring.write(from: [UnsafePointer(src)], frames: 0), 0)
        XCTAssertEqual(ring.fillCount, 0)
        XCTAssertEqual(ring.read(into: [dst], frames: 0), 0)
        // Caller-supplied destination must not have been touched.
        XCTAssertEqual(dst[0], -1)
    }
}
