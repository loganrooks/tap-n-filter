// EXP-037-R race-signal probe (read-only instrumentation).
//
// Purpose: measure, on-device, which Core Audio signal discriminates
//   (Y) "Bluetooth device is merely playing A2DP output" — mitigation SHOULD engage
// from
//   (Z) "Bluetooth microphone is actively in use by a real call/recording" — mitigation SHOULD decline.
//
// The shipped guard (DefaultInputGuard.engageIfNeeded) gates its race check on
// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default-input device.
// Codex review (PR #20, finding #3) argues that property is true whenever the
// device is running for ANY reason — including output playback — so on a single
// Bluetooth device that is both default input and default output, normal capture
// (music already playing) would always read "busy" and the mitigation would never
// engage in its primary scenario. This probe tests that claim and evaluates
// candidate replacement signals. It is INSTRUMENTATION: it never changes app
// behavior. The optional `--measure-write` mode (Codex finding #4) is the only
// part that mutates system state, and it restores the prior default input.
//
// Build:  swiftc -O -framework CoreAudio -o /tmp/exp037probe \
//             docs/investigations/probes/exp037_race_signal.swift
// Run:    /tmp/exp037probe "<condition-label>"          # read-only signal dump
//         /tmp/exp037probe "<condition-label>" --measure-write   # also times a set→readback→restore
//
// See docs/investigations/2026-05-audio-pipeline.md, EXP-037-R.

import CoreAudio
import Foundation

// MARK: - Generic HAL helpers

func addr(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
    var local = a
    return AudioObjectHasProperty(obj, &local)
}

func readScalar<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, default fallback: T) -> (T, OSStatus) {
    var local = a
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(obj, &local, 0, nil, &size, &value)
    return (value, status)
}

func readString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> String? {
    var local = a
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(obj, &local, 0, nil, &size, &cf)
    guard status == noErr, let cf else { return nil }
    return cf.takeRetainedValue() as String
}

func readObjectArray(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var local = a
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &local, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(obj, &local, 0, nil, &dataSize, &ids) == noErr else { return [] }
    return ids
}

func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var local = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &local, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &local, 0, nil, &dataSize, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportName(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypePCI: return "PCI"
    case kAudioDeviceTransportTypeUnknown: return "Unknown"
    default: return "0x" + String(t, radix: 16)
    }
}

func isBluetooth(_ t: UInt32) -> Bool {
    t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Per-device facts

struct DeviceFacts {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let inChannels: Int
    let outChannels: Int
    let nominalRate: Double
    let isRunning: Bool             // kAudioDevicePropertyDeviceIsRunning (global)
    let isRunningSomewhere: Bool    // kAudioDevicePropertyDeviceIsRunningSomewhere (global)
    let isRunningSomewhereInput: Bool?  // same, input scope (nil = property absent on input scope)
}

func deviceFacts(_ id: AudioDeviceID) -> DeviceFacts {
    let uid = readString(id, addr(kAudioDevicePropertyDeviceUID)) ?? "?"
    let name = readString(id, addr(kAudioObjectPropertyName)) ?? "?"
    let (transport, _) = readScalar(id, addr(kAudioDevicePropertyTransportType), default: UInt32(0))
    let (rate, _) = readScalar(id, addr(kAudioDevicePropertyNominalSampleRate), default: Double(0))
    let (running, _) = readScalar(id, addr(kAudioDevicePropertyDeviceIsRunning), default: UInt32(0))
    let (somewhere, _) = readScalar(id, addr(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(0))
    let inputScopeAddr = addr(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeInput)
    var somewhereInput: Bool?
    if has(id, inputScopeAddr) {
        let (v, st) = readScalar(id, inputScopeAddr, default: UInt32(0))
        somewhereInput = (st == noErr) ? (v != 0) : nil
    }
    return DeviceFacts(
        id: id,
        uid: uid,
        name: name,
        transport: transport,
        inChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
        outChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
        nominalRate: rate,
        isRunning: running != 0,
        isRunningSomewhere: somewhere != 0,
        isRunningSomewhereInput: somewhereInput
    )
}

// MARK: - Per-process facts

struct ProcessFacts {
    let id: AudioObjectID
    let pid: Int32
    let bundleID: String
    let isRunning: Bool
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let inputDeviceUIDs: [String]
}

func processList() -> [AudioObjectID] {
    readObjectArray(systemObject, addr(kAudioHardwarePropertyProcessObjectList))
}

func processFacts(_ id: AudioObjectID) -> ProcessFacts {
    let (pid, _) = readScalar(id, addr(kAudioProcessPropertyPID), default: Int32(-1))
    let bundle = readString(id, addr(kAudioProcessPropertyBundleID)) ?? "?"
    let (running, _) = readScalar(id, addr(kAudioProcessPropertyIsRunning), default: UInt32(0))
    let (runIn, _) = readScalar(id, addr(kAudioProcessPropertyIsRunningInput), default: UInt32(0))
    let (runOut, _) = readScalar(id, addr(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))
    let inputDevices = readObjectArray(id, addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput))
    let uids = inputDevices.map { readString($0, addr(kAudioDevicePropertyDeviceUID)) ?? "?" }
    return ProcessFacts(
        id: id,
        pid: pid,
        bundleID: bundle,
        isRunning: running != 0,
        isRunningInput: runIn != 0,
        isRunningOutput: runOut != 0,
        inputDeviceUIDs: uids
    )
}

// MARK: - Optional write-latency measurement (Codex finding #4)

/// Set→readback→restore the default input, polling the readback with timestamps,
/// to measure whether the HAL write is synchronous or needs polling. Restores the
/// prior default input before returning. Only runs with `--measure-write`.
func measureWriteLatency(allInputs: [DeviceFacts], currentInputID: AudioDeviceID) {
    print("--- WRITE-READBACK LATENCY (Codex #4) ---")
    // Pick a non-Bluetooth replacement, preferring built-in (mirrors pickReplacementInput).
    let nonBT = allInputs.filter { $0.inChannels > 0 && !isBluetooth($0.transport) && $0.id != currentInputID }
    guard let target = nonBT.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) ?? nonBT.first else {
        print("  SKIP: no non-Bluetooth replacement input available")
        return
    }
    var writeAddr = addr(kAudioHardwarePropertyDefaultInputDevice)
    var targetID = target.id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let t0 = DispatchTime.now()
    let writeStatus = AudioObjectSetPropertyData(systemObject, &writeAddr, 0, nil, size, &targetID)
    print("  set default input -> \(target.name) [\(target.uid)] status=\(writeStatus)")
    guard writeStatus == noErr else { print("  write failed; nothing to restore"); return }

    // From here the system default input is ours and MUST be handed back on
    // every exit path, not just the one at the bottom of the function. Without
    // this, an early return or a thrown signal during the ~1s poll would leave
    // the user on the probe's replacement input with no indication why.
    //
    // Abrupt termination (SIGKILL, power loss) can still strand it; there is no
    // handler for that, and recovery is manual via System Settings > Sound.
    defer { restoreDefaultInput(to: currentInputID, writeAddr: writeAddr, size: size) }

    var landedNs: UInt64?
    for _ in 0..<200 { // up to ~1s at 5ms granularity
        var readAddr = addr(kAudioHardwarePropertyDefaultInputDevice)
        var current = AudioDeviceID(kAudioObjectUnknown)
        var rsize = size
        if AudioObjectGetPropertyData(systemObject, &readAddr, 0, nil, &rsize, &current) == noErr,
           current == target.id {
            landedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
            break
        }
        usleep(5000)
    }
    if let landedNs {
        print(String(format: "  readback matched after %.1f ms", Double(landedNs) / 1_000_000))
    } else {
        print("  readback NEVER matched within ~1s (async write or rejected)")
    }

}

/// Hand the system default input back, but only if it is still the device this
/// probe set. The poll window is about a second, and a user who changes their
/// input during it means it well — clobbering that choice would make the probe
/// the very kind of silent device-stealer the mitigation it tests is careful
/// not to be.
func restoreDefaultInput(
    to original: AudioDeviceID,
    writeAddr: AudioObjectPropertyAddress,
    size: UInt32
) {
    var readAddr = addr(kAudioHardwarePropertyDefaultInputDevice)
    var current = AudioDeviceID(kAudioObjectUnknown)
    var rsize = size
    let readStatus = AudioObjectGetPropertyData(
        systemObject, &readAddr, 0, nil, &rsize, &current
    )
    guard readStatus == noErr else {
        print("  restore SKIPPED: could not read current default input (status=\(readStatus))")
        print("  default input may still be the probe's replacement — check System Settings > Sound")
        return
    }
    guard current != original else {
        print("  restore not needed; default input is already [\(original)]")
        return
    }
    var addrCopy = writeAddr
    var restoreID = original
    let restoreStatus = AudioObjectSetPropertyData(
        systemObject, &addrCopy, 0, nil, size, &restoreID
    )
    if restoreStatus == noErr {
        print("  restored default input -> [\(original)]")
    } else {
        print("  restore FAILED status=\(restoreStatus); default input is [\(current)]")
        print("  recover manually via System Settings > Sound > Input")
    }
}

// MARK: - Main

let args = CommandLine.arguments
let label = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "(unlabeled)"
let measureWrite = args.contains("--measure-write")

print("=================================================================")
print("EXP-037-R race-signal probe   condition=\(label)")
print("=================================================================")

let (defaultInputID, diStatus) = readScalar(systemObject, addr(kAudioHardwarePropertyDefaultInputDevice), default: AudioDeviceID(kAudioObjectUnknown))
let (defaultOutputID, doStatus) = readScalar(systemObject, addr(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID(kAudioObjectUnknown))
let inFacts = diStatus == noErr ? deviceFacts(defaultInputID) : nil
let outFacts = doStatus == noErr ? deviceFacts(defaultOutputID) : nil

print("DEFAULT INPUT : " + (inFacts.map { "\($0.name) [\($0.uid)] transport=\(transportName($0.transport)) in=\($0.inChannels)ch rate=\(Int($0.nominalRate))" } ?? "read failed (\(diStatus))"))
print("DEFAULT OUTPUT: " + (outFacts.map { "\($0.name) [\($0.uid)] transport=\(transportName($0.transport)) out=\($0.outChannels)ch rate=\(Int($0.nominalRate))" } ?? "read failed (\(doStatus))"))

// All devices.
let allDevices = readObjectArray(systemObject, addr(kAudioHardwarePropertyDevices)).map(deviceFacts)
print("\n--- DEVICES (\(allDevices.count)) ---")
for d in allDevices {
    let marks = [
        d.id == defaultInputID ? "DEF-IN" : nil,
        d.id == defaultOutputID ? "DEF-OUT" : nil,
        isBluetooth(d.transport) ? "BT" : nil,
    ].compactMap { $0 }.joined(separator: ",")
    let scoped = d.isRunningSomewhereInput.map { String($0) } ?? "n/a"
    print("  [\(d.id)] \(d.name)  \(transportName(d.transport))  in=\(d.inChannels) out=\(d.outChannels) rate=\(Int(d.nominalRate))"
        + "  running=\(d.isRunning) runningSomewhere=\(d.isRunningSomewhere) runningSomewhere[in]=\(scoped)"
        + (marks.isEmpty ? "" : "  <\(marks)>"))
}

// Processes (HAL process objects). May be empty/unavailable depending on entitlements.
let procs = processList().map(processFacts)
print("\n--- PROCESSES (\(procs.count) total; showing input/output-active) ---")
if procs.isEmpty {
    print("  (none returned — kAudioHardwarePropertyProcessObjectList empty or unavailable to this binary)")
}
for p in procs where p.isRunningInput || p.isRunningOutput {
    print("  pid=\(p.pid) \(p.bundleID)  runningInput=\(p.isRunningInput) runningOutput=\(p.isRunningOutput)"
        + (p.inputDeviceUIDs.isEmpty ? "" : "  inputDevices=\(p.inputDeviceUIDs)"))
}

// Candidate race signals evaluated against the default INPUT device.
let btDefaultInput = inFacts.map { isBluetooth($0.transport) } ?? false
let sigA = inFacts?.isRunningSomewhere ?? false
let sigB = inFacts?.isRunningSomewhereInput
let anyProcInput = procs.contains { $0.isRunningInput }
let defInputUID = inFacts?.uid
let anyProcInputOnBT = defInputUID.map { uid in
    procs.contains { $0.isRunningInput && $0.inputDeviceUIDs.contains(uid) }
} ?? false
let hfpSignature = inFacts.map { $0.inChannels > 0 && $0.nominalRate > 0 && $0.nominalRate <= 16000 } ?? false

print("\n--- CANDIDATE RACE SIGNALS (evaluated on the default INPUT device) ---")
print("  default input is Bluetooth?          : \(btDefaultInput)")
print("  SIG_A  IsRunningSomewhere (global)    : \(sigA)   <- the SHIPPED signal (Codex #3 says this false-fires on A2DP playback)")
print("  SIG_B  IsRunningSomewhere (input scope): \(sigB.map(String.init) ?? "n/a")")
print("  SIG_C  any process IsRunningInput     : \(anyProcInput)")
print("  SIG_D  any process IsRunningInput on this device: \(anyProcInputOnBT)")
print("  SIG_E  input stream present at HFP rate (<=16k): \(hfpSignature)")
print("\nInterpretation: the correct signal is FALSE under condition Y (A2DP playback,")
print("no call) and TRUE under condition Z (active call on the BT mic).")

if measureWrite, let inFacts {
    print("")
    measureWriteLatency(allInputs: allDevices, currentInputID: inFacts.id)
}
