import AVFoundation
import AppKit
import Capture
import Combine
import Effects
import Foundation
import Graph
import Presets
import ViewModel

/// Closed-loop probe for the live `powerOn` flow.
///
/// Why: iterating on the audio chain via "build → install .app → user
/// presses Power → user pastes pill text" takes minutes per cycle. The
/// probe drives the same `AppViewModel.powerOn` path the GUI does, then
/// dumps every log entry the in-app debug store captured. Run it from
/// the CLI and read the result directly:
///
///     swift run tap-n-filter-poweron-probe --bundle-id com.apple.Safari
///
/// The probe is meant for developers debugging the capture path. It is
/// not part of the shipped V0.1.0 binary — `Package.swift` adds it as
/// an executable target alongside the existing
/// `tap-n-filter-a11y-dump`, not as a library product.
///
/// Prerequisites: the user has already granted audio-capture permission
/// (the probe surfaces a typed error if not), and the target source app
/// is running and producing audio. Without those, the probe still exits
/// cleanly and the dump explains why.

@MainActor
func runProbe() async {
    let args = CommandLine.arguments
    let bundleID = parseBundleID(from: args)
    let waitSeconds = parseWait(from: args)

    print("==== tap-n-filter-poweron-probe ====")
    print("target bundle id : \(bundleID ?? "<first available>")")
    print("wait seconds     : \(waitSeconds)")
    print()

    // Fresh UserDefaults suite so the probe is independent of the
    // user's persisted state — otherwise a saved bad graph or stale
    // source bundle ID could mask the bug we're hunting.
    let suiteName = "tnf.poweronprobe.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fputs("error: could not create UserDefaults suite\n", stderr)
        exit(1)
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let capture = CaptureController(coreAudio: RealCoreAudioInterface())
    let engine = AVAudioEngine()
    let viewModel = AppViewModel(
        capture: capture,
        engine: engine,
        registry: EffectNodeRegistry.shared,
        defaults: defaults
    )

    // Make sure source enumeration kicks off and lands.
    viewModel.refreshAvailableSources()
    try? await Task.sleep(nanoseconds: 500_000_000)
    print("--- enumerated sources (\(viewModel.availableSources.count)) ---")
    for source in viewModel.availableSources {
        print("  \(source.displayName)  (\(source.bundleIdentifier ?? "no bundle id"), pid=\(source.pid))")
    }
    print()

    let candidate: CaptureSource?
    if let bundleID {
        candidate = viewModel.availableSources.first { $0.bundleIdentifier == bundleID }
    } else {
        candidate = viewModel.availableSources.first
    }
    guard let source = candidate else {
        fputs("error: no source matched bundle id '\(bundleID ?? "(any)")'\n", stderr)
        dumpDebugLog(viewModel)
        exit(2)
    }
    print("--- selected source ---")
    print("  \(source.displayName)  (\(source.bundleIdentifier ?? "no bundle id"), pid=\(source.pid))")
    print()

    viewModel.setSource(source)
    print("--- powerOn ---")
    await viewModel.powerOn()
    print("captureState after powerOn: \(viewModel.captureState)")
    if let error = viewModel.lastError {
        print("lastError: \(error.userMessage)")
    }
    print()

    // Let the engine settle (and any async log messages flush).
    try? await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
    print("--- captureState after \(waitSeconds)s wait ---")
    print("captureState: \(viewModel.captureState)")
    print()

    print("--- engine state ---")
    print("engine.isRunning   : \(engine.isRunning)")
    let inputFormat = engine.inputNode.inputFormat(forBus: 0)
    let outputFormat = engine.outputNode.outputFormat(forBus: 0)
    print("inputNode.inputFormat : \(inputFormat.sampleRate) Hz × \(inputFormat.channelCount) ch (\(inputFormat.commonFormatDescription))")
    print("outputNode.outputFormat: \(outputFormat.sampleRate) Hz × \(outputFormat.channelCount) ch (\(outputFormat.commonFormatDescription))")
    print()

    dumpDebugLog(viewModel)

    print("--- powerOff ---")
    await viewModel.powerOff()
    print("captureState after powerOff: \(viewModel.captureState)")
}

@MainActor
func dumpDebugLog(_ viewModel: AppViewModel) {
    let entries = viewModel.debugLog.entries.reversed()
    print("--- debug log (\(viewModel.debugLog.entries.count) entries, oldest first) ---")
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    for entry in entries {
        let stamp = formatter.string(from: entry.timestamp)
        print("[\(stamp)] [\(entry.level.rawValue.uppercased())] \(entry.source): \(entry.message)")
    }
    print()
}

func parseBundleID(from args: [String]) -> String? {
    guard let index = args.firstIndex(of: "--bundle-id"),
          index + 1 < args.count
    else {
        return nil
    }
    return args[index + 1]
}

func parseWait(from args: [String]) -> Int {
    guard let index = args.firstIndex(of: "--wait"),
          index + 1 < args.count,
          let seconds = Int(args[index + 1])
    else {
        return 3
    }
    return max(1, min(seconds, 30))
}

private extension AVAudioFormat {
    var commonFormatDescription: String {
        switch commonFormat {
        case .pcmFormatFloat32: return isInterleaved ? "Float32 interleaved" : "Float32 deinterleaved"
        case .pcmFormatFloat64: return "Float64"
        case .pcmFormatInt16: return "Int16"
        case .pcmFormatInt32: return "Int32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }
}

// AppKit needs an NSApplication instance up before any AVFoundation
// activity that touches output devices on the main thread.
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await runProbe()
    semaphore.signal()
}
// Spin the runloop while the probe runs so AVFoundation publishers
// and Combine subscriptions fire.
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}
