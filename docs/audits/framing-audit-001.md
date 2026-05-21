# Framing Audit 001

**Auditor**: Claude (cold-context Opus subagent)
**Date**: 2026-05-20
**Inputs**: docs/audits/design-rationale.md, docs/orchestration/plan.md, docs/orchestration/state.json, docs/orchestration/phases/-1-framing-audit.md, docs/orchestration/phases/00-init.md, docs/orchestration/phases/01-capture-spike.md, docs/orchestration/phases/02-dsp-chain.md, docs/orchestration/phases/03-ui-control.md, docs/orchestration/phases/04-polish-release.md, docs/specs/architecture.md, docs/specs/capture.md, docs/specs/audio-graph.md, docs/specs/effect-node-protocol.md, docs/specs/preset-format.md, docs/specs/ui.md, docs/decisions/README.md, docs/decisions/ADR-001-capture-api.md, docs/decisions/ADR-002-plugin-architecture.md, docs/decisions/ADR-003-no-sandbox-v1.md, docs/decisions/ADR-004-name.md, docs/decisions/ADR-005-min-macos-version.md, docs/decisions/dissent-log.md, docs/decisions/uncertainty-log.md, docs/governance/coding-standards.md, docs/governance/quality-gates.md, docs/governance/review-protocol.md, docs/governance/audit-protocol.md, docs/governance/audit-response-protocol.md, docs/governance/escalation-criteria.md, docs/governance/verification-protocol.md, CLAUDE.md
**Approach**: Three-persona audit (macOS audio dev, security reviewer, PM)

## Summary

The bundle is unusually disciplined for a pre-code design package: phase specs are concrete, ADRs trace reasoning honestly, the decision-log conventions are well thought through, and the failure modes for the agentic workflow are explicitly anticipated. The naming ADR and the design rationale are particularly candid about prior drift, which makes the bundle easier to audit because the author has already pre-flagged the patterns to watch.

The weakest sections are in the capture spec and the EffectNode protocol. Both layers contain Swift signatures and Core Audio property references that are subtly wrong in ways that will surface as compile errors or runtime bugs during Phase 1 and Phase 2, and several of the load-bearing details (process identifier type, tap UID retrieval, EffectNode bus typing, mutation pattern under `engine.pause()`) read as written-from-memory rather than verified against the AudioCap reference. The bundle also leaves some integration ambiguity: the ear test exercises the DSP graph offline, the capture spike exercises capture by itself, and the first time the two run end-to-end is Phase 3 — a phase whose gate is satisfied by a SwiftUI snapshot and an accessibility audit the orchestrator self-administers.

Scope-wise, V1 is mostly right-sized for the stated use case (filtered F1 in background), but the bundle commits to four factory presets when one is the actual motivating preset and one is a baseline. The other two are aesthetic-by-fiat additions that risk consuming ear-test and tuning attention without earning it. The Phase 3 verification criteria for UI correctness and accessibility are softer than they read — a sloppy orchestrator can mark them met by writing a brief artifact.

Recommended disposition: address the High-severity findings (F-001, F-002, F-007) before Phase 1 begins, since they each seed bugs in code that hasn't been written. The Medium findings are worth addressing or explicitly disagreeing with as a batch in the response document. The Low findings are housekeeping.

## Findings

### F-001: Capture spec uses pid_t where the API requires AudioObjectID

- **Severity**: High
- **Confidence**: High
- **Persona(s)**: macOS dev
- **Location**: docs/specs/capture.md (sections "Process tap creation," "Aggregate device creation"), docs/orchestration/phases/01-capture-spike.md (section 1.1 — CaptureSource definition and CaptureController API)

**Finding**:

The capture spec passes `pid_t` directly to `CATapDescription(stereoMixdownOfProcesses: [pid])`. The actual Core Audio Process Tap API takes `[AudioObjectID]` representing audio process objects, not raw process identifiers. Going from a `pid_t` to the corresponding `AudioObjectID` requires a HAL property lookup (`kAudioHardwarePropertyTranslatePIDToProcessObject` against the system object). AudioCap, the bundle's nominated reference, does this translation explicitly. The spec's `CaptureSource` struct carries a `pid_t` and the snippet hands that `pid_t` straight to the tap constructor, which will not compile against the real API and would not capture the intended process if it did.

The same code-shape error appears in the aggregate-device snippet's `kAudioSubTapUIDKey` value: the spec writes `tapID.uid`, but `AudioObjectID` is a typealias for `UInt32` with no `.uid` member. The tap's UID is a CFString fetched via an `AudioObjectGetPropertyData` call on `kAudioTapPropertyUID`. AudioCap also does this, but the spec's pseudo-Swift glosses both the type and the property dance, which means the Phase 1 author has to re-derive the right calls under time pressure.

**Recommendation**:

Rewrite the capture spec snippets to (a) declare `CaptureSource.audioProcessID: AudioObjectID` alongside or instead of `pid`, (b) include the pid→AudioObjectID translation step explicitly, and (c) replace `tapID.uid` with a documented `kAudioTapPropertyUID` getter helper. The CaptureController API in Phase 1 should accept either the AudioObjectID directly or carry both fields. Failing that, add an explicit pointer in the spec saying "the snippets show intent; verify the exact `AudioObjectID` plumbing against AudioCap before coding," and add an uncertainty entry capturing the verification step.

---

### F-002: EffectNode bus typing loses the information the wet/dry pattern requires

- **Severity**: High
- **Confidence**: High
- **Persona(s)**: macOS dev
- **Location**: docs/specs/effect-node-protocol.md (section "Definition" and "Wet/dry mixing convention"), docs/specs/audio-graph.md (section "attach")

**Finding**:

`EffectNode` declares `var inputBus: AVAudioNode { get }` and `var outputBus: AVAudioNode { get }`. The wet/dry convention then says `inputBus` is "an `AVAudioMixerNode` that fans out to both paths" and `outputBus` is "another `AVAudioMixerNode` summing them." Mixer nodes carry per-input-bus gains; that is the whole mechanism the protocol relies on for wet/dry. Returning the upcast `AVAudioNode` loses both the static type and the bus identity. When the graph connects `nodes[i].outputBus` to `nodes[i+1].inputBus`, it has no way to specify which input bus on the target mixer the connection lands on; `AVAudioEngine.connect(_:to:format:)` defaults to bus 0, which collides with the node's own internal dry-path or wet-path bus assignment.

Compounding this, the graph's `attach` does `engine.pause()` and then mutates connections. `AVAudioEngine.pause()` does not place the engine into the state required for `attach`/`connect` calls — those calls expect the engine to be either not-yet-started or stopped (`stop()`), and certain reconfigurations require detaching nodes first. Mixing pause/prepare/start while reconfiguring connections is a pattern that AVAudioEngine documentation warns against and that has historically produced crashes or silent no-ops. Together with the bus-typing issue, this means the graph layer will not work as written.

**Recommendation**:

Either tighten the protocol to expose `AVAudioMixerNode` (or an internal `EffectBus` wrapper that carries node + bus index) and document the bus convention explicitly, or restructure the wet/dry pattern so each node exposes a single non-mixer input/output and the dry split happens inside a sub-graph. For mutations during playback, change the spec to use `engine.stop()` (or perform attach/connect only while the engine has not yet been started for that session), and document the silence-on-mutation cost the spec already acknowledges. A short ADR documenting "graph mutation lifecycle" would help, since Phase 3 also depends on mid-flight chain edits.

---

### F-003: ear-test exercises DSP only; end-to-end capture+DSP is first tested in Phase 3

- **Severity**: Medium
- **Confidence**: High
- **Persona(s)**: PM, macOS dev
- **Location**: docs/orchestration/phases/02-dsp-chain.md (section 2.8), docs/orchestration/phases/01-capture-spike.md (gate criterion 2), docs/orchestration/phases/03-ui-control.md

**Finding**:

The Phase 2 ear test renders a known wav offline through the DSP graph using `AVAudioEngine.enableManualRenderingMode`. The Phase 1 capture spike is verified by "a documented test of start → 5 seconds passthrough → stop." Each phase verifies a slice of the pipeline. The first time capture and DSP run together in real time, on a real source app, is Phase 3 — which is gated by a snapshot test, a view-model unit test, and an accessibility audit. None of those test that capturing Safari and feeding the result through the distant-engines preset actually produces audible filtered output.

This means a class of bugs (sample-rate mismatch between the aggregate device's native format and the EQ/Reverb units, format conversion needs that don't appear in the offline render, real-time scheduling artifacts) cannot surface until Phase 3, when the orchestrator is focused on UI work and the cost of going back to fix capture or DSP is highest. The ear test as currently scoped is an aesthetic check on the DSP, not an end-to-end check on the product.

**Recommendation**:

Add a Phase 2 integration check: after the offline render, run a 10-second live render through the actual capture chain (Safari playing a known YouTube tab, distant-engines preset, output recorded to a wav). Verify the recorded output is audible and matches the offline render's spectral character within a tolerance. This adds about an hour of work to Phase 2 and catches the integration class of bugs before UI work begins. Document the check in the phase spec's gate criteria so verification can confirm it ran.

---

### F-004: Wet/dry mixing on an EQ node is poorly motivated

- **Severity**: Medium
- **Confidence**: Medium
- **Persona(s)**: macOS dev, PM
- **Location**: docs/specs/effect-node-protocol.md (section "Wet/dry mixing convention"), docs/orchestration/phases/02-dsp-chain.md (section 2.3)

**Finding**:

Every `EffectNode` exposes a `wetDryMix` parameter and the protocol enforces wet/dry mixing internally. For a reverb this is conventional and useful. For a parametric EQ that is configured as a high-pass + low-pass bandpass-style filter (the V1 EQ's purpose), wet/dry has surprising semantics: at `wetDryMix = 0.5` half the unfiltered signal is summed back in, undoing the filtering. That is rarely what a user adjusting a slider labeled "wet/dry" on an EQ expects, and it is not a typical pattern in audio software.

The bundle does not justify why EQ needs wet/dry. The likely reason is uniformity of the protocol surface, which is a defensible reason, but the UI (`docs/specs/ui.md`) makes wet/dry "the most-used control" and "always visible" in every EffectRow. On EQ this gives users a control that mostly defeats their other settings. The ear-test preset sets EQ `wetDryMix: 1.0`, which is the only value that makes sense for that effect, suggesting the author noticed.

**Recommendation**:

Either (a) drop `wetDryMix` from the protocol's required surface and make it optional per node (EQ omits, Reverb includes), or (b) keep the protocol-level requirement but hide the EQ's wet/dry slider in the UI by default and document the reason. Option (a) is cleaner; option (b) preserves uniformity. Either choice deserves an ADR since it touches the protocol and the UI.

---

### F-005: The four-preset bundle is two presets larger than the rationale supports

- **Severity**: Medium
- **Confidence**: Medium
- **Persona(s)**: PM
- **Location**: docs/specs/preset-format.md (section "Bundled presets"), docs/orchestration/phases/03-ui-control.md (section "Out" and PresetMenu), design-rationale.md (section "Origin")

**Finding**:

The design rationale describes one motivating preset: heavily filtered F1 onboard audio sitting underneath ambient music. The bundle then ships four factory presets — `distant-engines` (the motivating one), `dry` (a baseline that's effectively a passthrough), `submerged` (lowpass at 500Hz + plate reverb + "slight modulation if implemented"), and `next-room` (gentle lowpass at 2.5kHz + small room reverb). The parameter choices for `submerged` and `next-room` are not justified, are not ear-tested in Phase 2 (only distant-engines is), and the "slight modulation if implemented" hedge admits the orchestrator does not yet know whether the preset's character is even achievable in V1.

This is the scope-creep pattern the design-rationale doc explicitly warned about: extra deliverables that look like product breadth but are actually V2 wishes carrying V1 cost. Tuning each preset takes ear-test time; "factory" framing implies they should each have been verified to sound like their name promises; the JSON files and the UI menu entries are sunk cost if they end up not being shipped.

**Recommendation**:

Cut to two bundled presets for V1: `distant-engines` and `dry`. Leave the other names as a TODO under V0.2 in the README and CHANGELOG. If the user later wants more presets, they're additive — the menu structure and `EffectNodeRegistry` are unchanged. If the rationale for shipping four was preserved against expectations, document the reasoning in an ADR so the choice is visible.

---

### F-006: Phase 3 accessibility gate is structurally self-audited

- **Severity**: Medium
- **Confidence**: High
- **Persona(s)**: PM, Security (lightly)
- **Location**: docs/orchestration/phases/03-ui-control.md (section 3.8 and gate criterion 5), docs/specs/ui.md (section "Accessibility")

**Finding**:

The Phase 3 gate requires that "Accessibility audit shows no major issues (VoiceOver reads every control, keyboard navigation reaches every control)." The audit is performed by the orchestrator running through the app with VoiceOver and writing the results to `docs/audits/verification/phase-3-accessibility.md`. The verification subagent then reads that file to confirm the gate.

The verification subagent has no way to corroborate the orchestrator's claims — it can confirm the file exists and contains plausible content, but it cannot independently observe VoiceOver behavior. If the orchestrator is sloppy, motivated, or limited in its ability to actually run interactive accessibility tools (a real possibility for an agent), it can produce a file that says "all good" and the gate passes. Similar shape applies to the Phase 1 gate ("non-silent audio is present in the recorded output") and Phase 4's clean-Gatekeeper-launch check ("if the orchestrator can't verify on a clean machine, it documents the verification approach"). Each of these has a documented out for "if you can't verify, write what you did instead."

**Recommendation**:

For Phase 3 accessibility specifically, add at least one programmatic check the verification subagent can re-run: snapshot the SwiftUI accessibility tree (via `XCUIApplication`'s element queries or a debug dump) and commit the tree as evidence. The subagent can then check that every interactive element has a non-empty `accessibilityLabel`. This catches the most common omissions automatically and leaves the manual VoiceOver check for the qualitative pass. For Phase 1, require the recorded wav to be committed as a small artifact (gitignored is fine; verification can read from the working tree) so the subagent can run a level check. For Phase 4, the "verify on a clean machine" criterion remains hard to automate; the documented-approach fallback is acceptable, but the spec should be explicit that this is a known soft spot.

---

### F-007: macOS audio capture permission UI and entitlement details are stale or speculative

- **Severity**: High
- **Confidence**: Medium
- **Persona(s)**: macOS dev, Security
- **Location**: docs/specs/capture.md (section "Permission handling"), docs/orchestration/phases/01-capture-spike.md (section 1.3), docs/orchestration/phases/04-polish-release.md (section 4.3)

**Finding**:

The capture spec says the System Settings path for the permission as of macOS 14.4 is "Privacy & Security → Microphone" and notes Apple conflates audio capture with microphone access. AudioCap and the Apple-engineer forum guidance actually describe a distinct "Audio Capture" or "Audio recording" permission pane separate from Microphone in 14.4+. If the bundle ships user-facing text and deep-link guidance pointing to Microphone settings, users who follow that guidance will look in the wrong place and conclude the app is broken when in fact a different toggle controls the permission.

Phase 4's signing/entitlements section says: "`com.apple.security.device.audio-input` (for the audio capture permission, if Apple's docs require it — verify against current docs)." `com.apple.security.device.audio-input` is the microphone hardware entitlement for sandboxed apps, not the process-tap audio-capture entitlement. For an unsandboxed app using process taps, there is no equivalent public entitlement; the `NSAudioCaptureUsageDescription` Info.plist key is what governs the prompt. Adding `audio-input` to entitlements may have no effect, or it may trigger Gatekeeper or notarization surprises that are hard to diagnose post-hoc.

**Recommendation**:

Before Phase 1, verify the actual System Settings path on the orchestrator's macOS version and update capture.md to match. Also verify whether the audio-capture-permission has its own pane in current macOS (likely yes); if so, the UI guidance and any open-System-Settings deep links must point there. For Phase 4 entitlements, remove `com.apple.security.device.audio-input` from the planned entitlement list unless the orchestrator can find a current Apple doc requiring it for process-tap-based capture; add an uncertainty entry tracking what entitlements (if any) the process tap path actually needs in an unsandboxed hardened-runtime app.

---

### F-008: GraphPreset Codable mechanism for `[any EffectNode]` is referenced but never specified

- **Severity**: Medium
- **Confidence**: High
- **Persona(s)**: macOS dev
- **Location**: docs/specs/effect-node-protocol.md (section "Codable conformance"), docs/specs/preset-format.md (section "Format"), docs/specs/audio-graph.md (section "snapshot and restore")

**Finding**:

`EffectNode` is declared `AnyObject, Codable` and the default extension provides `encode(to:)` by delegating to `snapshot()`. The protocol acknowledges that `init(from:)` cannot be provided by the protocol and must be implemented by each concrete type. The graph's `nodes` array is `[any EffectNode]`, and serialization to `.tnf` requires a discriminated-union pattern keyed on `typeIdentifier`. The effect-node-protocol spec says "see `docs/specs/preset-format.md`," and preset-format.md describes the JSON output but does not describe the Swift Codable plumbing that produces or consumes it.

Concretely, decoding a `GraphPreset.nodes` requires either a custom `init(from:)` on `GraphPreset` that reads each node's `typeIdentifier`, then dispatches to the matching concrete type's `init(from:)` via the `EffectNodeRegistry`, or a different approach (a discriminator enum wrapping all known types). The bundle implies the first approach but never writes it down. Without specification, the Phase 2 author will improvise, and the improvisation may not survive contact with V2's AUv3 additions (since `AUv3Node` would need to be discoverable via the registry too).

**Recommendation**:

Add a short subsection to preset-format.md called "Swift Codable mechanism" that pins the approach: `GraphPreset` has a custom `init(from decoder:)` that for each node reads `typeIdentifier` from the JSON, looks up the type in `EffectNodeRegistry.shared`, and calls that type's decoder. The same approach scales to AUv3 because `AUv3Node` would register at app launch like any other type. Include the canonical 20-30 lines of Swift in the spec so the implementer has something to copy.

---

### F-009: Loopback re-entry on phase REVISE is undefined in state.json schema

- **Severity**: Low
- **Confidence**: High
- **Persona(s)**: PM
- **Location**: docs/orchestration/plan.md (section "Phase summary," "What 'complete' means"), docs/orchestration/state.json (`_schema_note`), docs/orchestration/phases/04-polish-release.md (section "Failure modes" — `[REVISE: <what>]` handling)

**Finding**:

Phase 4's failure path includes "the orchestrator returns to whichever phase covers the issue (likely 2 or 3) and re-runs that phase's work, then re-runs Phase 4." The state.json schema notes valid statuses as `pending | in_progress | passed | failed | blocked` and the orchestrator transitions a phase from pending/blocked to in_progress, then to passed on verification. The schema does not document what happens to a phase that's already passed but is being re-entered. Does it transition `passed → in_progress`? Does a re-run produce a second verification report at `phase-N-rerun-K.md` (which exists for re-runs after FAIL, but not for re-runs after a downstream REVISE)? Does `state.json` track the loop?

This is small but it's the kind of detail that bites at the wrong moment — Phase 4 user-acceptance is the most stressed point in the build, and the orchestrator hitting an undefined state transition there means more user back-and-forth at the worst time.

**Recommendation**:

Add one paragraph to the state.json schema note: when REVISE drops the build back to phase N, that phase transitions `passed → in_progress`, the orchestrator writes a new verification report under a `-revise-K` suffix on completion, and `state.json` records the loop in `human_inputs` for traceability.

---

### F-010: ScreenCaptureKit "fallback as contained change" oversells the modularity

- **Severity**: Low
- **Confidence**: Medium
- **Persona(s)**: macOS dev
- **Location**: docs/decisions/ADR-001-capture-api.md (section "Alternatives considered" — ScreenCaptureKit paragraph), docs/specs/capture.md (overall structure)

**Finding**:

ADR-001 says ScreenCaptureKit "retains some appeal as a fallback if Core Audio Process Taps prove untenable" and that "the architecture in `docs/specs/capture.md` is structured so that swapping the capture backend would be a contained change." Reading capture.md, the structure is not actually backend-agnostic: the CaptureController API references aggregate devices, AudioObjectIDs, and HAL property setters in its concrete-class implementation, and the public protocol exposes nothing that abstracts over the underlying capture mechanism. Swapping to ScreenCaptureKit would mean replacing the implementation entirely, which is fine but isn't "contained" in any meaningful sense.

This is a small bit of authority-laundering: ADR-001 leans on the swap-out clause to make the choice feel low-risk. The actual risk is the same as committing to any single backend.

**Recommendation**:

Soften ADR-001's language: state that the backend choice is committed for V1 and that switching backends would be a substantial rewrite, not a contained change. Or, if the architectural intent is to keep backends swappable, factor capture.md's CaptureController behind a smaller protocol surface that genuinely could accept either implementation. The first option is lower-cost.

---

### F-011: CodeRabbit template repo dependency may leak content into a public repo

- **Severity**: Low
- **Confidence**: Medium
- **Persona(s)**: Security
- **Location**: docs/orchestration/phases/00-init.md (section 0.5)

**Finding**:

Phase 0 clones `loganrooks/coderabbit` (potentially private) into `/tmp/coderabbit-template`, copies the local config template, "adapts it for this project, and commits the resulting `.coderabbit.yaml` to the repo root." The tap-n-filter repo is public. If the source template contains anything sensitive — internal review rules referencing private services, API keys for paid lint tooling, references to internal repo names that shouldn't be public — the "adapts" step is the only guard, and the spec doesn't say what to look for during adaptation.

The base rate for a CodeRabbit config containing real secrets is low (these files are mostly behavior tuning), but a template explicitly described as "canonical config and instructions" copied across repos could include URLs or repo names the user would prefer to keep private.

**Recommendation**:

Add one sentence to Phase 0.5: "Before committing the adapted `.coderabbit.yaml`, scan for references to private repos, internal services, or API keys. If any are present, remove them or replace with public-safe equivalents." This is a small change and the cost is one extra read pass during Phase 0.

---

### F-012: U-005 ear-test input licensing is left dangling until Phase 2

- **Severity**: Low
- **Confidence**: High
- **Persona(s)**: PM, Security
- **Location**: docs/decisions/uncertainty-log.md (U-005), docs/orchestration/phases/02-dsp-chain.md (section 2.8)

**Finding**:

The ear-test harness depends on a 30-second audio clip whose licensing status is genuinely uncertain. U-005 logs the options (user-provided personally-licensed clip; synthetic test signal; CC-licensed engine recording). Phase 2 plans to escalate via `[ESCALATION: ear-test-input-source]`. This is fine procedurally, but it puts the ear-test gate at risk of stalling mid-build over an asset question that could be settled now. The synthetic-signal fallback (sine sweep, pink noise) is fast to implement and probably the right default — it lets the ear test verify the DSP technically, with the aesthetic check happening separately when the user provides a clip.

**Recommendation**:

Decide now: ship the harness with a synthetic test signal as default input, and offer a CLI flag for the user to point at their own clip when they're ready for the aesthetic ear-test. This makes the Phase 2 gate runnable without the escalation, and the aesthetic check becomes a one-line user action ("I dropped my clip at ~/Music/onboard.wav and re-ran the harness; here are the artifacts"). Add an ADR-006 (or update U-005) capturing this.

---

## Cross-cutting observations

The bundle's strongest pattern is the honesty in ADRs and the decision-rationale doc: alternatives are described enough that an outsider can see why they were rejected, and the naming ADR in particular pre-flags the failure mode the audit was asked to look for. The dissent log and uncertainty log conventions are right and the structure (open + best guess + resolution path + revisit trigger) is more useful than typical "issues" tracking.

The bundle's weakest pattern is in the technical Swift snippets across capture.md, effect-node-protocol.md, and audio-graph.md. Several of these compile-by-eye but not against the actual APIs (F-001, F-002), or invoke patterns the lifecycle docs of `AVAudioEngine` warn against (F-002). The author has been more rigorous about process and structure than about API-level verification. Given that the build is performed by an agent that will follow these snippets closely, the risk of "the spec said do X, I did X, it doesn't compile" is concentrated in this layer.

A second pattern: several gate criteria across phases are self-administered by the orchestrator and read by the verification subagent. The verification subagent's job is to evaluate evidence, and where the evidence is itself an orchestrator-written file (accessibility audit, "non-silent audio observed by me"), the gate becomes structurally soft. The audit-protocol's audit-lite question partially compensates by asking whether the orchestrator introduced unsound additions, but it cannot catch a sloppy self-report. Programmatic checks where they exist (snapshot tests, codesign --verify) are the right kind of gate; manual checks where the orchestrator is the only witness are the soft kind. F-006 captures the most concerning case but the pattern is broader.

A third smaller pattern: the bundle is large enough that the audit, the audit-response, and each verification subagent all read substantial subsets. This is acceptable for a single build, but if the agent-driven scaffolding is reused for future projects, the size-vs-coverage trade-off is worth tracking. Not a finding — just an observation for the reusable-pattern goal mentioned in the design rationale.
