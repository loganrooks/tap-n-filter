import AVFoundation
import Effects
import Foundation
import Graph
import Presets

/// Command-line ear-test harness.
///
/// Renders an input audio buffer through the bundled `distant-engines` preset
/// using `AVAudioEngine.enableManualRenderingMode(.offline, ...)`. The input
/// is either user-supplied (via `--input <path>`) or a synthetic composite
/// generated in-process when no input is provided.
///
/// See `docs/orchestration/phases/02-dsp-chain.md` section 2.8 and ADR-008.

// MARK: CLI parsing

struct CLIOptions {
    var inputPath: String?
    var outputDirectory: String
    var presetName: String

    static let defaultOutputDirectory: String = "test-artifacts"
    static let defaultPresetName: String = "distant-engines"
}

func parseArguments(_ arguments: [String]) -> CLIOptions {
    var options = CLIOptions(
        inputPath: nil,
        outputDirectory: CLIOptions.defaultOutputDirectory,
        presetName: CLIOptions.defaultPresetName
    )
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--input":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("error: --input requires a path\n".utf8))
                exit(EXIT_FAILURE)
            }
            options.inputPath = arguments[index]
        case "--output":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("error: --output requires a directory\n".utf8))
                exit(EXIT_FAILURE)
            }
            options.outputDirectory = arguments[index]
        case "--preset":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("error: --preset requires a name\n".utf8))
                exit(EXIT_FAILURE)
            }
            options.presetName = arguments[index]
        case "--help", "-h":
            printUsage()
            exit(EXIT_SUCCESS)
        default:
            FileHandle.standardError.write(Data("error: unknown argument '\(argument)'\n".utf8))
            printUsage()
            exit(EXIT_FAILURE)
        }
        index += 1
    }
    return options
}

func printUsage() {
    let usage = """
    tap-n-filter-eartest — offline-render a wav through a bundled preset

    Usage:
      tap-n-filter-eartest [--input <path>] [--output <dir>] [--preset <name>]

    Options:
      --input <path>    Path to a wav file to render. If omitted, a 30-second
                        synthetic composite (pink noise + sine sweep + tones)
                        is generated in-process.
      --output <dir>    Output directory for ear-test-input.wav and
                        ear-test-output.wav. Defaults to test-artifacts/.
      --preset <name>   Bundled preset to use. Defaults to distant-engines.

    See docs/orchestration/phases/02-dsp-chain.md and ADR-008.
    """
    print(usage)
}

// MARK: Buffer loading

func loadBuffer(at path: String) throws -> AVAudioPCMBuffer {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(
            domain: "tap-n-filter-eartest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate input buffer"]
        )
    }
    try file.read(into: buffer)
    return buffer
}

// MARK: Offline render

/// Render `input` through `preset` using offline manual rendering. Returns a
/// freshly-allocated buffer in the input's format.
func renderOffline(
    input: AVAudioPCMBuffer,
    preset: GraphPreset
) throws -> AVAudioPCMBuffer {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = input.format

    engine.attach(player)

    // Build the graph from the preset before attaching, so the chain is
    // ready when attach() wires it in.
    let graph = try Graph.restore(from: preset, using: EffectNodeRegistry.shared)
    if !graph.lastLoadWarnings.isEmpty {
        for warning in graph.lastLoadWarnings {
            print("warning: \(warning)")
        }
    }

    try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)

    // Switch to offline rendering before start. The engine must be stopped
    // (which is the default after attach) for enableManualRenderingMode to
    // succeed.
    let maxFrames: AVAudioFrameCount = 4_096
    try engine.enableManualRenderingMode(
        .offline,
        format: format,
        maximumFrameCount: maxFrames
    )

    try engine.start()
    player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
    player.play()

    // Allocate output buffer big enough to hold the input. Reverb tails
    // outlive the input by a few seconds; the spec calls for the input
    // duration's worth of output (the tail trails off in subsequent buffers
    // we don't render here).
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
        throw NSError(
            domain: "tap-n-filter-eartest",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate render buffer"]
        )
    }

    // Output file is the full length of the input. Reverb tail beyond the
    // input is intentionally discarded; the ear test is about the steady-state
    // chain behaviour over the input's duration.
    let totalFrames = AVAudioFramePosition(input.frameLength)
    guard let collected = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(totalFrames)
    ) else {
        throw NSError(
            domain: "tap-n-filter-eartest",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate collected buffer"]
        )
    }
    collected.frameLength = 0

    var remaining = totalFrames
    while remaining > 0 {
        let frames = AVAudioFrameCount(min(Int64(maxFrames), remaining))
        let status = try engine.renderOffline(frames, to: outputBuffer)
        switch status {
        case .success:
            try appendFrames(from: outputBuffer, to: collected, frameCount: frames)
            remaining -= Int64(frames)
        case .insufficientDataFromInputNode:
            // Player has run out — fill the rest with silence and stop.
            outputBuffer.frameLength = frames
            zeroOut(outputBuffer)
            try appendFrames(from: outputBuffer, to: collected, frameCount: frames)
            remaining -= Int64(frames)
        case .cannotDoInCurrentContext:
            throw NSError(
                domain: "tap-n-filter-eartest",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "renderOffline cannotDoInCurrentContext"]
            )
        case .error:
            throw NSError(
                domain: "tap-n-filter-eartest",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "renderOffline error"]
            )
        @unknown default:
            throw NSError(
                domain: "tap-n-filter-eartest",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "renderOffline unknown status"]
            )
        }
    }

    player.stop()
    engine.stop()
    engine.disableManualRenderingMode()
    graph.detach()

    return collected
}

func appendFrames(
    from source: AVAudioPCMBuffer,
    to destination: AVAudioPCMBuffer,
    frameCount: AVAudioFrameCount
) throws {
    guard let sourceData = source.floatChannelData,
          let destData = destination.floatChannelData
    else {
        throw NSError(
            domain: "tap-n-filter-eartest",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Buffer is not float-format"]
        )
    }
    let channels = Int(source.format.channelCount)
    let offset = Int(destination.frameLength)
    let copyCount = Int(frameCount)
    let available = Int(destination.frameCapacity) - offset
    let toCopy = min(copyCount, available)
    for channel in 0 ..< channels {
        let src = sourceData[channel]
        let dst = destData[channel].advanced(by: offset)
        dst.update(from: src, count: toCopy)
    }
    destination.frameLength = AVAudioFrameCount(offset + toCopy)
}

func zeroOut(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData else { return }
    let channels = Int(buffer.format.channelCount)
    let count = Int(buffer.frameLength)
    for channel in 0 ..< channels {
        data[channel].update(repeating: 0.0, count: count)
    }
}

// MARK: File writing

func writeBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
    // Write 16-bit PCM wav. AVAudioFile decides the file format from the URL
    // extension plus the settings dictionary.
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: buffer.format.sampleRate,
        AVNumberOfChannelsKey: buffer.format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: buffer.format.commonFormat,
        interleaved: buffer.format.isInterleaved
    )
    try file.write(from: buffer)
}

// MARK: Driver

func run() throws {
    let options = parseArguments(CommandLine.arguments)

    // Resolve output directory and ensure it exists.
    let outputDirURL = URL(fileURLWithPath: options.outputDirectory)
    try FileManager.default.createDirectory(
        at: outputDirURL,
        withIntermediateDirectories: true,
        attributes: nil
    )

    // Resolve input buffer.
    let inputBuffer: AVAudioPCMBuffer
    if let path = options.inputPath {
        print("Loading input from \(path)…")
        inputBuffer = try loadBuffer(at: path)
    } else {
        print("No --input provided; generating synthetic test signal (30 s).")
        inputBuffer = SyntheticTestSignal.render()
    }
    let frameRate = inputBuffer.format.sampleRate
    let frameCount = inputBuffer.frameLength
    let durationSeconds = Double(frameCount) / frameRate
    print(String(
        format: "Input: %u frames, %.1f s, %.0f Hz, %u channel(s)",
        frameCount,
        durationSeconds,
        frameRate,
        inputBuffer.format.channelCount
    ))

    // Load preset.
    print("Loading preset '\(options.presetName)' from bundle…")
    let preset = try FactoryPresets.load(named: options.presetName)
    print("Preset: '\(preset.name)' with \(preset.nodes.count) node(s).")

    // Write the input buffer to disk for A/B reference.
    let inputURL = outputDirURL.appendingPathComponent("ear-test-input.wav")
    try writeBuffer(inputBuffer, to: inputURL)
    print("Wrote input to \(inputURL.path)")

    // Render through the graph.
    print("Rendering offline…")
    let outputBuffer = try renderOffline(input: inputBuffer, preset: preset)
    print(String(
        format: "Rendered %u frames (%.1f s).",
        outputBuffer.frameLength,
        Double(outputBuffer.frameLength) / frameRate
    ))

    // Write the rendered output.
    let outputURL = outputDirURL.appendingPathComponent("ear-test-output.wav")
    try writeBuffer(outputBuffer, to: outputURL)
    print("Wrote output to \(outputURL.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ear-test failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
