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

    func test_restore_keepsCurrentNonBluetoothInputWhenSavedDeviceMissing() {
        // A3: saved UID no longer resolves to a present device. The user is
        // already on a USB mic, so the correct move is to leave it alone —
        // forcing the built-in over a device the user selected is the same
        // class of harm the marker exists to prevent (Codex PR #20 finding #5).
        // The built-in fallback still applies when the current default is
        // itself Bluetooth; see
        // `test_restore_appliesBuiltInFallbackWhenCurrentDefaultIsStillBluetooth`.
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

        XCTAssertEqual(control.defaultInput, usbID,
                       "a user-chosen USB mic must survive a restore whose saved device is gone")
        XCTAssertTrue(control.setInputCalls.isEmpty, "no write should be issued at all")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
        XCTAssertTrue(logs.contains { $0.contains("kept-current") })
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

    // MARK: Marker-safety regressions (from the adversarial review of #20)

    /// Re-engaging while a switch is already owed must NOT overwrite the stored
    /// original input — otherwise restore strands the user on the wrong device.
    /// (Review blocker.)
    func test_engage_doesNotOverwriteMarker_onSecondEngage() {
        let bt2ID: AudioDeviceID = 40
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
                bt2ID: .init(uid: "bt2-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        XCTAssertTrue(guardian.engageIfNeeded(settingEnabled: true).engaged)
        XCTAssertEqual(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "bt-uid")

        // Simulate the default input becoming Bluetooth again mid-session
        // (a second headset, a manual re-selection) and a second engage.
        control.defaultInput = bt2ID
        let second = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(second.engaged)
        XCTAssertEqual(second.reason, "already-engaged")
        XCTAssertEqual(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "bt-uid",
                       "the original input UID must survive a second engage")
        XCTAssertEqual(control.defaultInput, bt2ID, "a declined re-engage must not switch the input")
    }

    /// When restore cannot land (saved device gone AND no fallback input), the
    /// marker must be KEPT so the next launch retries — clearing it would make
    /// the strand permanent. (Review major.)
    func test_restore_keepsMarkerWhenRestoreFails() {
        let control = FakeDefaultInputControl(
            devices: [btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true)],
            defaultInput: btID,
            defaultOutput: btID
        )
        let defaults = makeDefaults()
        defaults.set("ghost-uid", forKey: DefaultInputGuard.strandedInputMarkerKey)
        var logs: [String] = []
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { logs.append($0) })

        guardian.restore(trigger: "clean-stop")

        XCTAssertEqual(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "ghost-uid",
                       "marker must be retained when restore fails, so launch recovery can retry")
        XCTAssertTrue(logs.contains { $0.contains("[EXP-037.restore]") && $0.contains("ok=false") })
    }

    /// A HAL write that returns success but does not take (readback mismatch)
    /// must be reported as a failed engage and must NOT leave a marker — we
    /// never claim a switch that did not land. (Review minor — diagnostic
    /// integrity.)
    func test_engage_readbackFailure_dropsMarkerAndReportsFailure() {
        let control = FakeDefaultInputControl(
            devices: [
                btID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth, running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn, running: false, isInput: true),
            ],
            defaultInput: btID,
            defaultOutput: btID
        )
        control.ignoreSetInput = true   // switch silently no-ops
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "switch-readback-failed")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey),
                     "no marker should remain for a switch that did not land")
        XCTAssertEqual(control.defaultInput, btID, "the input is unchanged after a no-op switch")
    }
}

// MARK: - Fake

/// Coverage for the second adversarial review round (Codex on PR #20).
final class DefaultInputGuardReviewRoundTwoTests: XCTestCase {

    private let btInputID: AudioDeviceID = 10
    private let btOutputID: AudioDeviceID = 11
    private let otherBTInputID: AudioDeviceID = 12
    private let builtInID: AudioDeviceID = 20
    private let usbID: AudioDeviceID = 30
    private let virtualID: AudioDeviceID = 40

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "tnf.exp037.r2.\(UUID().uuidString)")!
    }

    // MARK: Same-physical-device identity (ADR-019 engage condition 3)

    /// macOS publishes a headset as two device objects with different IDs and
    /// `:input` / `:output` UID suffixes. The guard must still recognise them
    /// as the same headset — comparing IDs would never match.
    func test_engage_matchesSplitInputOutputObjectsOfOneHeadset() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btInputID: .init(uid: "BC-87-FA-23-5B-E0:input",
                                 transport: kAudioDeviceTransportTypeBluetooth,
                                 running: false, isInput: true),
                btOutputID: .init(uid: "BC-87-FA-23-5B-E0:output",
                                  transport: kAudioDeviceTransportTypeBluetooth,
                                  running: false, isInput: false),
                builtInID: .init(uid: "builtin-uid",
                                 transport: kAudioDeviceTransportTypeBuiltIn,
                                 running: false, isInput: true),
            ],
            defaultInput: btInputID,
            defaultOutput: btOutputID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertTrue(outcome.engaged,
                      "the split input/output objects of one headset must count as the same device")
        XCTAssertEqual(control.defaultInput, builtInID)
    }

    /// Bluetooth output A with an unrelated Bluetooth microphone B as the
    /// default input: HFP negotiates on B, not A, so switching B away is a
    /// system-wide side effect that buys nothing.
    func test_engage_declinesWhenBluetoothInputIsADifferentDeviceThanTheOutput() throws {
        let control = FakeDefaultInputControl(
            devices: [
                otherBTInputID: .init(uid: "AA-11-22-33-44-55:input",
                                      transport: kAudioDeviceTransportTypeBluetooth,
                                      running: false, isInput: true),
                btOutputID: .init(uid: "BC-87-FA-23-5B-E0:output",
                                  transport: kAudioDeviceTransportTypeBluetooth,
                                  running: false, isInput: false),
                builtInID: .init(uid: "builtin-uid",
                                 transport: kAudioDeviceTransportTypeBuiltIn,
                                 running: false, isInput: true),
            ],
            defaultInput: otherBTInputID,
            defaultOutput: btOutputID
        )
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "input-not-the-bt-output")
        XCTAssertEqual(control.defaultInput, otherBTInputID, "an unrelated mic must not be touched")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
    }

    // MARK: Replacement candidate selection

    /// A device can advertise input channels and still refuse to become the
    /// default input. It must not be offered.
    func test_engage_skipsCandidateThatCannotBeDefaultInput() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btInputID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth,
                                 running: false, isInput: true),
                virtualID: .init(uid: "virtual-uid", transport: kAudioDeviceTransportTypeVirtual,
                                 running: false, isInput: true, canBeDefaultInput: false),
                usbID: .init(uid: "usb-uid", transport: kAudioDeviceTransportTypeUSB,
                             running: false, isInput: true),
            ],
            defaultInput: btInputID,
            defaultOutput: btInputID
        )
        let guardian = DefaultInputGuard(control: control, defaults: makeDefaults(), log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertTrue(outcome.engaged)
        XCTAssertEqual(control.defaultInput, usbID)
        XCTAssertFalse(control.setInputCalls.contains(virtualID),
                       "a non-defaultable device must never be attempted")
    }

    /// If the HAL rejects the first candidate at write time, the next one is
    /// tried rather than the whole mitigation aborting.
    func test_engage_fallsThroughToNextCandidateWhenSetFails() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btInputID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth,
                                 running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn,
                                 running: false, isInput: true),
                usbID: .init(uid: "usb-uid", transport: kAudioDeviceTransportTypeUSB,
                             running: false, isInput: true),
            ],
            defaultInput: btInputID,
            defaultOutput: btInputID
        )
        control.rejectSetInput = [builtInID]
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertTrue(outcome.engaged)
        XCTAssertEqual(control.defaultInput, usbID)
        XCTAssertEqual(outcome.toUID, "usb-uid")
        XCTAssertEqual(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey), "bt-uid")
    }

    /// When no candidate can be applied, nothing changed — so the marker set
    /// ahead of the attempt must not survive to strand a later launch.
    func test_engage_dropsMarkerWhenEveryCandidateFails() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btInputID: .init(uid: "bt-uid", transport: kAudioDeviceTransportTypeBluetooth,
                                 running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn,
                                 running: false, isInput: true),
            ],
            defaultInput: btInputID,
            defaultOutput: btInputID
        )
        control.rejectSetInput = [builtInID]
        let defaults = makeDefaults()
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        let outcome = guardian.engageIfNeeded(settingEnabled: true)

        XCTAssertFalse(outcome.engaged)
        XCTAssertEqual(outcome.reason, "switch-readback-failed")
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
        XCTAssertEqual(control.defaultInput, btInputID)
    }

    // MARK: A3 restore fallback

    /// The saved headset is gone and the current default is still a Bluetooth
    /// device, so the built-in fallback does apply.
    func test_restore_appliesBuiltInFallbackWhenCurrentDefaultIsStillBluetooth() throws {
        let control = FakeDefaultInputControl(
            devices: [
                btInputID: .init(uid: "other-bt-uid", transport: kAudioDeviceTransportTypeBluetooth,
                                 running: false, isInput: true),
                builtInID: .init(uid: "builtin-uid", transport: kAudioDeviceTransportTypeBuiltIn,
                                 running: false, isInput: true),
            ],
            defaultInput: btInputID,
            defaultOutput: btInputID
        )
        let defaults = makeDefaults()
        defaults.set("gone-bt-uid", forKey: DefaultInputGuard.strandedInputMarkerKey)
        let guardian = DefaultInputGuard(control: control, defaults: defaults, log: { _ in })

        guardian.restore(trigger: "clean-stop")

        XCTAssertEqual(control.defaultInput, builtInID)
        XCTAssertNil(defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey))
    }

    // MARK: Physical-device key

    func test_physicalDeviceKey_stripsScopeSuffixes() {
        XCTAssertTrue(AudioDeviceIdentity.isSamePhysicalDevice(
            "BC-87-FA-23-5B-E0:input", "BC-87-FA-23-5B-E0:output"))
        XCTAssertFalse(AudioDeviceIdentity.isSamePhysicalDevice(
            "AA-11-22-33-44-55:input", "BC-87-FA-23-5B-E0:output"))
        // Devices without a scope suffix compare by their plain UID.
        XCTAssertTrue(AudioDeviceIdentity.isSamePhysicalDevice("BuiltInMicrophoneDevice",
                                                              "BuiltInMicrophoneDevice"))
        XCTAssertFalse(AudioDeviceIdentity.isSamePhysicalDevice("BuiltInMicrophoneDevice",
                                                               "BuiltInSpeakerDevice"))
    }
}

private final class FakeDefaultInputControl: DefaultInputControlling {
    struct Device {
        var uid: String
        var transport: UInt32
        var running: Bool
        var isInput: Bool
        /// Models `kAudioDevicePropertyDeviceCanBeDefaultDevice` on the input
        /// scope. Defaults to true so existing fixtures are unaffected.
        var canBeDefaultInput: Bool = true
    }

    var devices: [AudioDeviceID: Device]
    var defaultInput: AudioDeviceID
    var defaultOutput: AudioDeviceID
    private(set) var setInputCalls: [AudioDeviceID] = []
    /// Device IDs whose `setDefaultInputDeviceID` throws, modelling a HAL that
    /// refuses a device the enumeration offered.
    var rejectSetInput: Set<AudioDeviceID> = []
    /// When true, `setDefaultInputDeviceID` records the call but does NOT
    /// change `defaultInput` — models a HAL write that returns success yet
    /// does not take, so the guard's readback check can be exercised.
    var ignoreSetInput = false

    init(devices: [AudioDeviceID: Device], defaultInput: AudioDeviceID, defaultOutput: AudioDeviceID) {
        self.devices = devices
        self.defaultInput = defaultInput
        self.defaultOutput = defaultOutput
    }

    func defaultInputDeviceID() throws -> AudioDeviceID { defaultInput }
    func defaultOutputDeviceID() throws -> AudioDeviceID { defaultOutput }

    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws {
        setInputCalls.append(id)
        if rejectSetInput.contains(id) { throw FakeError.setRefused }
        if !ignoreSetInput { defaultInput = id }
    }

    func canBeDefaultInputDevice(_ id: AudioDeviceID) throws -> Bool {
        guard let device = devices[id] else { throw FakeError.unknownDevice }
        return device.canBeDefaultInput
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

    enum FakeError: Error { case unknownDevice, setRefused }
}
