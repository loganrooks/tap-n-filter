# ADR-019: Bluetooth HFP Mitigation via Default-Input Switch

## Status

Accepted (2026-05-29). Refines the H15 disposition in
`docs/investigations/2026-05-audio-pipeline.md`. Partially supersedes the
ADR-018 consequence "No HFP trigger on Bluetooth" (see Context).

## Context

On a Bluetooth output, starting a capture session degrades audio to
telephone quality: the system switches the Bluetooth device from A2DP
(44.1 kHz stereo, output-only) to HFP (16 kHz mono, bidirectional voice).
Effects still apply, but HFP's 8 kHz Nyquist strips the reverb tail and
collapses stereo width, so the chain is barely audible. The investigation
tracks this as H15.

ADR-018 moved capture off the `AVAudioEngine.inputNode` binding and kept
`outputNode` on the user's default output device. That removed one HFP
trigger — the one caused by re-binding the engine's unified IO audio unit
to the tap aggregate. ADR-018 listed "No HFP trigger on Bluetooth" as an
enabled consequence. Live testing on macOS 26.3 showed that claim was
incomplete: a **second, independent** trigger survived the architecture
change. An active process tap registers as a running input at the OS
routing layer (`kAudioProcessPropertyIsRunningInput`), and when the
Bluetooth device is the system default input, macOS negotiates HFP for it
regardless of how the engine's output is wired. EXP-029 captured this —
`outputNode` flips to 16 kHz × 1 ch about 65 ms after `AudioDeviceStart`,
with no engine reconfiguration on our side.

Earlier we treated H15 as an intrinsic OS limitation reachable only by a
HAL-plugin virtual device (V0.2 scope), and the V0.1 plan was a README
caveat. Two facts changed that:

- `sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" -bool
  true` does **not** work on macOS 26.3 (tested earlier in the
  investigation). The blunt system-wide switch is gone.
- **EXP-036** (2026-05-29): forcing the system default *input* device to
  the Mac built-in microphone keeps the Bluetooth output on A2DP. Two
  runs bracket it in `app.log` — default-input-on-Bluetooth gives
  `outputOut rate=16000 ch=1` (HFP); default-input-on-built-in-mic gives
  `outputOut rate=44100 ch=2` (A2DP). The reverb depth and stereo width
  audibly return.

EXP-036 establishes that the HFP trigger is gated on the Bluetooth device
being the system default *input* during capture, and that this lever is
manipulable from user space — no entitlement, no kext. An app-side
mitigation therefore exists.

The user chose a default-on toggle for the behaviour (the alternative was
a manual instruction or an off-by-default opt-in).

## Decision

V0.1 ships an app-side HFP mitigation: while capture is active, the app
switches the **system default input device** away from the Bluetooth
device, and restores the prior default input when capture stops. The
behaviour sits behind a setting, **"Preserve Bluetooth quality during
capture," on by default.**

The mitigation is conditional. It engages only when all hold:

1. The setting is on.
2. The capture output path is a Bluetooth device (the only route that
   suffers HFP).
3. The current system default input is that same Bluetooth device (if the
   default input is already a non-Bluetooth device, there is nothing to
   switch and HFP will not trigger).

When it engages, the app selects a replacement default input, preferring
the built-in microphone, then any non-Bluetooth input. If no non-Bluetooth
input exists, the mitigation cannot run; the app leaves the input
untouched and surfaces the README-style caveat instead.

State handling:

- The prior default input device's UID is persisted (UserDefaults) the
  moment the switch is made, so a crash mid-capture does not strand the
  user on the wrong input. On launch the app checks for a stranded marker
  and restores the saved input if capture is not active.
- On a clean stop, the app restores the saved input and clears the marker.

The implementation, including the discriminating prediction and its risky
branch, is pre-registered as **EXP-037** before any device-switch code is
written, per `docs/governance/debugging-protocol.md`. This ADR records the
decision; EXP-037 records the intervention. The race with a user who is
actively using the Bluetooth microphone (see Risks) is the open design
point EXP-037 settles.

The README caveat is retained as the fallback for the toggle-off case and
for Macs with no usable non-Bluetooth input.

## Alternatives considered

### README caveat only (the original V0.1 plan)

Document "for full quality use a wired output or built-in speakers."
Rejected as the primary path now that EXP-036 found a working in-app
mitigation. Demoted to a fallback for the cases the mitigation cannot
cover.

### Block V0.1 on a HAL-plugin virtual device

Install a virtual audio device (Rogue Amoeba ARK pattern) so the capture
path never touches the Bluetooth device as an input. This is the most
robust fix and avoids touching the user's input device at all. Rejected
for V0.1: it requires DriverKit or a kext-style installer, a different
distribution and entitlement model, and weeks of scope (consistent with
ADR-018's rejection of the same option for capture). Deferred to V0.2 as a
robustness improvement, not a prerequisite.

### `defaults write` HFP disable

Tested earlier; does not work on macOS 26.3. Ruled out.

### Off-by-default opt-in toggle

Same mechanism, but the user must discover and enable it. Rejected per the
user's choice: the degraded-on-Bluetooth experience is bad enough by
default that the mitigation should be on, with an escape hatch for users
who would rather we never touch their input device.

## Consequences

**Enabled:**

- Bluetooth output stays on A2DP (44.1 kHz stereo) during capture, so the
  effect chain is audible at full bandwidth and stereo width on the most
  common wireless-headphone setup.
- The mitigation is reversible and visible: a labelled toggle, restored on
  stop, recovered after a crash.

**Precluded or constrained:**

- Switching the system default input is a system-wide side effect. Other
  apps that read "the default input" see the change for the duration of
  capture. This is why the switch is narrow (only when the default input
  is the Bluetooth device being captured to) and restored promptly.
- The app gains a small device-management responsibility: enumerate input
  devices, classify Bluetooth vs non-Bluetooth (via
  `kAudioDevicePropertyTransportType`), persist and restore the prior
  default input, and recover a stranded marker on launch.

**Risks:**

- **Active microphone use.** If the user is on a call using the Bluetooth
  microphone while they start capture, switching the default input to the
  built-in mic changes their call's microphone mid-call. This is the
  sharpest risk. Mitigations to weigh in EXP-037: detect whether the
  Bluetooth input is already in use and decline to switch; or scope the
  switch tightly and rely on prompt restore. The default-on choice raises
  the stakes here, which is why the toggle is prominent and the restore
  path must be reliable.
- **Restore correctness.** A missed restore strands the user on the wrong
  input. The UserDefaults marker plus launch-time recovery is the guard;
  EXP-037's prediction must include a diagnostic that the restore actually
  landed, separate from the one that proves the switch landed.
- **Device churn.** Bluetooth disconnect mid-capture, or the saved device
  no longer existing at restore time, needs a defined fallback (restore to
  the current system default, or to the built-in input).

## References

- `docs/investigations/2026-05-audio-pipeline.md` — H15 (refined),
  EXP-029 (HFP trigger observed), EXP-036 (default-input lever found),
  EXP-037 (the app-side automation, pre-registered before code), Q4.
- ADR-018 — direct IOProc capture architecture; this ADR corrects its
  "No HFP trigger on Bluetooth" consequence and adds the mitigation that
  the surviving trigger requires.
- ADR-014 — source-process mute behaviour; unchanged by this ADR.
- `docs/governance/debugging-protocol.md` — why the automation is an
  intervention requiring a pre-registered entry (EXP-037).
- Apple Core Audio: `kAudioHardwarePropertyDefaultInputDevice`
  (settable), `kAudioDevicePropertyTransportType`
  (`kAudioDeviceTransportTypeBluetooth` / `…BluetoothLE` / `…BuiltIn`),
  `kAudioProcessPropertyIsRunningInput`.
