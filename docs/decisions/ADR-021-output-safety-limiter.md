# ADR-021: Always-On Output Safety Limiter

## Status

Accepted (2026-06-07). Adds a fixed stage to the audio graph described in
`docs/specs/architecture.md` and `docs/specs/audio-graph.md`. Lands alongside
the new `GainNode` (`docs/specs/effect-node-protocol.md`), which is the feature
that makes the limiter load-bearing rather than theoretical.

## Context

V0.2 adds user-controllable output gain in two places: the per-graph output
trim (`Graph.outputGain`, 0–2×) and a new insertable `GainNode` (up to +12 dB,
≈3.98×). Both can push the signal past 0 dBFS. The capture source is also
outside our control — a podcast normalised hot, a game with a loud transient,
a song mastered near full scale — and the effect chain itself can add level
(an EQ boosting a band, a reverb summing wet and dry energy). Once the summed
signal exceeds 0 dBFS it clips at the output device, which on headphones is a
harsh, potentially painful blowout rather than a gentle distortion.

The app sits between an application and the user's ears and silences the source
while active (ADR-014), so the user cannot fall back on the app's own volume to
escape a blowout quickly. A clipping-prevention stage that the user cannot
accidentally defeat is a safety requirement, not a polish item, before shipping
a boostable gain control.

## Decision

Insert an always-on brick-wall peak limiter as a fixed stage in the graph,
between the output trim mixer and the destination:

```
… last effect → trimMixer (outputGain) → safetyLimiter → mainMixerNode → output
```

The limiter is Apple's `PeakLimiter` AudioUnit
(`kAudioUnitSubType_PeakLimiter`), wrapped in an `AVAudioUnitEffect` and owned
by `Graph` (not by the `nodes` chain). At its default settings (pre-gain 0 dB)
it holds peaks at approximately 0 dBFS, which is exactly the wanted behaviour,
so no parameters are tuned.

Key properties of the decision:

- **Always on, not user-defeatable.** The limiter is a safety floor, not an
  effect. There is no toggle in V0.2. A future "advanced: disable output
  limiter" escape hatch for power users is possible but deliberately omitted
  now (see alternatives).
- **Outside the effect chain.** It is not an `EffectNode` and never appears in
  the chain editor, in presets, or in `EffectNodeRegistry`. It cannot be
  reordered, removed, or bypassed through the normal node machinery.
- **Last stage before the engine mixer.** Placing it after the output trim
  means it catches everything the user can do upstream — every effect, the
  per-node wet/dry, and the output gain — in one place.
- **Transparent below threshold.** A signal that never approaches 0 dBFS
  passes essentially unchanged; the limiter only acts on peaks that would
  otherwise clip, so normal-level listening is uncoloured.

### Interaction with the H17 format-pin (load-bearing)

The two new connections (`trimMixer → safetyLimiter` and
`safetyLimiter → destination`) obey the same format-pin discipline as the rest
of `Graph.attach`. When the capture path pins the tap's sample rate, both links
use that rate; the engine's `mainMixerNode` still performs the single
sample-rate conversion to the output device. This matters because an
attached-but-unconnected `AVAudioUnitEffect` reports the engine's default
format (44.1 kHz) from `outputFormat(forBus:)`, not the rate it will actually
run at — reading that default for these connections would reintroduce the
H17 "pitched-down / voice-changer" bug
(`docs/investigations/2026-05-audio-pipeline.md`, EXP-032). The limiter
insertion was wired through the pinned path specifically to preserve that fix.

## Alternatives considered

### No limiter; rely on the user not to over-boost

Rejected. Shipping a boostable gain control with no protection makes a painful
blowout a one-slider mistake, on headphones, with the source muted. The cost of
the safety stage (one AudioUnit, transparent below threshold) is far below the
cost of the failure it prevents.

### A user-toggleable / insertable limiter `EffectNode`

Rejected for the safety role. If the limiter is an ordinary node it can be
removed, bypassed, or reordered to sit before the gain it is meant to catch,
which defeats the purpose. A *creative* limiter/compressor as an `EffectNode`
is a fine future feature, but it is a separate thing from the fixed safety
floor and would not replace it.

### Manual sample-clamp / soft-clip in a render block

Rejected. A hand-written clamp in an `AVAudioSourceNode` or tap render block
would be a hard clip (harsh) unless we also implement look-ahead and
attack/release, which is exactly what `PeakLimiter` already provides, tested
and on every supported macOS. Reimplementing it adds DSP surface to maintain
for no benefit.

### `DynamicsProcessor` configured as a limiter

Considered. `kAudioUnitSubType_DynamicsProcessor` can be set to a high ratio
with a 0 dBFS threshold to act as a limiter. `PeakLimiter` is the
purpose-built, simpler component for "do not exceed 0 dBFS" and needs no
parameter tuning, so it is the cleaner default. The DynamicsProcessor remains
the natural choice if a future version wants a tunable compressor/limiter
*effect*.

### Disable-able safety limiter (advanced setting)

Deferred. A power user feeding a downstream limiter of their own might want
ours off to avoid double-limiting. A hidden "disable output limiter" advanced
toggle could serve that, but it adds a footgun and UI surface for a narrow
case. Left out of V0.2; revisit if a real user need appears.

## Consequences

**Enabled:**

- A boostable `GainNode` and a 0–2× output trim can ship without exposing the
  user to a clipping blowout.
- A single, predictable place where output level is guaranteed bounded,
  independent of source, effects, or user settings.

**Precluded or constrained:**

- The absolute output ceiling is fixed at ~0 dBFS. A user who wants to
  intentionally drive the output into clipping (a creative choice) cannot, in
  V0.2.
- The graph now owns an `AVAudioUnit` it always instantiates, a small fixed
  cost per capture session (negligible relative to the effect chain).
- Extreme sustained boost is limited rather than passed through, so a user
  dialing +12 dB into an already-hot source hears the limiter act. This is the
  intended behaviour, but it means the gain knob is not linear all the way to
  the top on hot material.

**Risks:**

- `PeakLimiter` defaults are assumed adequate as a brick wall. If on-device
  testing shows audible pumping or insufficient limiting on real material, the
  attack/decay/pre-gain parameters are the tuning surface; this ADR is not
  invalidated, only its default-parameters assumption.
- The limiter sits on the H17-sensitive `Graph.attach` connection path. The
  format-pin discipline above is the mitigation; the graph unit tests assert
  attach/detach and the limiter's clamping behaviour via offline rendering, but
  the sample-rate correctness on a live 48 kHz tap is owed an on-device check.

## References

- ADR-014 — source process muted while tapped (why the user cannot quickly
  escape a blowout via the source's own volume).
- ADR-007 — wet/dry on EQ (the `showsWetDryByDefault` precedent that
  `supportsWetDry` extends for utility nodes).
- `docs/investigations/2026-05-audio-pipeline.md`, EXP-032 — the H17
  format-propagation bug whose fix the limiter insertion preserves.
- `docs/specs/architecture.md`, `docs/specs/audio-graph.md`,
  `docs/specs/effect-node-protocol.md` — updated for the fixed limiter stage
  and the `GainNode`.
- Apple `PeakLimiter` AudioUnit (`kAudioUnitSubType_PeakLimiter`).
