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
///
/// Not internally synchronized. Call all methods from the main actor: the
/// capture lifecycle (`powerOn`/`powerOff`) and launch recovery both run there,
/// so the single `UserDefaults` marker is only ever touched from one thread.
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
        // Set-once: a present marker means a switch (from this session or a
        // crashed prior one) is still owed a restore. Never switch again while
        // one is outstanding — overwriting the marker would lose the true
        // original input and strand the user, the ship-blocker ADR-019 names.
        // Fails safe: a stale marker declines the switch (degraded audio)
        // rather than stranding.
        guard defaults.string(forKey: Self.strandedInputMarkerKey) == nil else {
            return .notEngaged("already-engaged")
        }
        do {
            let outputID = try control.defaultOutputDeviceID()
            guard outputID != AudioObjectID(kAudioObjectUnknown) else {
                return .notEngaged("no-default-output")
            }
            guard AudioDeviceTransport.isBluetooth(try control.transportType(of: outputID)) else {
                return .notEngaged("output-not-bluetooth")
            }
            let inputID = try control.defaultInputDeviceID()
            guard inputID != AudioObjectID(kAudioObjectUnknown) else {
                return .notEngaged("no-default-input")
            }
            guard AudioDeviceTransport.isBluetooth(try control.transportType(of: inputID)) else {
                // The default input is already non-Bluetooth: HFP will not
                // trigger, so there is nothing to switch.
                return .notEngaged("input-not-bluetooth")
            }
            guard let replacement = try pickReplacementInput(excluding: inputID) else {
                log("[EXP-037.switch] engaged=false reason=no-replacement-input")
                return .notEngaged("no-replacement-input")
            }
            // EXP-037 race policy (D5): never hijack a Bluetooth mic in active
            // use (e.g. a live call). Checked immediately before the switch to
            // keep the check-then-act window minimal. A residual TOCTOU remains
            // between here and the real `AudioDeviceStart` in the capture
            // lifecycle — the HAL has no atomic test-and-set on the default
            // input — so the wiring keeps engage close to capture start (A1)
            // and this guarantee is best-effort by nature.
            if try control.isRunningSomewhere(inputID) {
                let originUID = (try? control.uid(of: inputID)) ?? "?"
                log("[EXP-037.switch] from=\(originUID) engaged=false reason=bt-input-in-use")
                return .notEngaged("bt-input-in-use")
            }
            let originUID = try control.uid(of: inputID)
            let outputUID = (try? control.uid(of: outputID)) ?? "?"
            // Persist the original UID BEFORE the switch so a crash between the
            // switch and a clean stop can still be recovered on next launch.
            defaults.set(originUID, forKey: Self.strandedInputMarkerKey)
            try control.setDefaultInputDeviceID(replacement)
            let replacementUID = try control.uid(of: replacement)
            // D1 requires the switch to have actually landed: a readback that
            // the default input now equals the replacement. A `noErr` write
            // that did not take is NOT success — drop the marker we just set
            // and report failure, so we never claim D1 (or leave a recovery
            // breadcrumb) for a no-op switch.
            guard (try? control.defaultInputDeviceID()) == replacement else {
                defaults.removeObject(forKey: Self.strandedInputMarkerKey)
                log("[EXP-037.switch] from=\(originUID) to=\(replacementUID) "
                    + "engaged=false reason=switch-readback-failed")
                return .notEngaged("switch-readback-failed")
            }
            log("[EXP-037.switch] from=\(originUID) to=\(replacementUID) "
                + "btOutput=\(outputUID) engaged=true readback=true")
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
        // Clear the marker ONLY when the restore actually landed. On failure
        // (HAL threw, or the saved device is gone and no fallback exists) keep
        // the breadcrumb so launch recovery retries — clearing it here would
        // convert a transient failure into a permanent strand.
        if ok {
            defaults.removeObject(forKey: Self.strandedInputMarkerKey)
        }
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
        // D4 (crash recovery landed). Clear the marker only on success so a
        // transient HAL failure is retried on the next launch rather than
        // erased (consistent with `restore`).
        log("[EXP-037.recover] restoredTo=\(savedUID) ok=\(ok) markerCleared=\(ok)")
        if ok {
            defaults.removeObject(forKey: Self.strandedInputMarkerKey)
        }
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
