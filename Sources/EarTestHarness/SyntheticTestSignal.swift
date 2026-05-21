import AVFoundation
import Darwin
import Foundation

/// Errors thrown by `SyntheticTestSignal.render()`.
enum SyntheticTestSignalError: Error {
    /// The combination of sample rate and channel count is not supported by
    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)`.
    case unsupportedFormat(sampleRate: Double, channels: AVAudioChannelCount)
    /// `AVAudioPCMBuffer` returned `nil` for the given frame capacity.
    case bufferAllocationFailed(frameCapacity: AVAudioFrameCount)
    /// `AVAudioPCMBuffer.floatChannelData` was nil on a buffer that was
    /// expected to use float PCM.
    case missingFloatChannelData
}

/// Generates the default 30-second composite test signal used when the user
/// does not pass `--input` to the ear-test harness.
///
/// Composition per ADR-008:
///
/// - 0–10 s: pink noise (broadband content for spectral verification).
/// - 10–20 s: logarithmic sine sweep, 20 Hz to 20 kHz (frequency response).
/// - 20–30 s: test tones at 100 Hz, 1 kHz, and 10 kHz, each 3.333 s long
///   (level verification).
///
/// The signal is stereo (the same content in both channels) at 48 kHz —
/// matching the typical aggregate-device output and avoiding any sample-rate
/// conversion in the offline render.
enum SyntheticTestSignal {

    static let sampleRate: Double = 48_000.0
    static let channelCount: AVAudioChannelCount = 2
    static let totalDuration: Double = 30.0

    /// Render the composite into a freshly-allocated `AVAudioPCMBuffer`.
    ///
    /// Throws `SyntheticTestSignalError` if the format is unsupported, the
    /// buffer cannot be allocated, or `floatChannelData` is unexpectedly nil.
    static func render() throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            throw SyntheticTestSignalError.unsupportedFormat(
                sampleRate: sampleRate,
                channels: channelCount
            )
        }
        let totalFrames = AVAudioFrameCount(sampleRate * totalDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw SyntheticTestSignalError.bufferAllocationFailed(frameCapacity: totalFrames)
        }
        buffer.frameLength = totalFrames

        guard let channelData = buffer.floatChannelData else {
            throw SyntheticTestSignalError.missingFloatChannelData
        }
        let channels = Int(channelCount)

        // Segment 1: pink noise (0–10 s).
        let segmentFrames = Int(sampleRate * 10.0)
        renderPinkNoise(into: channelData, channels: channels, startFrame: 0, frames: segmentFrames)
        // Segment 2: logarithmic sweep (10–20 s).
        renderSineSweep(
            into: channelData,
            channels: channels,
            startFrame: segmentFrames,
            frames: segmentFrames,
            startHz: 20.0,
            endHz: 20_000.0
        )
        // Segment 3: 100 Hz / 1 kHz / 10 kHz tone burst (20–30 s).
        let toneFrames = segmentFrames / 3
        let toneStart = segmentFrames * 2
        renderTone(
            into: channelData,
            channels: channels,
            startFrame: toneStart,
            frames: toneFrames,
            frequency: 100.0
        )
        renderTone(
            into: channelData,
            channels: channels,
            startFrame: toneStart + toneFrames,
            frames: toneFrames,
            frequency: 1_000.0
        )
        renderTone(
            into: channelData,
            channels: channels,
            startFrame: toneStart + toneFrames * 2,
            frames: Int(totalFrames) - (toneStart + toneFrames * 2),
            frequency: 10_000.0
        )

        return buffer
    }

    // MARK: Segment renderers

    private static func renderPinkNoise(
        into channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        startFrame: Int,
        frames: Int
    ) {
        // Voss-McCartney algorithm: sum of N rows where row k updates every
        // 2^k samples. Approximates -3 dB/octave (pink) spectrum. Five rows
        // is the conventional cheap-and-acceptable choice.
        let rows = 5
        var rowValues = [Float](repeating: 0.0, count: rows)
        var lastValue: Float = 0.0
        var rng = SystemRandomNumberGenerator()
        let scale: Float = 0.25 // -12 dBFS to leave headroom before the chain.

        for frame in 0 ..< frames {
            let index = frame + 1 // index 0 would set no row.
            var updateRow = 0
            while updateRow < rows && (index & (1 << updateRow)) == 0 {
                updateRow += 1
            }
            if updateRow < rows {
                let newValue = Float.random(in: -1.0 ... 1.0, using: &rng)
                lastValue += newValue - rowValues[updateRow]
                rowValues[updateRow] = newValue
            }
            // Add one always-changing row to fill in highs.
            let topUp = Float.random(in: -1.0 ... 1.0, using: &rng)
            let sample = ((lastValue + topUp) / Float(rows + 1)) * scale
            for channel in 0 ..< channels {
                channelData[channel][startFrame + frame] = sample
            }
        }
    }

    private static func renderSineSweep(
        into channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        startFrame: Int,
        frames: Int,
        startHz: Double,
        endHz: Double
    ) {
        let duration = Double(frames) / sampleRate
        let scale: Float = 0.25
        // Phase integrates instantaneous frequency. f(t) = f0 * (f1/f0)^(t/T).
        // Phase = integral of 2*pi*f(t) dt = 2*pi*f0*T/ln(ratio) * (ratio^(t/T) - 1)
        let ratio = endHz / startHz
        let lnRatio = log(ratio)
        let coefficient = 2.0 * Double.pi * startHz * duration / lnRatio

        for frame in 0 ..< frames {
            let t = Double(frame) / sampleRate
            let phase = coefficient * (pow(ratio, t / duration) - 1.0)
            let sample = Float(sin(phase)) * scale
            for channel in 0 ..< channels {
                channelData[channel][startFrame + frame] = sample
            }
        }
    }

    private static func renderTone(
        into channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels: Int,
        startFrame: Int,
        frames: Int,
        frequency: Double
    ) {
        let scale: Float = 0.25
        let angularFreq = 2.0 * Double.pi * frequency / sampleRate
        // Apply a 50 ms linear fade-in/out to avoid clicks at segment edges.
        let fadeFrames = min(Int(0.05 * sampleRate), frames / 4)

        for frame in 0 ..< frames {
            var amplitude = scale
            if frame < fadeFrames {
                amplitude *= Float(frame) / Float(fadeFrames)
            } else if frame >= frames - fadeFrames {
                // Fade starts one frame earlier (>=) and the last sample
                // lands at zero: max(frames - 1 - frame, 0) / max(fadeFrames, 1).
                // Without this fix the boundary was `frame > frames - fadeFrames`,
                // which started a frame late and left the final sample non-zero,
                // causing an audible click at segment boundaries.
                amplitude *= Float(max(frames - 1 - frame, 0)) / Float(max(fadeFrames, 1))
            }
            let sample = Float(sin(angularFreq * Double(frame))) * amplitude
            for channel in 0 ..< channels {
                channelData[channel][startFrame + frame] = sample
            }
        }
    }
}
