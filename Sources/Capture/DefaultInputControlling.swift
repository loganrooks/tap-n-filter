import AudioToolbox
import CoreAudio
import Foundation

/// Narrow seam for the system default-input device operations the
/// Bluetooth-HFP mitigation needs (ADR-019, EXP-037).
///
/// Kept separate from `CoreAudioInterface` (the tap/aggregate seam) on
/// purpose: the mitigation is a single-responsibility concern that should be
/// unit-testable without hardware and without entangling the capture path.
/// UIDs cross the seam as `String` (bridged from `CFString`) so the guard and
/// its tests stay value-typed.
public protocol DefaultInputControlling {
    /// The current system default *input* device.
    func defaultInputDeviceID() throws -> AudioDeviceID

    /// The current system default *output* device.
    func defaultOutputDeviceID() throws -> AudioDeviceID

    /// Set the system default *input* device. This is a system-wide side
    /// effect: every app that reads "the default input" sees the change.
    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws

    /// `kAudioDevicePropertyTransportType` for the device. Classify with
    /// `AudioDeviceTransport`.
    func transportType(of id: AudioDeviceID) throws -> UInt32

    /// `kAudioDevicePropertyDeviceUID` for the device.
    func uid(of id: AudioDeviceID) throws -> String

    /// Resolve a device UID back to an `AudioDeviceID`, or `nil` when no
    /// present device has that UID (e.g. the device was unplugged).
    func deviceID(forUID uid: String) throws -> AudioDeviceID?

    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` — true when any process
    /// is actively using the device (e.g. a live call on the Bluetooth mic).
    /// This backs the EXP-037 race policy: never hijack a busy BT input.
    func isRunningSomewhere(_ id: AudioDeviceID) throws -> Bool

    /// Every device that exposes at least one input channel.
    func inputDeviceIDs() throws -> [AudioDeviceID]

    /// `kAudioDevicePropertyDeviceCanBeDefaultDevice` on the input scope —
    /// false for devices the HAL exposes with input channels but refuses to
    /// make the default input (some virtual and aggregate devices). Setting
    /// such a device as the default input fails, so it must not be offered as
    /// a replacement.
    func canBeDefaultInputDevice(_ id: AudioDeviceID) throws -> Bool
}

/// Identity of the *physical* device behind a HAL device object.
public enum AudioDeviceIdentity {

    /// macOS publishes a Bluetooth headset as **two** device objects — one
    /// input-only, one output-only — with distinct `AudioDeviceID`s and
    /// distinct UIDs. The UIDs are the same Bluetooth MAC address with a
    /// `:input` / `:output` suffix. Measured on macOS 27 with a Bose
    /// QuietComfort, EXP-037-R condition Y
    /// (`docs/investigations/probes/exp037_race_signal.swift`):
    ///
    ///     id=108  in=1 out=0  uid=BC-87-FA-23-5B-E0:input
    ///     id=102  in=0 out=2  uid=BC-87-FA-23-5B-E0:output
    ///
    /// Comparing `AudioDeviceID`s to decide "is the default input the same
    /// headset as the default output" therefore never matches. Comparing the
    /// UID with its scope suffix stripped does.
    ///
    /// A UID with no recognised suffix is returned unchanged, so non-Bluetooth
    /// devices compare by their plain UID.
    public static func physicalDeviceKey(forUID uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }

    /// True when two device UIDs name the same physical device.
    public static func isSamePhysicalDevice(_ lhs: String, _ rhs: String) -> Bool {
        physicalDeviceKey(forUID: lhs) == physicalDeviceKey(forUID: rhs)
    }
}

/// Transport-type classification shared by the guard and its tests.
public enum AudioDeviceTransport {
    public static func isBluetooth(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    public static func isBuiltIn(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

/// Errors raised by `SystemDefaultInputControl` when a HAL property access
/// fails. Carries the `OSStatus` and the property name for diagnostics.
public enum DefaultInputControlError: Error {
    case propertyReadFailed(OSStatus, String)
    case propertyWriteFailed(OSStatus, String)
}

// MARK: - Real implementation

/// Concrete `DefaultInputControlling` backed by the Apple HAL.
///
/// All reads/writes target the system object for the default-device
/// properties and the specific `AudioDeviceID` for per-device properties,
/// matching the idiom in `CoreAudioInterface`'s real implementation.
public struct SystemDefaultInputControl: DefaultInputControlling {
    public init() {}

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readDeviceID(_ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var addr = address(selector)
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(Self.systemObject, &addr, 0, nil, &size, &value)
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "deviceID(\(selector))")
        }
        return value
    }

    public func defaultInputDeviceID() throws -> AudioDeviceID {
        try readDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    public func defaultOutputDeviceID() throws -> AudioDeviceID {
        try readDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    public func setDefaultInputDeviceID(_ id: AudioDeviceID) throws {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var value = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(Self.systemObject, &addr, 0, nil, size, &value)
        guard status == noErr else {
            throw DefaultInputControlError.propertyWriteFailed(status, "setDefaultInputDevice")
        }
    }

    public func transportType(of id: AudioDeviceID) throws -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "transportType")
        }
        return value
    }

    public func uid(of id: AudioDeviceID) throws -> String {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfUID)
        guard status == noErr, let cfUID else {
            throw DefaultInputControlError.propertyReadFailed(status, "deviceUID")
        }
        return cfUID.takeRetainedValue() as String
    }

    public func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                Self.systemObject,
                &addr,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "translateUIDToDevice")
        }
        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    public func isRunningSomewhere(_ id: AudioDeviceID) throws -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "isRunningSomewhere")
        }
        return value != 0
    }

    public func inputDeviceIDs() throws -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(Self.systemObject, &addr, 0, nil, &dataSize)
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "devices.size")
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(Self.systemObject, &addr, 0, nil, &dataSize, &ids)
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "devices")
        }
        return ids.filter { hasInputChannels($0) }
    }

    public func canBeDefaultInputDevice(_ id: AudioDeviceID) throws -> Bool {
        var addr = address(
            kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: kAudioObjectPropertyScopeInput
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr else {
            throw DefaultInputControlError.propertyReadFailed(status, "canBeDefaultInputDevice")
        }
        return value != 0
    }

    /// True when the device exposes at least one input channel. A device with
    /// no input streams (a pure output) is not a candidate replacement input.
    private func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, raw) == noErr else {
            return false
        }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }
}
