# ADR-014: Mute the Source Process When the Tap Is Active

## Status

Accepted

## Context

`CATapDescription`'s `muteBehavior` property controls whether the OS keeps
playing the tapped process's audio through the normal output path while a
tap is observing it. The options are:

- `.unmuted` (default) — source plays normally, tap observes a copy.
- `.muted` — source is silenced at the OS level, tap delivers the audio
  the source produced.
- `.mutedWhenTapped` — source plays normally when no client is reading
  the tap; muted while a client is actively reading.

Until this ADR landed, `Sources/Capture/CoreAudioInterface.swift` created
the tap without setting `muteBehavior`, so the tap defaulted to
`.unmuted`. The architecture, however, was always interception: the
Phase 1 spec (`docs/orchestration/phases/01-capture-spike.md`) puts an
"audio output (intercepted)" arrow between the source app and the tap,
and the V1 user model is "tap-n-filter replaces what I hear with the
filtered version." With the default `.unmuted` setting, V0.1.0 produced
a different behaviour: the source app's audio continued to play through
the system mixer untouched, and `tap-n-filter`'s processed output mixed
in alongside via `AVAudioEngine.outputNode`. The user heard the
unfiltered signal plus a faint, lagged processed copy. Functional
testing on 2026-05-21 surfaced this with a Safari source and the
`distant-engines` preset: the user reported "audio continues as it did
before" and "killing the app makes audio slightly louder and crisper"
— consistent with the unmuted tap leaving the original path active.

## Decision

Set `description.muteBehavior = .muted` on every tap V0.1.0 creates. The
source process is silenced at the OS level while the tap is alive; the
tap captures the audio the source would have played, the effect chain
processes it, and `AVAudioEngine.mainMixerNode → outputNode` delivers
the processed audio to the user's output device.

Stopping the capture (`tap.stop`, then aggregate device teardown)
returns the source process to unmuted, so its audio resumes normally.
This matches the V1 user model: "tap-n-filter on" filters what you
hear; "tap-n-filter off" gives you the original audio.

## Alternatives considered

### Stay `.unmuted`, mix processed signal on top of original

Rejected. The user would always hear the original signal plus the
processed signal mixed at the audio device — the user model is
replacement, not augmentation. Augmenting is also subjectively worse:
reverb tails from the processed signal trail the original, which sounds
broken even when both signals are deliberate.

### `.mutedWhenTapped`

Rejected. The behaviour is identical to `.muted` while the tap is being
read, and tap-n-filter always reads the tap continuously between
`powerOn` and `powerOff`. The extra state machine complexity in
`.mutedWhenTapped` (auto-unmute when no reader is present) is unhelpful
because we never have a "tap exists but no reader" state.

### Route the processed audio to a virtual loopback device (BlackHole)

Rejected for V0.1.0. Requires the user to install BlackHole (or another
loopback driver) and configure macOS audio routing manually — a
multi-step setup that defeats the menubar app's "press power, hear
filtered audio" promise. V0.2 may add a virtual-output option for power
users who want to route the processed audio elsewhere, but the default
remains `.muted` + system output.

## Consequences

**Enabled:**

- "Power on" actually changes what the user hears. Filtering is
  audible, not a faint mix-in.
- Quitting the app immediately restores the source's normal audio (the
  tap teardown unmutes the process).
- The Phase 2 ear-test result (offline render of `distant-engines`
  against a YouTube clip, `[EAR_TEST: PASS]` on 2026-05-21) now matches
  the live listening experience — same chain, audible.

**Precluded or constrained:**

- The source process has no way to play audio at all while the tap is
  active. If `tap-n-filter` crashes mid-capture, the user's source app
  stays silent until the OS GCs the orphan tap (seconds, typically) or
  the user restarts the source app. V0.2 considers a watchdog that
  force-unmutes on abnormal exit.
- Apps with their own audio routing (e.g. a DAW outputting to a
  specific device that isn't the system default) may not be muted as
  expected. The `CATapMuteBehavior` documentation describes the system
  mixer's behaviour; specialised audio apps that bypass the system
  mixer are out of scope for V1.

**Risks:**

- Users who don't realise tap-n-filter is muting the source process
  may think the source app is broken when they hear silence with
  tap-n-filter off. Mitigation: the README and onboarding text make
  the "filter on = mute source + play processed" model explicit. The
  power button's "On / Off" state is the in-app affordance.

## References

- `docs/orchestration/phases/01-capture-spike.md` — architecture diagram
  with the "audio output (intercepted)" annotation.
- `Sources/Capture/CoreAudioInterface.swift` — `createTap` sets
  `muteBehavior = .muted`.
- `CATapDescription` and `CATapMuteBehavior` in the macOS CoreAudio
  framework.
