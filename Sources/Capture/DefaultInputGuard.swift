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

    /// Emit the D5-shaped decline marker and return the matching outcome.
    ///
    /// Every decline goes through here so none is silent. The on-device
    /// verification greps `[EXP-037.switch]`, and a decline that logged nothing
    /// would read identically to a guard that was never called.
    private func declined(_ reason: String, detail: String? = nil) -> EngageOutcome {
        let suffix = detail.map { " \($0)" } ?? ""
        log("[EXP-037.switch] engaged=false reason=\(reason)\(suffix)")
        return .notEngaged(reason)
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
    /// or surface.
    ///
    /// Every path emits an `[EXP-037.switch]` marker, including each decline.
    /// The on-device verification greps for these strings, so a silent decline
    /// would be indistinguishable from a guard that never ran at all.
    ///
    /// Engage requires all of: the setting is on; the default *output* is a
    /// Bluetooth device; the default *input* is that same physical device; the
    /// Bluetooth input is not already in use by another process; and a
    /// non-Bluetooth replacement input exists.
    ///
    /// `async` because confirming the switch landed means polling the HAL
    /// readback, and this runs on the main actor at capture start — a blocking
    /// sleep there would stall the UI.
    @discardableResult
    public func engageIfNeeded(settingEnabled: Bool) async -> EngageOutcome {
        guard settingEnabled else { return declined("setting-off") }
        // Set-once: a present marker means a switch (from this session or a
        // crashed prior one) is still owed a restore. Never switch again while
        // one is outstanding — overwriting the marker would lose the true
        // original input and strand the user, the ship-blocker ADR-019 names.
        // Fails safe: a stale marker declines the switch (degraded audio)
        // rather than stranding.
        guard defaults.string(forKey: Self.strandedInputMarkerKey) == nil else {
            return declined("already-engaged")
        }
        do {
            let outputID = try control.defaultOutputDeviceID()
            guard outputID != AudioObjectID(kAudioObjectUnknown) else {
                return declined("no-default-output")
            }
            guard AudioDeviceTransport.isBluetooth(try control.transportType(of: outputID)) else {
                return declined("output-not-bluetooth")
            }
            let inputID = try control.defaultInputDeviceID()
            guard inputID != AudioObjectID(kAudioObjectUnknown) else {
                return declined("no-default-input")
            }
            guard AudioDeviceTransport.isBluetooth(try control.transportType(of: inputID)) else {
                // The default input is already non-Bluetooth: HFP will not
                // trigger, so there is nothing to switch.
                return declined("input-not-bluetooth")
            }
            let originUID = try control.uid(of: inputID)
            let outputUID = try control.uid(of: outputID)
            // ADR-019 engage condition 3 is an *identity* condition — the
            // default input must be the same headset as the Bluetooth output,
            // not merely some Bluetooth device. With BT output A selected and
            // an unrelated idle BT microphone B as the default input, HFP is
            // negotiated on B, not on A; switching B away is a system-wide
            // side effect that buys the user nothing.
            //
            // Note this cannot be an `AudioDeviceID` comparison: macOS
            // publishes a headset as two device objects with different IDs and
            // different UIDs (see `AudioDeviceIdentity`), so `inputID ==
            // outputID` would never hold and the mitigation would never
            // engage. The comparison is on the UID with its scope suffix
            // stripped.
            guard AudioDeviceIdentity.isSamePhysicalDevice(originUID, outputUID) else {
                return declined("input-not-the-bt-output",
                                detail: "from=\(originUID) btOutput=\(outputUID)")
            }
            let candidates = try replacementCandidates(excluding: inputID)
            guard !candidates.isEmpty else {
                return declined("no-replacement-input")
            }
            // EXP-037 race policy (D5): never hijack a Bluetooth mic in active
            // use (e.g. a live call). Checked immediately before the switch to
            // keep the check-then-act window minimal. A residual TOCTOU remains
            // between here and the real `AudioDeviceStart` in the capture
            // lifecycle — the HAL has no atomic test-and-set on the default
            // input — so the wiring keeps engage close to capture start (A1)
            // and this guarantee is best-effort by nature.
            if try control.isRunningSomewhere(inputID) {
                return declined("bt-input-in-use", detail: "from=\(originUID)")
            }
            // Persist the original UID BEFORE the switch so a crash between the
            // switch and a clean stop can still be recovered on next launch.
            defaults.set(originUID, forKey: Self.strandedInputMarkerKey)
            // Try candidates in preference order. A device can advertise input
            // channels and still refuse to become the default input, and the
            // HAL only reports that at write time — so one unusable candidate
            // must not disable the mitigation while a usable one remains.
            for replacement in candidates {
                do {
                    try control.setDefaultInputDeviceID(replacement)
                } catch {
                    log("[EXP-037.switch] candidate=\(replacement) set-failed error=\(error)")
                    continue
                }
                // D1 requires the switch to have actually landed: a readback
                // that the default input now equals the replacement. A `noErr`
                // write that did not take is NOT success — we never claim D1
                // (or leave a recovery breadcrumb) for a no-op switch.
                guard await readBackDefaultInput(equals: replacement) else {
                    log("[EXP-037.switch] candidate=\(replacement) readback-failed")
                    continue
                }
                let replacementUID = (try? control.uid(of: replacement)) ?? "?"
                log("[EXP-037.switch] from=\(originUID) to=\(replacementUID) "
                    + "btOutput=\(outputUID) engaged=true readback=true")
                return EngageOutcome(
                    engaged: true,
                    reason: nil,
                    fromUID: originUID,
                    toUID: replacementUID
                )
            }
            // Every candidate failed. Drop the marker we optimistically set —
            // nothing was changed, so there is nothing owed a restore.
            defaults.removeObject(forKey: Self.strandedInputMarkerKey)
            return declined("switch-readback-failed",
                            detail: "from=\(originUID) candidates=\(candidates.count)")
        } catch {
            return declined("error", detail: "error=\(error)")
        }
    }

    // MARK: Restore (clean stop)

    /// Restore the default input saved at engage time. Called on a clean stop.
    /// No-op when no marker is present (engage never ran or already restored).
    public func restore(trigger: String) async {
        guard let savedUID = defaults.string(forKey: Self.strandedInputMarkerKey) else { return }
        let ok = await applyRestore(toUID: savedUID)
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
    public func recoverIfStranded(captureActive: Bool) async {
        guard !captureActive else { return }
        guard let savedUID = defaults.string(forKey: Self.strandedInputMarkerKey) else { return }
        let ok = await applyRestore(toUID: savedUID)
        // D4 (crash recovery landed). Clear the marker only on success so a
        // transient HAL failure is retried on the next launch rather than
        // erased (consistent with `restore`).
        log("[EXP-037.recover] restoredTo=\(savedUID) ok=\(ok) markerCleared=\(ok)")
        if ok {
            defaults.removeObject(forKey: Self.strandedInputMarkerKey)
        }
    }

    // MARK: Helpers

    /// Readback poll budget: 5 attempts with a 20 ms pause *between* them, so
    /// 4 sleeps — a worst case of 80 ms, not 100.
    ///
    /// HAL property writes are not guaranteed to be visible to the very next
    /// read. A single immediate readback can therefore report a false failure
    /// for a switch that lands a few milliseconds later — which matters here
    /// because the caller must not reach `AudioDeviceStart` before the switch
    /// is live (EXP-037's A1 timing assumption), and because a false failure
    /// drops the marker and strands the user on a switch that did land.
    ///
    /// The poll costs nothing on the common path: the first readback normally
    /// succeeds and returns immediately. `applyRestore` can pay the budget once
    /// per fallback candidate, which is why this awaits rather than sleeping —
    /// the caller is on the main actor.
    ///
    /// The numbers are an assumption, not a measurement. The probe's
    /// `--measure-write` mode times the real write-to-readback latency and is
    /// what would let them be set from data.
    private static let readbackAttempts = 5
    private static let readbackRetryDelay: Duration = .milliseconds(20)

    /// Poll `kAudioHardwarePropertyDefaultInputDevice` until it reports
    /// `expected`, up to the bounded attempt budget.
    private func readBackDefaultInput(equals expected: AudioDeviceID) async -> Bool {
        for attempt in 0..<Self.readbackAttempts {
            if (try? control.defaultInputDeviceID()) == expected { return true }
            if attempt < Self.readbackAttempts - 1 {
                try? await Task.sleep(for: Self.readbackRetryDelay)
            }
        }
        return false
    }

    /// Resolve the saved UID to a present device and set it as the default
    /// input. A3 fallback: if the saved device is gone, keep whatever
    /// non-Bluetooth input the user is on now, and only reach for the built-in
    /// mic when the current default is itself unusable. If nothing usable
    /// exists, leave the input untouched and report failure.
    private func applyRestore(toUID savedUID: String) async -> Bool {
        do {
            if let target = try control.deviceID(forUID: savedUID) {
                try control.setDefaultInputDeviceID(target)
                return await readBackDefaultInput(equals: target)
            }
            // A3: the saved device is gone (headset unpaired mid-session).
            // Preserve the current system default before resorting to the
            // built-in mic — the user may have already picked a perfectly good
            // USB mic, and overwriting it would leave them on an input they
            // never chose, which is the same class of harm the marker exists
            // to prevent.
            if let current = try? control.defaultInputDeviceID(),
               current != AudioObjectID(kAudioObjectUnknown),
               let transport = try? control.transportType(of: current),
               !AudioDeviceTransport.isBluetooth(transport) {
                log("[EXP-037.restore] kept-current savedUIDMissing=\(savedUID)")
                return true
            }
            for fallback in try replacementCandidates(excluding: nil) {
                guard (try? control.setDefaultInputDeviceID(fallback)) != nil,
                      await readBackDefaultInput(equals: fallback) else { continue }
                log("[EXP-037.restore] fallback-applied savedUIDMissing=\(savedUID)")
                return true
            }
            return false
        } catch {
            log("[EXP-037.restore] error=\(error)")
            return false
        }
    }

    /// Non-Bluetooth input devices that can actually become the default input,
    /// in preference order: the built-in microphone first, then the rest in
    /// HAL order. Empty when the only inputs are Bluetooth or non-selectable
    /// (the mitigation cannot run; the caller surfaces the README caveat).
    ///
    /// A device is filtered out unless `canBeDefaultInputDevice` says the HAL
    /// will accept it. Some virtual and aggregate devices advertise input
    /// channels but refuse to be the default input; offering one and having
    /// the write fail used to abort the whole switch even when a usable mic
    /// was next in the list.
    private func replacementCandidates(
        excluding excludedID: AudioDeviceID?
    ) throws -> [AudioDeviceID] {
        var builtIn: [AudioDeviceID] = []
        var others: [AudioDeviceID] = []
        for id in try control.inputDeviceIDs() where id != excludedID {
            let transport = try control.transportType(of: id)
            if AudioDeviceTransport.isBluetooth(transport) { continue }
            // A device that cannot be read is a device we cannot vouch for.
            guard (try? control.canBeDefaultInputDevice(id)) == true else { continue }
            if AudioDeviceTransport.isBuiltIn(transport) {
                builtIn.append(id)
            } else {
                others.append(id)
            }
        }
        return builtIn + others
    }
}
