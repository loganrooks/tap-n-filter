import CoreAudio
import Foundation
import os

/// Bluetooth-HFP mitigation (ADR-019 / EXP-037).
///
/// While a capture session is active on a Bluetooth output whose device is
/// also the system default input, macOS negotiates HFP (16 kHz mono) for the
/// Bluetooth link, which collapses the effect chain to telephone quality.
/// EXP-036 established that forcing the system default *input* away from the
/// Bluetooth device keeps the output on A2DP. This guard automates that lever:
/// it switches the default input on capture start (subject to the ADR-019
/// engage conditions and the EXP-037 race check), restores the prior input on
/// clean stop, and recovers it on the next launch if a crash stranded it.
///
/// The decision and bookkeeping live here; the HAL calls go through
/// `DefaultInputControlling` so the logic is unit-testable without hardware.
/// The emitted `[EXP-037.switch|restore|recover]` markers are the diagnostics
/// defined in the EXP-037 pre-registration (D1, D3, D4, D5) and must not drift
/// from it — the on-device verification greps for exactly these strings.
public final class DefaultInputGuard {

    /// Key under which the pre-switch default-input UID is persisted, so a
    /// crash mid-capture can be recovered on the next launch. The literal name
    /// is fixed by the EXP-037 pre-registration.
    public static let strandedInputMarkerKey = "hfpMitigation.strandedInputUID"

    /// Outcome of an engage attempt. `engaged == false` carries a `reason`
    /// describing which engage condition (or the race check) declined.
    public struct EngageOutcome: Equatable {
        public let engaged: Bool
        public let reason: String?
        public let fromUID: String?
        public let toUID: String?

        static func notEngaged(_ reason: String) -> EngageOutcome {
            EngageOutcome(engaged: false, reason: reason, fromUID: nil, toUID: nil)
        }
    }

    private let control: DefaultInputControlling
    private let defaults: UserDefaults
    private let log: (String) -> Void

    public init(
        control: DefaultInputControlling,
        defaults: UserDefaults,
        log: @escaping (String) -> Void = { message in
            Logger(subsystem: "tap-n-filter", category: "hfp-mitigation")
                .info("\(message, privacy: .public)")
        }
    ) {
        self.control = control
        self.defaults = defaults
        self.log = log
    }

    // MARK: Engage (capture start)

    /// Evaluate the ADR-019 engage conditions plus the EXP-037 race check and,
    /// when all hold, switch the default input away from the Bluetooth device.
    /// Call once per capture start. Returns the outcome for the caller to log
    /// or surface; the diagnostic markers are emitted here regardless.
    ///
    /// Engage requires all of: the setting is on; the default *output* is a
    /// Bluetooth device; the default *input* is that Bluetooth class of device;
    /// the Bluetooth input is not already in use by another process; and a
    /// non-Bluetooth replacement input exists.
    @discardableResult
    public func engageIfNeeded(settingEnabled: Bool) -> EngageOutcome {
        guard settingEnabled else { return .notEngaged("setting-off") }
        do {
            let outputID = try control.defaultOutputDeviceID()
            guard AudioDeviceTransport.isBluetooth(try control.transportType(of: outputID)) else {
                return .notEngaged("output-not-bluetooth")
            }
            let inputID = try control.defaultInputDeviceID()
            guard AudioDeviceTransport.isBluetooth(try control.transportType(of: inputID)) else {
                // The default input is already non-Bluetooth: HFP will not
                // trigger, so there is nothing to switch.
                return .notEngaged("input-not-bluetooth")
            }
            // EXP-037 race policy: never hijack a Bluetooth mic that is in
            // active use (e.g. a live call). Degraded playback is the lesser
            // failure. (D5)
            if try control.isRunningSomewhere(inputID) {
                let originUID = (try? control.uid(of: inputID)) ?? "?"
                log("[EXP-037.switch] from=\(originUID) engaged=false reason=bt-input-in-use")
                return .notEngaged("bt-input-in-use")
            }
            guard let replacement = try pickReplacementInput(excluding: inputID) else {
                log("[EXP-037.switch] engaged=false reason=no-replacement-input")
                return .notEngaged("no-replacement-input")
            }
            let originUID = try control.uid(of: inputID)
            let outputUID = (try? control.uid(of: outputID)) ?? "?"
            // Persist the original UID BEFORE the switch so a crash between the
            // switch and a clean stop can still be recovered on next launch.
            defaults.set(originUID, forKey: Self.strandedInputMarkerKey)
            try control.setDefaultInputDeviceID(replacement)
            let replacementUID = try control.uid(of: replacement)
            let readbackOK = (try? control.defaultInputDeviceID()) == replacement
            // D1 (switch landed).
            log("[EXP-037.switch] from=\(originUID) to=\(replacementUID) "
                + "btOutput=\(outputUID) engaged=true readback=\(readbackOK)")
            return EngageOutcome(engaged: true, reason: nil, fromUID: originUID, toUID: replacementUID)
        } catch {
            log("[EXP-037.switch] engaged=false reason=error error=\(error)")
            return .notEngaged("error")
        }
    }

    // MARK: Restore (clean stop)

    /// Restore the default input saved at engage time. Called on a clean stop.
    /// No-op when no marker is present (engage never ran or already restored).
    public func restore(trigger: String) {
        guard let savedUID = defaults.string(forKey: Self.strandedInputMarkerKey) else { return }
        let ok = applyRestore(toUID: savedUID)
        // D3 (clean-stop restore landed).
        log("[EXP-037.restore] to=\(savedUID) trigger=\(trigger) ok=\(ok)")
        defaults.removeObject(forKey: Self.strandedInputMarkerKey)
    }

    // MARK: Recover (launch after crash)

    /// On launch, if a stranded-input marker is present and capture is not
    /// active, restore the saved input. Recovers from a crash that skipped
    /// `restore(trigger:)`. No-op while capture is active (a live session owns
    /// the switch and will restore it on its own stop).
    public func recoverIfStranded(captureActive: Bool) {
        guard !captureActive else { return }
        guard let savedUID = defaults.string(forKey: Self.strandedInputMarkerKey) else { return }
        let ok = applyRestore(toUID: savedUID)
        // D4 (crash recovery landed).
        log("[EXP-037.recover] restoredTo=\(savedUID) ok=\(ok) markerCleared=true")
        defaults.removeObject(forKey: Self.strandedInputMarkerKey)
    }

    // MARK: Helpers

    /// Resolve the saved UID to a present device and set it as the default
    /// input. A3 fallback: if the saved device is gone, fall back to a
    /// non-Bluetooth input (preferring the built-in mic); if none exists,
    /// leave the input untouched and report failure.
    private func applyRestore(toUID savedUID: String) -> Bool {
        do {
            if let target = try control.deviceID(forUID: savedUID) {
                try control.setDefaultInputDeviceID(target)
                return true
            }
            if let fallback = try pickReplacementInput(excluding: nil) {
                try control.setDefaultInputDeviceID(fallback)
                log("[EXP-037.restore] fallback-applied savedUIDMissing=\(savedUID)")
                return true
            }
            return false
        } catch {
            log("[EXP-037.restore] error=\(error)")
            return false
        }
    }

    /// Pick a non-Bluetooth input device, preferring the built-in microphone,
    /// then any other non-Bluetooth input. Returns `nil` when the only inputs
    /// are Bluetooth (the mitigation cannot run; the caller surfaces the
    /// README caveat).
    private func pickReplacementInput(excluding excludedID: AudioDeviceID?) throws -> AudioDeviceID? {
        var firstNonBluetooth: AudioDeviceID?
        for id in try control.inputDeviceIDs() where id != excludedID {
            let transport = try control.transportType(of: id)
            if AudioDeviceTransport.isBluetooth(transport) { continue }
            if AudioDeviceTransport.isBuiltIn(transport) { return id }
            if firstNonBluetooth == nil { firstNonBluetooth = id }
        }
        return firstNonBluetooth
    }
}
