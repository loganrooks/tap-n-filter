import CoreAudio
import XCTest
@testable import Capture

/// Unit tests for the EXP-037 Bluetooth-HFP mitigation logic. These exercise
/// the engage/restore/recover decision paths and the diagnostic markers
/// against a fake `DefaultInputControlling`, so they run with no hardware and
/// no live HAL. The on-device verification of D2 (A2DP retained) is owed
/// separately — these tests cover D1, D3, D4, D5 and the engage conditions.
final class DefaultInputGuardTests: XCTestCase {

    // Device id constants used across tests.
    private let btID: AudioDeviceID = 10
    private let builtInID: AudioDeviceID = 20
    private let usbID: AudioDeviceID = 30

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tnf.exp037.\(UUID().uuidString)")!
    }

    // MARK: Engage

    func test_engage_switchesBluetoothInputToBuiltIn_andMarksStranded() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        var logs: [String] = []
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { logs.append($0) })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertTrue(outcome.engaged)
        XCTAssertEqual(outcome.fromUID, "bt-uid")
        XCTAssertEqual(outcome.toUID, "builtin-uid")
        XCTAssertEqual(control.defaultInput, builtInID, "default input should now be the built-in mic")
        XCTAssertEqual(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "bt-uid",
                       "the original input UID must be persisted before the switch")
        XCTAssertTrue(logs.contains { $0.contains("[EXP-037.switch]") && $0.contains("engaged=true") })
    }

    func test_engage_prefersBuiltInOverOtherNonBluetooth() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                usbID: .init(uid: "usb-uid", transport: kAudioDeviceTransportTypeUSB, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertTrue(outcome.engaged)
        XCTAssertEqual(control.defaultInput, builtInID)
    }

    func test_engage_usesNonBluetoothWhenNoBuiltIn() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                usbID: .init(uid: "usb-uid", transport: kAudioDeviceTransportTypeUSB, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertTrue(outcome.engaged)
        XCTAssertEqual(control.defaultInput, usbID)
    }

    func test_doesNotEngage_whenSettingOff() {
        let control = FakeDefaultInputControl(
            devices: [btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true)],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: false)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "setting-off")
        XCTAssertEqual(control.defaultInput, btID, "input must be untouched when the setting is off")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
    }

    func test_doesNotEngage_whenOutputNotBluetooth() {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: builtInID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "output-not-bluetooth")
        XCTAssertEqual(control.defaultInput, btID)
    }

    func test_doesNotEngage_whenDefaultInputNotBluetooth() {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: builtInID,
            defaultOutput: btID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "input-not-bluetooth")
    }

    func test_declines_whenBluetoothInputRunningSomewhere() {
        // D5: a live call on the BT mic must not be hijacked.
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: true, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        var logs: [String] = []
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { logs.append($0) })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "bt-input-in-use")
        XCTAssertEqual(control.defaultInput, btID, "a busy BT mic must be left as the default input")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
        XCTAssertTrue(logs.contains { $0.contains("engaged=false") && $0.contains("reason=bt-input-in-use") })
    }

    func test_doesNotEngage_whenNoReplacementInputExists() {
        let control = FakeDefaultInputControl(
            devices: [btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true)],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "no-replacement-input")
        XCTAssertEqual(control.defaultInput, btID)
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
    }

    // MARK: Restore

    func test_restore_setsInputBackAndClearsMarker() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        var logs: [String] = []
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { logs.append($0) })

        XCTAssertTrue(guardian.engageIfNeeded(settingEnabled: true).engaged)
        XCTAssertEqual(control.defaultInput, builtInID)

        guardian.restore(trigger: "clean-stop")

        XCTAssertEqual(control.defaultInput, btID, "the original BT input should be restored")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "marker cleared after restore")
        XCTAssertTrue(logs.contains { $0.contains("[EXP-037.restore]") && $0.contains("trigger=clean-stop") && $0.contains("ok=true") })
    }

    func test_restore_isNoOpWithoutMarker() {
        let control = FakeDefaultInputControl(
            devices: [builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true)],
            defaultInput: builtInID,
            defaultOutput: builtInID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        guardian.restore(trigger: "clean-stop")

        XCTAssertTrue(control.setInputCalls.isEmpty, "restore with no marker must not touch the input")
    }

    func test_restore_fallsBackToBuiltInWhenSavedDeviceMissing() {
        // A3: saved UID no longer resolves to a present device.
        let control = FakeDefaultInputControl(
            devices: [
                usbID: .init(uid: "usb-uid", transport: kAudioDeviceTransportTypeUSB, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: usbID,
            defaultOutput: usbID
        )
        let defaults = makeDefaults()
        defaults.set("ghost-bt-uid", forKey: DefaultInputGuard.strandedInputMarkerKey)
        var logs: [String] = []
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { logs.append($0) })

        guardian.restore(trigger: "clean-stop")

        XCTAssertEqual(control.defaultInput, builtInID, "fall back to the built-in input when the saved device is gone")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
        XCTAssertTrue(logs.contains { $0.contains("fallback-applied") })
    }

    // MARK: Recover

    func test_recover_restoresWhenStrandedAndCaptureInactive() {
        // D4: crash left a marker; on next launch with capture inactive, restore.
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: builtInID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        defaults.set("bt-uid", forKey: DefaultInputGuard.strandedInputMarkerKey)
        var logs: [String] = []
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { logs.append($0) })

        guardian.recoverIfStranded(captureActive: false)

        XCTAssertEqual(control.defaultInput, btID, "the stranded input should be restored on launch")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
        XCTAssertTrue(logs.contains { $0.contains("[EXP-037.recover]") && $0.contains("markerCleared=true") })
    }

    func test_recover_isNoOpWhenCaptureActive() {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: builtInID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        defaults.set("bt-uid", forKey: DefaultInputGuard.strandedInputMarkerKey)
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        guardian.recoverIfStranded(captureActive: true)

        XCTAssertTrue(control.setInputCalls.isEmpty, "an active session owns the switch; recovery must not interfere")
        XCTAssertEqual(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "bt-uid", "marker preserved while capture is active")
    }
}

// MARK: - Fake

private final class FakeDefaultInputControl: DefaultInputControlling {
    struct Device {
        var uid: String
        var transport: UInt32
        var running: Bool
        var isInput: Bool
    }

    var devices: [AudioDeviceID: Device]
    var defaultInput: AudioDeviceID
    var defaultOutput: AudioDeviceID
    private(set) var setInputCalls: [AudioDeviceID] = []

    init(devices: [AudioDeviceID: Device], defaultInput: AudioDeviceID, defaultOutput: AudioDeviceID) {
        self.devices = devices
        self.defaultInput = defaultInput
        self.defaultOutput = defaultOutput
    }

    func defaultInputDeviceID() throws -> AudioDeviceID { defaultInput }
    func defaultOutputDeviceID() throws -> AudioDeviceID { defaultOutput }

    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws {
        setInputCalls.append(id)
        defaultInput = id
    }

    func transportType(of id: AudioDeviceID) throws -> UInt32 {
        guard let device = devices[id] else { throw FakeError.unknownDevice }
        return device.transport
    }

    func uid(of id: AudioDeviceID) throws -> String {
        guard let device = devices[id] else { throw FakeError.unknownDevice }
        return device.uid
    }

    func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        devices.first { $0.value.uid == uid }?.key
    }

    func isRunningSomewhere(_ id: AudioDeviceID) throws -> Bool {
        devices[id]?.running ?? false
    }

    func inputDeviceIDs() throws -> [AudioDeviceID] {
        devices.filter { $0.value.isInput }.keys.sorted()
    }

    enum FakeError: Error { case unknownDevice }
}
