# Escalation Criteria

When a subagent (audit-response, verification, or any other) encounters a decision it cannot resolve autonomously, it escalates to the user. This document specifies the criteria. Escalation is reserved for genuinely user-domain decisions; default behavior is to resolve in-agent per the rubric.

## When to escalate

A finding, decision, or condition is escalated if **any** of the following criteria are met:

### (a) Domain judgment beyond agent competence

The decision requires context the agent doesn't have access to. Examples:
- Aesthetic preferences: "is this UI consistent with what the user would like" — the agent has no access to the user's aesthetic.
- Taste-based naming: "should this preset be named X or Y" — neither name is objectively better.
- User's tolerance for trade-offs: "is a 30-minute build time acceptable for V1" — only the user can say.

### (b) High-severity finding with low confidence

The finding is High-severity per `audit-protocol.md`'s definitions, AND the agent's confidence in its proposed resolution is below 70%. High-severity issues with low-confidence resolutions are exactly the cases where a wrong autonomous decision is most costly.

### (c) Conflict with explicit user instruction

The agent's proposed resolution would contradict something the user explicitly said in the conversation log. The agent may not have the conversation log, but the design-rationale document and the phase specs capture user instructions; any proposed resolution that conflicts with documented user constraints is escalated.

### (d) Multiple irreversible choices

The decision commits the project to a path that's expensive to reverse, AND there are multiple defensible paths. Examples:
- Choice of cryptographic algorithm (rarely reversible cleanly).
- Choice of network protocol (downstream lock-in).
- Choice of binary file format that will accumulate artifacts in user data.

For tap-n-filter V1, this criterion rarely applies — the architecture is local-only and the file format (`.tnf`) is text-based and versioned.

### (e) Cost or quota considerations

The decision involves spending real money, consuming a quota (API calls, GitHub Actions minutes, signing certificate slots), or otherwise has a resource cost beyond what's been pre-authorized. The user has authorized the build itself; new resource expenditures need a check-in.

## When NOT to escalate

Escalation has a cost: it interrupts the user's flow and asks them to context-switch. Default to autonomous resolution unless one of the criteria above applies.

Do NOT escalate for:

- Routine technical decisions covered by the spec.
- Findings the agent can resolve with reasonable confidence.
- Things the agent would prefer the user to confirm "just in case."
- Anything where one option is clearly better than another by the rubric in `audit-response-protocol.md`.
- Multiple low-severity findings that can be batch-disagreed-with.

If the agent is genuinely uncertain whether to escalate, default to resolving autonomously and documenting the reasoning. The orchestrator and the user can revisit later if the resolution turns out badly. Better to make a decision and document it than to escalate every uncertain call.

## How to escalate

Escalations from the audit-response agent are recorded in the response document and surfaced by the orchestrator via the marker `[ESCALATION: <topic>]: <question>`. The `<topic>` is a short identifier (e.g., `audit-001-F-007`, `signing-identity-missing`). The `<question>` is the verbatim question for the user.

Escalations from the verification subagent are recorded in the verification report and surfaced the same way.

Escalations from the orchestrator itself (when the orchestrator hits something the docs don't cover) use the same marker format.

## What the user sees

When an escalation is surfaced, the user sees something like:

```
[ESCALATION: signing-identity-missing]: I ran `security find-identity -v -p codesigning` 
and found no Developer ID Application certificate. Options:

1. You obtain a certificate via Apple Developer Program ($99/year) and re-run.
2. We proceed with ad-hoc signing. Users will need to bypass Gatekeeper to install.
3. We pause Phase 4 until you have a certificate.

Which would you like?

The orchestrator is waiting. Reply with the option number or describe an alternative.
```

The user replies in chat. The orchestrator records the reply in `state.json` under `human_inputs` and proceeds.

## Recording escalations

Every escalation that goes to the user is recorded:

- Question, timestamp, agent that raised it.
- User's response, timestamp.
- Resolution: what action was taken.

These live in `state.json` (`human_inputs.audit_escalations` and `human_inputs.other_escalations`) and are referenced from the corresponding audit response or verification report.

## Examples

**Should escalate**:
- "The audit found that the capture API choice (Core Audio Taps) may not work on a future macOS version. Do you want to commit to it for V1?" — criterion (a): user's tolerance for forward-compatibility risk.
- "The Codex GitHub App is not responding to `@codex review` on the test PR. Do you want me to wait, retry with a different invocation, or proceed without Codex review for now?" — criterion (a): user knows their account state.
- "Notarization has failed three times with different errors. The pattern suggests an issue with the signing identity. Should I investigate further or escalate the signing setup as a separate task?" — criterion (b): high-severity (release-blocking), low-confidence (the cause isn't yet clear).

**Should NOT escalate**:
- "The audit suggested using `AVAudioUnitEQ` band 0 as the high-pass filter. Should I do that?" — covered by the spec. Just do it.
- "Should the slider for `wetDryMix` use a linear or logarithmic mapping?" — agent's call per the spec's parameter mapping guidance.
- "The audit said the test for X is missing. Should I add it?" — yes, obviously. Don't escalate.

## Escalation fatigue

The agent monitors its own escalation rate. If more than 20% of findings in a single audit response result in escalations, the agent flags this as a potential over-escalation in the response document's summary, and the orchestrator re-prompts as described in `audit-response-protocol.md`'s failure modes.

User-side, if the user receives more than three escalations in a single phase, the orchestrator additionally surfaces a meta-message: "I've raised three escalations this phase. If this seems excessive, it may indicate the phase spec is under-specified. Let me know if you'd like me to pause and revise the spec before continuing."
