# Phase 1 Manual Passthrough Test

Originally documented as the procedure-of-record on `Phase1DebugViewModel`. Phase 3 replaced the debug UI with the production `ControlPanelView`; the procedure is preserved here so the Phase 1 gate criterion can be re-executed if a regression suspect ever calls for it.

## Procedure

1. Open Safari and start a YouTube video (or any audio-producing tab).
2. Launch the app. The menu-bar icon appears.
3. Click the icon, select Safari from the **Source** picker, and click **Start**.
4. Wait 5 seconds. You should hear the captured audio through your default output device.
5. Click **Stop**.

## Recording variant

The Phase 1 debug UI exposed a "Record output" toggle that installed an `AVAudioEngine` tap on `mainMixerNode` and wrote PCM frames to `~/Library/Application Support/tap-n-filter/phase-1-passthrough.wav`. The production UI does not expose this toggle — recording was a Phase 1 instrumentation, not a V1 user-facing feature. If a regression requires the recorded baseline, restore the toggle locally (do not commit) and re-run.

## Permission prompts

The permission grant dialog appears on the first **Start** press. Deny it to verify the `.permissionDenied` error path (the UI's error chip surfaces it); allow it to run the passthrough. If you denied, go to System Settings → Privacy & Security → Screen & System Audio Recording and re-grant access before retrying.

## See also

- `docs/audits/verification/phase-1-passthrough.md` — original passing record of the test.
- `docs/specs/capture.md` — the capture-layer contract being exercised.
- `docs/specs/ui.md` — the production UI surface.
