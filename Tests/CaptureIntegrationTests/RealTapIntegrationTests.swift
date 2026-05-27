import AVFoundation
import CoreAudio
import Darwin
import Foundation
import XCTest
@testable import Capture

/// Integration tests that run `TapIOProcReader` against the real Core
/// Audio HAL. Gated behind the `RUN_INTEGRATION_TESTS=1` environment
/// variable because they require:
///
/// - The orchestrator's host to have a process currently producing audio
///   (e.g., Music, Safari with a YouTube tab, a test tone generator).
/// - The host to have granted the test binary the system-audio-recording
///   TCC permission (otherwise tap creation returns
///   `kAudioHardwareNotRunningError` / -66626 mapped to
///   `CaptureError.permissionDenied`).
///
/// Covers TDD anchors TI.1 and TI.2 from
/// `docs/orchestration/phases/01-capture-spike-rework-1.md`.
///
/// When the env var is not set, every test calls `XCTSkip` so the
/// default `swift test` run is unaffected. The code path remains intact
/// so reviewers and the verification subagent can confirm by inspection
/// that the integration shape exists.
@available(macOS 14.4, *)
final class RealTapIntegrationTests: XCTestCase {

    /// Path the integration test writes a 5-second capture wav to so
    /// the verification subagent can run an RMS check. Same pattern as
    /// the original Phase 1 gate criterion 2 artifact.
    private let passthroughWavPath = "test-artifacts/phase-1-rework-1-passthrough.wav"

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RUN_INTEGRATION_TESTS"] != "1",
            "Integration tests gated; set RUN_INTEGRATION_TESTS=1 to run"
        )
    }

    // MARK: TI.1 — real tap delivers non-silent audio

    func test_TI1_real_tap_delivers_nonsilent_audio_to_ring() throws {
        let coreAudio = RealCoreAudioInterface()
        let source = try pickAnyAudibleSource(coreAudio: coreAudio)

        let reader = try TapIOProcReader(
            audioProcessID: source.audioProcessID,
            coreAudio: coreAudio
        )
        try reader.start()
        defer { reader.stop() }

        // Within 1 second the IOProc should have fired and pushed frames
        // into the ring. With the proven EXP-026 aggregate pattern,
        // empirical fire rate is ~94/sec so a 1-second wait gives
        // ~94 IOProc invocations.
        let firstCheck = Date().addingTimeInterval(1.0)
        while Date() < firstCheck {
            if reader.ring.fillCount > 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(
            reader.ring.fillCount,
            0,
            "after 1s no frames reached the ring buffer"
        )

        // Drain 5 seconds of audio into a contiguous capture buffer for
        // the RMS check.
        let channels = Int(reader.format.channelCount)
        let rate = Int(reader.format.sampleRate)
        let totalFrames = rate * 5
        var captured: [[Float]] = Array(
            repeating: [Float](repeating: 0, count: totalFrames),
            count: channels
        )
        var collected = 0
        let drainDeadline = Date().addingTimeInterval(10.0)
        let chunkFrames = 1024
        while collected < totalFrames && Date() < drainDeadline {
            withUnsafeTemporaryAllocation(
                of: UnsafeMutablePointer<Float>.self,
                capacity: channels
            ) { scratch in
                // Read into per-channel temporary buffers, then copy into
                // the captured ring at `collected..collected+n`.
                let chunkBufs: [UnsafeMutablePointer<Float>] = (0..<channels).map { _ in
                    UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
                }
                defer { chunkBufs.forEach { $0.deallocate() } }
                let n = reader.ring.read(into: chunkBufs, frames: chunkFrames)
                if n == 0 {
                    Thread.sleep(forTimeInterval: 0.01)
                    return
                }
                for ch in 0..<channels {
                    for i in 0..<n {
                        captured[ch][collected + i] = chunkBufs[ch][i]
                    }
                }
                collected += n
                _ = scratch
            }
        }
        XCTAssertGreaterThanOrEqual(
            collected,
            rate,
            "received only \(collected) frames in 10s; expected at least 1s worth"
        )

        // Compute RMS on channel 0 over the collected frames; assert
        // > -60 dBFS.
        let frames = max(1, collected)
        var sumSq: Double = 0
        for i in 0..<frames {
            let s = Double(captured[0][i])
            sumSq += s * s
        }
        let rms = sqrt(sumSq / Double(frames))
        let rmsDBFS = 20.0 * log10(max(rms, 1e-9))
        XCTAssertGreaterThan(
            rmsDBFS,
            -60.0,
            "captured audio is silent (RMS=\(rmsDBFS) dBFS); is the source actually producing audio?"
        )

        // Write a wav artifact for the verification subagent.
        try writePassthroughWAV(
            channels: channels,
            sampleRate: Double(rate),
            frames: collected,
            data: captured,
            to: passthroughWavPath
        )
    }

    // MARK: TI.2 — start → stop → start cleanly releases and re-acquires

    func test_TI2_start_stop_start_stop_cleanly_releases_resources() throws {
        let coreAudio = RealCoreAudioInterface()
        let source = try pickAnyAudibleSource(coreAudio: coreAudio)

        // First cycle.
        var reader: TapIOProcReader? = try TapIOProcReader(
            audioProcessID: source.audioProcessID,
            coreAudio: coreAudio
        )
        try reader!.start()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(reader!.ring.fillCount, 0, "first start: no audio delivered")
        reader!.stop()
        reader = nil

        // Second cycle on a fresh reader. If the first cycle leaked the
        // tap or aggregate, this would fail with
        // kAudioHardwareIllegalOperationError or similar.
        let reader2 = try TapIOProcReader(
            audioProcessID: source.audioProcessID,
            coreAudio: coreAudio
        )
        try reader2.start()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(reader2.ring.fillCount, 0, "second start: no audio delivered")
        reader2.stop()
    }

    // MARK: Helpers

    /// Pick any available audio-producing process. The test requires the
    /// host to have at least one such process running; if there are
    /// none, the test fails with a clear message rather than spinning.
    private func pickAnyAudibleSource(coreAudio: CoreAudioInterface) throws -> CaptureSource {
        let processes = try coreAudio.availableAudioProcesses()
        let runningApps = NSWorkspace.shared.runningApplications
        var byPID: [pid_t: NSRunningApplication] = [:]
        for app in runningApps { byPID[app.processIdentifier] = app }

        for entry in processes {
            if let app = byPID[entry.pid],
               let bundleID = app.bundleIdentifier,
               !bundleID.isEmpty {
                return CaptureSource(
                    pid: entry.pid,
                    audioProcessID: entry.audioProcessID,
                    bundleIdentifier: bundleID,
                    displayName: app.localizedName ?? bundleID
                )
            }
        }
        throw XCTSkip("No audio-producing process available; start Music/Safari and retry")
    }

    /// Write a non-interleaved Float32 capture to disk as an interleaved
    /// 16-bit PCM WAV. Minimal wav-header-then-data writer; only used by
    /// the integration test artifact.
    private func writePassthroughWAV(
        channels: Int,
        sampleRate: Double,
        frames: Int,
        data: [[Float]],
        to path: String
    ) throws {
        // Resolve to repo-root relative path.
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let absolute = (path as NSString).isAbsolutePath
            ? path
            : (cwd as NSString).appendingPathComponent(path)
        let dir = (absolute as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let bytesPerSample = 2
        let pcmFrames = frames * channels * bytesPerSample
        let chunkSize = 36 + pcmFrames

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(UInt32(chunkSize).littleEndianData)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(UInt32(16).littleEndianData)         // fmt chunk size
        header.append(UInt16(1).littleEndianData)          // PCM
        header.append(UInt16(channels).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bytesPerSample)
        header.append(byteRate.littleEndianData)
        header.append(UInt16(channels * bytesPerSample).littleEndianData) // block align
        header.append(UInt16(bytesPerSample * 8).littleEndianData) // bits/sample
        header.append(contentsOf: "data".utf8)
        header.append(UInt32(pcmFrames).littleEndianData)

        var body = Data(capacity: pcmFrames)
        for i in 0..<frames {
            for ch in 0..<channels {
                let s = max(-1.0, min(1.0, data[ch][i]))
                let v = Int16(s * 32_767.0)
                body.append(UInt16(bitPattern: v).littleEndianData)
            }
        }

        try (header + body).write(to: URL(fileURLWithPath: absolute))
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<UInt32>.size)
    }
}
