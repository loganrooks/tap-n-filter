# ADR-001: Capture API

## Status

Accepted

## Context

tap-n-filter needs to capture audio from a chosen running application (Safari, Music, etc.) and route that audio through an effect chain. macOS offers several APIs that could plausibly accomplish per-application audio capture:

1. **Core Audio Process Taps** (`AudioHardwareCreateProcessTap` with `CATapDescription`) — introduced in macOS 14.4, designed specifically for per-process audio interception.

2. **ScreenCaptureKit** (`SCStreamConfiguration.capturesAudio = true`) — primarily a screen-recording API, supports audio-only capture as a side capability.

3. **Audio Hardware Plug-Ins** — a more invasive approach involving installing a virtual audio device that the user routes their app's audio through manually.

4. **AVCaptureSession with audio input devices** — captures from input devices (microphones), not from running applications.

Option 4 is immediately ruled out — it captures input devices, not application output. The real comparison is among 1, 2, and 3.

The user's source-of-knowledge for this decision: an Apple developer forum thread where an Apple engineer (Apple's "Core Audio" team) explicitly recommended Core Audio Process Taps for audio-only use cases over ScreenCaptureKit. The recommendation cited:

- Lower overhead (no video pipeline).
- No screen-recording permission prompt (which is misleading to users when no screen recording is happening).
- More direct integration with Core Audio HAL.

## Decision

V1 uses **Core Audio Process Taps** (`AudioHardwareCreateProcessTap` with `CATapDescription`), bridged into `AVAudioEngine` via an aggregate device.

The reference implementation is [insidegui/AudioCap](https://github.com/insidegui/AudioCap), maintained by Guilherme Rambo (Apple developer, hosts of Cocoaheads and the Cocoa Hangout podcast). That repo is the most thorough public example of using the API. The orchestrator reads it before writing capture code (see Phase 1 spec) and implements tap-n-filter's capture layer informed by AudioCap's patterns with attribution.

## Alternatives considered

### ScreenCaptureKit

Would also work technically. Rejected for three reasons:

1. Triggers the screen-recording permission prompt, even when no screen recording happens. Users find this confusing — "this app says it needs screen recording, but it's not recording my screen." Apple's UI doesn't distinguish the audio-only case.

2. Higher overhead due to the video pipeline machinery that's loaded even when only audio is requested.

3. Apple's own engineers, on the developer forums, have explicitly recommended Core Audio Process Taps over ScreenCaptureKit for audio-only cases. This is an official-channel signal, not a third-party opinion.

ScreenCaptureKit remains a potential fallback if Core Audio Process Taps prove untenable (tracked in `uncertainty-log.md`). The fallback is a substantial rewrite, not a contained change: `docs/specs/capture.md`'s CaptureController is structured around aggregate-device + HAL-property-setter calls that are specific to the process-tap backend. The public `CaptureControllerProtocol` exposes nothing that abstracts over the underlying capture mechanism. Swapping backends would mean replacing the concrete `CaptureController` implementation entirely. V1 commits to the process-tap path; if the fallback is needed, that work is its own design pass and likely its own ADR superseding this one.

### Audio Hardware Plug-In

Rejected because it requires the user to manually configure their source application to route through tap-n-filter's virtual device. This breaks the UX model — the user picks a source from a dropdown; the source doesn't need configuration on its own.

Audio Hardware Plug-Ins are still useful for some use cases (system-wide capture, capturing from apps that don't expose themselves to taps) and remain a possibility for a V2 extension.

### Loopback or BlackHole-style virtual devices

Same problem as Audio Hardware Plug-In: user-side configuration required. Also, these are typically installed as system-wide audio devices, which is a heavier install than a sandboxed-ish app.

## Consequences

**Enabled:**
- Minimum macOS version is 14.4 (the API's availability floor). See `ADR-005`.
- Per-application capture with no user-side configuration of the source app.
- Clean integration path into `AVAudioEngine`.
- No screen-recording permission prompt (only the audio capture prompt, which accurately describes what the app does).

**Precluded or constrained:**
- Older macOS versions are unsupported. macOS 14.4 was released in March 2024; coverage is broad enough by 2026 for a V1 audience but excludes older Intel Macs that don't run 14.4.
- The capture flow depends on a relatively new API. Bugs in the API itself may surface; the orchestrator should monitor Apple's release notes.
- Multi-pair output devices may produce attenuated capture. The known-issue is documented in `docs/specs/capture.md`; V1 does not implement compensation.

**Risks:**
- API instability across minor macOS releases. The API is new and not yet broadly battle-tested. Mitigation: pin behavior tests to current macOS versions and re-verify on each macOS update.
- AudioCap's patterns may diverge from Apple's preferred patterns over time. Mitigation: the implementation is structured for adaptation, and the orchestrator reviews AudioCap and Apple's documentation periodically.

## References

- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — reference implementation.
- Apple Developer Forums thread on audio capture for non-screen-recording use cases (referenced in `uncertainty-log.md`).
- `docs/specs/capture.md` — capture layer specification.
- `docs/decisions/uncertainty-log.md` — entries on the multi-pair attenuation issue and the API-stability concern.
- `docs/orchestration/phases/01-capture-spike.md` — Phase 1 spec, where the capture layer is built.
