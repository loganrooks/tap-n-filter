# Phase -1 Verification

**Verifier**: Claude (verification subagent, cold context)
**Date**: 2026-05-20
**Phase**: -1 — Framing Audit
**Verdict**: PASS

## Gate criteria assessment

### Criterion 1: `docs/audits/framing-audit-001.md` exists and follows the schema in `docs/governance/audit-protocol.md`.

**Status**: Met

**Evidence**:

`docs/audits/framing-audit-001.md` exists (28k, committed in 679e327 — "audit: framing-audit-001 (3 High, 6 Medium, 3 Low findings)"). I compared the file against the schema in `audit-protocol.md` under "Report schema":

- Header block: present. Includes "Auditor", "Date", "Inputs" (lists 29 input files), "Approach" (names the three personas).
- Summary: present, ~4 paragraphs covering bundle state, weakest sections (capture spec, EffectNode protocol), strongest sections (ADR discipline), and a recommended disposition.
- Findings: 12 entries numbered F-001 through F-012, each with the required fields (**Severity**, **Confidence**, **Persona(s)**, **Location**, **Finding**, **Recommendation**). Severity distribution: 3 High (F-001, F-002, F-007), 6 Medium (F-003, F-004, F-005, F-006, F-008), 3 Low (F-009, F-010, F-011, F-012). One Medium I miscount: rechecking — F-003 M, F-004 M, F-005 M, F-006 M, F-008 M; F-009 L, F-010 L, F-011 L, F-012 L → 3H/5M/4L total. Either way the counts match the commit message (3H/6M/3L) closely enough that the schema fit holds; the slight count drift is in the file itself (the commit-message author classified one item differently than I'm reading it), not in schema conformance.
- Cross-cutting observations: present, three patterns described.

The tone matches what `audit-protocol.md` calls for (a colleague's review, not sycophancy or adversarial-for-show). The High-severity findings are concrete and consequential, not used as a default tag.

### Criterion 2: `docs/audits/audit-response-001.md` exists and has a response for every finding in the audit.

**Status**: Met

**Evidence**:

`docs/audits/audit-response-001.md` exists (72k, committed in e3654d6 — "audit: audit-response-001 (11 address, 0 disagree, 1 escalate)"). I verified one response section per finding by listing the `### F-NNN:` headings in both files:

- Audit (`framing-audit-001.md`): F-001 through F-012 (12 headings).
- Response (`audit-response-001.md`): F-001 through F-012 (12 headings, exactly matching).

Each response has an explicit `**Action**:` field. The actions count: 11 `address`, 1 `escalate` (F-005, marked "escalate (resolved autonomously, see 'User response' below)"). The escalation rate (1/12 = 8.3%) is well under the audit-response protocol's over-escalation threshold per the response's own summary.

### Criterion 3: Every High-severity finding has either been addressed (`action: address`) or documented with explicit accepting reasoning (`action: disagree`) or resolved via user escalation (`action: escalate` with user response recorded in `state.json`).

**Status**: Met

**Evidence**:

Three High-severity findings: F-001, F-002, F-007. All three are tagged `address` in the response document. I confirmed the revisions described in each response landed in the target docs:

- **F-001** (pid_t → AudioObjectID): The revision required rewriting `docs/specs/capture.md`'s "Process tap creation" and "Aggregate device creation" subsections to add the explicit pid→AudioObjectID translation via `kAudioHardwarePropertyTranslatePIDToProcessObject`, and updating `CaptureSource` in `docs/orchestration/phases/01-capture-spike.md` to carry both `pid` and `audioProcessID`. I read `capture.md` lines 59-167 and `01-capture-spike.md` lines 99-125. Both revisions are present verbatim. The new `CaptureError.sourceNotFound(pid_t)` case and the "Process not registered with Core Audio" failure-mode note also appear as specified.

- **F-002** (EffectNode bus typing and engine lifecycle): The revision required (a) tightening `EffectNode` to expose `inputBus` and `outputBus` as `AVAudioMixerNode` rather than `AVAudioNode`, (b) replacing the wet/dry mixing convention to document per-input-bus volume mechanics, (c) replacing the `audio-graph.md` `attach` subsection to require `engine.stop()` rather than `engine.pause()`, (d) replacing "Graph mutations during playback" to the same effect, (e) creating `ADR-006-graph-mutation-lifecycle.md`. I confirmed:
  - `effect-node-protocol.md` lines 7-60 show the revised protocol with `AVAudioMixerNode` typing on both buses.
  - `effect-node-protocol.md` lines 99-126 show the new wet/dry mixing convention with per-input-bus volume mechanics.
  - `audio-graph.md` lines 48-60 show the revised `attach` subsection with the not-started-or-fully-stopped engine precondition.
  - `audio-graph.md` lines 96-109 show the revised "Graph mutations during playback" section using `engine.stop()`.
  - `docs/decisions/ADR-006-graph-mutation-lifecycle.md` exists (66 lines, Status: Accepted, with the full Context/Decision/Alternatives/Consequences/References sections).

- **F-007** (stale permission UI and entitlement details): The revision required updating `capture.md`'s "Permission handling" section, replacing `01-capture-spike.md` section 1.3, replacing `04-polish-release.md` section 4.3, and adding U-008. I confirmed:
  - `capture.md` lines 194-202 show the revised permission handling, with explicit "verify against the orchestrator's current macOS version" language and U-008 reference.
  - `01-capture-spike.md` lines 133-143 show the revised section 1.3 with the verification steps spelled out.
  - `04-polish-release.md` lines 38-49 show the revised "Code signing" section. `com.apple.security.device.audio-input` is now mentioned only as a counterexample ("the microphone-hardware entitlement for sandboxed apps; adding it to an unsandboxed app has no documented effect…"), not as a required entitlement.
  - `uncertainty-log.md` lines 126-136 show the new U-008 entry, marked Open, with both parts of the question.

No High-severity finding was escalated. The one escalation (F-005) is Medium-severity.

### Criterion 4: No finding remains in `unresolved` state.

**Status**: Met

**Evidence**:

I reviewed the action assignments for all 12 findings:

- F-001, F-002, F-003, F-004, F-006, F-007, F-008, F-009, F-010, F-011, F-012: `address` (11 total).
- F-005: `escalate (resolved autonomously, see 'User response' below)`.

F-005's escalation is annotated with the autonomous-resolution note and a "Resolution applied" line stating "Option 1 — cut to two presets. Implemented during the address-findings commit." The user-response field in the response document records the orchestrator's autonomous-call language under "User response (appended 2026-05-20)". I verified the resolution landed: `preset-format.md` line 170 now reads "`submerged` and `next-room` were considered during scribing but cut from V1 per audit finding F-005 (`docs/audits/framing-audit-001.md`); they are deferred to V0.2 as TODOs in `CHANGELOG.md`." `state.json` records the escalation and the autonomous resolution under `human_inputs.audit_escalations` (lines 67-82).

No finding is in an `unresolved` state; the response document has no findings without an `**Action**:` field, and no `address`-tagged finding is missing its revision (see Criterion 5).

### Criterion 5: All revisions described in `audit-response-001.md` have been applied to the corresponding docs in this commit.

**Status**: Met

**Evidence**:

I spot-checked the revisions across all 11 `address`-tagged findings and the autonomous F-005 resolution:

- F-001 (capture.md, 01-capture-spike.md): Verified above under Criterion 3.
- F-002 (effect-node-protocol.md, audio-graph.md, ADR-006): Verified above.
- F-003 (02-dsp-chain.md section 2.9 + new gate criterion 3): Verified by reading `02-dsp-chain.md` lines 226-246 (new section 2.9 with the live-render check spec) and the renumbered gate criteria 1-4 at lines 250-259.
- F-004 (effect-node-protocol.md "When wet/dry is meaningful" subsection, ui.md per-row text, ADR-007): Verified. `effect-node-protocol.md` lines 128-134 have the new subsection. `ui.md` lines 118-120 have the revised "wet/dry slider is visible by default for time-domain effects" text and the `showsWetDryByDefault` reference. `ADR-007-wet-dry-on-eq.md` exists (77 lines, Status: Accepted).
- F-005 (preset-format.md, 03-ui-control.md, 04-polish-release.md): Verified. `preset-format.md` line 170 documents the cut. `03-ui-control.md` line 13 lists the "Factory Presets" submenu as containing "`distant-engines` and `dry` (the two V1 bundled presets...)". `04-polish-release.md` line 88 (CHANGELOG entry) says "Two bundled presets: distant-engines (the motivating preset) and dry (a baseline)".
- F-006 (03-ui-control.md section 3.8, gate criterion 5, 01-capture-spike.md gate criterion 2): Verified. `03-ui-control.md` lines 117-140 have the revised section 3.8 with both the programmatic and the manual VoiceOver parts. Gate criterion 5 at line 160 references both parts. `01-capture-spike.md` line 169 has the revised criterion 2 with the level-check requirement (RMS > -60 dBFS).
- F-007 (capture.md, 01-capture-spike.md, 04-polish-release.md, uncertainty-log.md): Verified above under Criterion 3.
- F-008 (preset-format.md "Swift Codable mechanism" subsection, effect-node-protocol.md Codable conformance): Verified. `preset-format.md` lines 78-150 have the new "Swift Codable mechanism" subsection with the GraphPreset boundary, the encoding and decoding snippets, the registry dispatch, and the V2 AUv3 note. `effect-node-protocol.md` lines 142-165 have the revised "Codable conformance" section pointing to the GraphPreset boundary.
- F-009 (state.json `_schema_note`): Verified. `state.json` lines 91 (the `_schema_note` value) contains the new sentence about REVISE re-entry, the `-revise-K` suffix convention, and the `human_inputs.other_escalations` tracking.
- F-010 (ADR-001-capture-api.md ScreenCaptureKit subsection): Verified. `ADR-001-capture-api.md` lines 35-45 now say "The fallback is a substantial rewrite, not a contained change..." with the explicit "V1 commits to the process-tap path" framing.
- F-011 (00-init.md section 0.5): Verified. `00-init.md` lines 92-93 have the new scan-for-private-references paragraph before the existing CodeRabbit-GitHub-App-verification paragraph.
- F-012 (02-dsp-chain.md section 2.8 rewrite, U-005 update, ADR-008): Verified. `02-dsp-chain.md` lines 208-224 have the revised section 2.8 with synthetic-default + --input flag. `uncertainty-log.md` U-005 (lines 82-92) marked "Resolved (ADR-008)" with the new body. `ADR-008-ear-test-input-source.md` exists (59 lines, Status: Accepted).

Beyond the per-finding revisions, the commit log shows three commits matching the protocol (`679e327` framing-audit-001, `e3654d6` audit-response-001, `cdc3b9a` audit: address findings from framing-audit-001), and the diff stats show 18 files changed totaling 1875 insertions / 103 deletions — consistent with the scope of the response.

### Criterion 6: The verification subagent (you) returns PASS.

**Status**: Met

**Evidence**:

This document is the verification subagent's report. All five preceding criteria are met. The framing-audit-lite check below does not flag unsound additions that would override the literal-criteria verdict.

---

## Framing audit-lite

**Question**: Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?

**Answer**:

The phase introduced two notable additions beyond the literal "apply the audit's recommendations" mandate, and both are sound.

The first is the autonomous resolution of F-005 under the user's `/goal` "work without stopping for clarifying questions" directive. The response document explicitly marks F-005 as `escalate` and includes the question that would have been asked, then appends an "AUTONOMOUS-RESOLUTION" section documenting that the orchestrator picked Option 1 (cut to two presets) without waiting for user input. State.json's `human_inputs.audit_escalations` records the escalation and the autonomous response so the audit trail is preserved. The reasoning given for the autonomous call is defensible — the design rationale motivates one preset, the audit recommends Option 1, the responder's preferred option is Option 1 — and the resolution is reversible (the user can override by replying with a different choice; the orchestrator commits to iterating). The framing-audit phase spec did not anticipate this pattern, but the user-level directive that drove it is explicit, and the orchestrator's handling preserves both the audit trail and the user's ability to overrule. I would have made the same call.

The second is the elaboration of the F-007 entitlement claim. The audit said `com.apple.security.device.audio-input` is the wrong entitlement for an unsandboxed process-tap app. The response went further: it not only removed the entitlement from Phase 4's required-entitlement list, it also added counterexample language to Phase 4 explaining why the entitlement does nothing for an unsandboxed app, and it added U-008 tracking the verification step. I checked ADR-003-no-sandbox-v1.md to see whether the new counterexample language conflicted with that ADR's "Sandbox the V1 app" alternatives-considered section (which still lists `com.apple.security.device.audio-input` as an entitlement that WOULD be required IF V1 were sandboxed). The two readings are consistent: ADR-003 describes the entitlement's correct use in a sandboxed-app hypothetical; the new F-007 language describes its incorrect use in the unsandboxed V1 reality. No contradiction.

A small caveat on assumption-soundness: the F-001 response's note that `CATapDescription`'s property is `isPrivate` (not `privateTap`), and the F-001 response's reference to `stereoMixdownOfProcesses:` as AudioCap's constructor, are both load-bearing API claims that the response asks the orchestrator to verify against AudioCap source at implementation time. The response correctly flags these as "verify at implementation time" rather than asserting them as known facts. This is the appropriate level of confidence given that the audit-response agent did not have access to AudioCap's actual source. The verification step is correctly punted to Phase 1, where the orchestrator can ground-truth against the reference implementation. This is sound.

## Verdict reasoning

All six gate criteria are met. The audit report and response both exist with the right schema and the right scope; every finding has an action; every High-severity finding is addressed (none escalated or disagreed); the one escalation is Medium-severity and is recorded in state.json with the autonomous-resolution note; every revision described in the response landed in the corresponding doc; and the framing-audit-lite check found no unsound additions. The framing audit served its purpose: three High-severity findings flagged real load-bearing API errors that would have surfaced as bugs in Phase 1 and Phase 2, and the response addressed each with concrete, code-level revisions plus an ADR where the lifecycle commitment needed pinning. The two human-input-gate paths (F-005 autonomously resolved, F-007 partly punted to Phase 1 verification) are documented honestly rather than hidden. Verdict: PASS.
