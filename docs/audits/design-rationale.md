# Design Rationale

This document is the author's account of how the tap-n-filter design ended up where it did. It is written for the framing auditor (Phase -1) to read alongside the bundle. The auditor uses this to assess whether the bundle's commitments are grounded in good reasoning or in post-hoc justification.

The rationale is honest. It includes false starts, redirections, and a few explicit failure modes the orchestrator should watch for. An audit that finds gaps between this account and the bundle is doing its job.

## Origin

The project began with a specific listening pattern. The author (Logan) wanted to layer F1 onboard audio (the in-car driver footage's audio track) underneath ambient music, with the onboard heavily filtered to sit in the mix like distant engine noise rather than dominant foreground sound. The desired effect: lowpass filter at around 800 Hz, large hall reverb at substantial wet mix, dropped into the background of whatever other audio was playing.

The first question was whether existing tools could do this. The conversation traced:

1. Chrome extension via `tabCapture` + Web Audio API — technically feasible, but only works while the source is in a Chrome tab. The author also uses Safari, and the F1 stream is in Safari PiP.
2. Safari extension via similar APIs — Safari has no `tabCapture` equivalent. This path is closed.
3. Existing audio-effect apps like Ears, Equalizer Plus, Loopback — either system-wide (affecting everything), or require manual routing setup per source app, or focus on different use cases.
4. A native macOS app that taps a specific app's audio — the path with the best fit.

The native app needs to capture audio from a chosen application, run it through configurable effects, output the result. That's tap-n-filter.

## Why now, why this design

The choice to build a custom app rather than use existing tools is motivated by the per-application capture requirement and the desire for a saveable preset format. Existing tools either:

- Apply system-wide (no per-app targeting), or
- Require manual routing of the source app's audio through a virtual device (Loopback-style), or
- Don't support the specific filter + reverb chain or don't save chains as portable files.

A custom app is acceptable because the project is also a vehicle for the author's broader work building agentic infrastructure: the bundle (this document set) is an artifact of an experiment in handing a structured project to a Claude Code orchestrator and seeing how far it gets autonomously.

The bundle is therefore doubly motivated: ship a working audio tool, and produce a reusable pattern for agent-driven builds of similar scope.

## Technical decisions and why they were made

### Capture API: Core Audio Process Taps

The Core Audio Process Tap API was the obvious choice once Apple's own forum guidance was located. ADR-001 documents this. The fallback (ScreenCaptureKit) is real but has known UX problems (the screen-recording permission prompt). The reference implementation, AudioCap, removes most of the implementation risk by showing what the API looks like in practice.

### Audio engine: AVAudioEngine

`AVAudioEngine` is Apple's standard mid-level audio framework. It handles the engine lifecycle, node attachment, and routing. The alternative (raw Core Audio Units with manual buffer management) is more flexible but vastly more code. `AVAudioEngine` is the right level of abstraction for a V1 tool.

### DSP units: AVAudioUnitEQ + AVAudioUnitReverb

Apple ships built-in audio units for parametric EQ (`AVAudioUnitEQ`) and convolution-style reverb (`AVAudioUnitReverb`). These are well-tested, work with `AVAudioEngine` natively, and offer the specific units the project needs (HP/LP bands; reverb with factory IRs). Writing custom DSP for V1 is unnecessary and risky.

The factory reverb IRs may or may not produce the exact aesthetic the author wants. This uncertainty is tracked in U-002. The Phase 2 ear test resolves it. If the IRs are insufficient, the architecture supports adding a convolution node with user-supplied IRs.

### Plugin architecture: closed set with EffectNode protocol

ADR-002. V1 doesn't host AUv3 plugins; it ships its own effects. The protocol surface is designed for V2 to add AUv3 hosting without breaking V1.

### Sandbox: no

ADR-003. V1 is unsandboxed. The Mac App Store is not the distribution target; signed/notarized DMG is. The unsandboxed posture preserves flexibility for V2's AUv3 hosting plan.

### Minimum macOS: 14.4

ADR-005. Bound by the Core Audio Process Tap API's availability floor.

### Name: tap-n-filter

ADR-004. A direct, descriptive name chosen after a notable detour through several concept-loaded alternatives that the user correctly rejected. The lesson — don't reach for names that suggest depth the project doesn't have — generalizes; the framing audit should look for the same pattern in technical decisions.

## Bundle shape and why

The bundle is a suite of ~30 markdown files plus state.json plus minor config, rather than a single brief that Claude Code expands at run time. The reasoning is in the dissent log entry from 2026-05-21: routing load-bearing design decisions through an agent re-derivation step adds a translation layer between intent and the artifacts the build phases consume. The bundle's documents are the documents the orchestrator reads.

The phase structure (-1 through 4) reflects a separation between design check (Phase -1) and the build phases (0–4). Each build phase is small enough to verify cleanly but substantial enough to merit a PR.

The governance docs (`audit-protocol.md`, `verification-protocol.md`, etc.) exist because the build is performed by an agent, and the user is committing to minimal involvement (two human-in-loop gates: ear test and acceptance). The protocols ensure the agent's autonomy doesn't degrade into either rubber-stamping (everything passes) or runaway escalation (everything is escalated to the user).

## Failure modes recorded for the auditor

These are real failure patterns from the conversation that produced this bundle. The audit should look for them in the bundle itself; if they're present, the audit's job is to surface them.

### Pattern 1: Reaching for unsupported narratives

During naming, the author of the bundle (the assistant in the original conversation) repeatedly proposed names with concept-loaded justifications — connecting "Manifold" to Kantian philosophy and F1 intake manifolds, connecting "Substrate" to ML and continental thought. The connections were strained. The user pushed back, correctly identifying these as post-hoc justifications for names chosen for sound rather than for sense.

The same pattern can appear in technical decisions: a capture API chosen because it "feels right" with a borrowed justification, an architecture chosen for its conceptual elegance without a concrete-need argument. The audit should look for technical claims justified by reach toward authority or elegance rather than by the project's actual needs.

### Pattern 2: Scope creep dressed as forward design

The temptation to add "supports AUv3 plugin hosting" or "marketplace UI" or "multi-source capture" to V1 is real. Each of those would be V2-defensible. None belongs in V1. The audit should check whether any V1 commitments are actually V2 wishes that snuck in.

### Pattern 3: Authority laundering

References to "Apple's recommendation" or "AudioCap's pattern" or "Apple engineer X said Y in forum thread Z" are evidence, but they're not arguments. The audit should verify that cited authorities actually settle the question they're cited for, and that the bundle doesn't outsource its reasoning to authorities without engaging with applicability.

### Pattern 4: Hidden reasoning

If a decision in the bundle has only the conclusion documented and not the reasoning, that's an audit flag. Decisions are recorded in ADRs (or the dissent log) precisely so the reasoning is visible. Bundle sections that read as confident pronouncements without traceable reasoning should be flagged.

## What this bundle does not commit to

- A claim that this design will produce a great product. It produces a V1 that meets the listed criteria. Whether the V1 is good depends on the ear test (Phase 2) and the user's acceptance (Phase 4).
- A claim that the agent-driven build will succeed. It commits to a structure that gives the build a fair chance and a clear set of gates that prevent silent failures. The orchestrator may still hit problems that require human intervention via the escalation channel.
- A claim that the audit framework is fully sound. The framing audit can miss things; the per-phase audit-lite is a narrow check; the verification subagent can be wrong. The framework is best-effort, not a guarantee.

## What the audit should look for

To summarize the audit's job in the auditor's terms (these mirror `audit-protocol.md`):

1. Decisions with weak reasoning.
2. Aesthetics disguised as technique.
3. Unconsidered alternatives.
4. Authority laundering.
5. Scope creep.
6. Implicit load-bearing assumptions.
7. Mismatch between this rationale doc and what the bundle actually commits to.

If the audit finds nothing, it's more likely a failed audit than a clean bundle.
