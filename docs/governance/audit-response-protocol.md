# Audit Response Protocol

The audit-response agent processes findings from the framing auditor (and from per-phase audit-lite questions, when those surface non-trivial issues). It runs in a fresh context separate from both the orchestrator and the auditor. It produces a structured response — one entry per finding — and either resolves findings autonomously or escalates them to the user.

## Model

The audit-response agent runs on **Opus**. The per-finding decision is rubric-driven but the rubric has edges: when the auditor's recommendation conflicts with a documented user constraint, when "Medium severity, concrete recommendation" should still be escalated because the finding cuts product scope, when a Low-severity batch-disagree is actually a missed Medium. These are judgment calls. Sonnet would default to rubber-stamping the rubric. Model selection is per `docs/governance/delegation-protocol.md`.

## Why a separate agent

The audit-response decisions need a perspective the orchestrator doesn't have: the orchestrator is the entity whose work is being audited. Asking the orchestrator to evaluate findings against its own work risks motivated reasoning. A fresh agent reading the audit, the bundle, and the escalation criteria can evaluate findings against the criteria directly.

The audit-response agent is also not the auditor itself. It's a third perspective. The audit can be wrong; the response agent can disagree. The user can override.

## Inputs

The audit-response agent receives, as its full context:

1. The audit report (`framing-audit-001.md` or per-phase equivalent).
2. The full bundle (same input set as the auditor).
3. This document (`audit-response-protocol.md`).
4. `escalation-criteria.md`.

The audit-response agent does not see the orchestrator's reasoning or the orchestrator's prior conversation. Its decisions are based on the documented bundle and the audit report alone.

## Process

For each finding in the audit, the agent decides one of three actions:

### Action: `address`

The agent agrees with the finding and proposes a specific revision. The response includes the exact text to add or change, in enough detail that the orchestrator can apply it as a literal edit.

For findings that require new ADRs, the response includes the ADR's full proposed text.

For findings that require scope reduction, the response includes the specific cuts (file paths, sections, sentences to remove).

### Action: `disagree`

The agent does not accept the finding. The response includes:
- A clear statement of the disagreement.
- The reasoning, in 1–3 paragraphs.
- Acknowledgment of what the auditor saw correctly (steelmanning before disagreeing).

Disagreements are documented in `audit-response-NNN.md` and persist. Future readers see both the finding and the disagreement.

### Action: `escalate`

The agent cannot resolve the finding autonomously and escalates to the user. Escalation is triggered when the finding meets any of the criteria in `escalation-criteria.md`. The response includes:
- A clear question for the user.
- The relevant context the user needs to answer.
- Acknowledgment of what the agent considered and why it couldn't decide.

Escalation is not a default. Most findings can be resolved by either `address` or `disagree`. Escalation is reserved for genuinely user-domain decisions.

## Decision rubric

The agent uses this rubric when choosing an action:

| Finding type | Default action |
|---|---|
| High-severity, High-confidence, with a concrete recommendation | `address` (unless the recommendation contradicts a user-provided constraint, then `escalate`) |
| High-severity, Low-confidence | `escalate` (per criterion b in escalation-criteria.md) |
| Medium-severity, with a concrete recommendation | `address` |
| Medium-severity, no concrete recommendation | `disagree` with note "no actionable alternative; flagging for record" |
| Low-severity, batch | `disagree` with a single shared justification line covering multiple low-severity findings at once |
| Anything contradicting an explicit user instruction from the conversation | `escalate` (per criterion c) |
| Anything where the audit-response agent itself lacks domain context | `escalate` (per criterion a) |

The agent applies the rubric but can deviate with documented reasoning. The rubric is a default, not a hard rule.

## Output format

The agent writes to `docs/audits/audit-response-NNN.md` (matching the audit number it responds to):

```markdown
# Audit Response 001

**Responder**: Claude (cold-context subagent, audit-response role)
**Responds to**: framing-audit-001.md
**Date**: <ISO date>

## Summary

<2–3 paragraphs. How many findings, how many addressed vs disagreed vs escalated, any cross-cutting observations on the audit itself.>

## Responses

### F-001 [audit title]

- **Action**: address | disagree | escalate
- **Confidence**: High | Medium | Low

<For `address`:>
**Proposed revision**:
- File: `docs/specs/architecture.md`
- Section: "Sandbox"
- Change: <exact text or diff>

**Rationale**: <1 paragraph>

<For `disagree`:>
**Steelman**: <what the auditor saw correctly>
**Disagreement**: <reasoning, 1–3 paragraphs>

<For `escalate`:>
**Question for user**:

> <verbatim question>

**Context**: <what the user needs to know>
**What I considered**: <agent's reasoning attempt before giving up>

---

### F-002 [audit title]

...
```

## After the response

The orchestrator reads the response document and:

1. For each `address` entry, applies the proposed revision. If the proposed revision is unclear or incomplete (e.g., refers to a section that doesn't exist), the orchestrator surfaces `[ESCALATION: audit-response-incomplete: F-NNN]` and waits for user guidance.

2. For each `disagree` entry, no document edit. The disagreement persists in the response file as the project record.

3. For each `escalate` entry, the orchestrator surfaces `[ESCALATION: audit-NNN-F-MMM]: <question>` and waits for the user's reply. The user's reply is appended to the response document under the corresponding finding, and the orchestrator then applies whatever action the user directed.

After all entries are processed, the orchestrator commits the changes and re-runs the verification subagent to confirm Phase -1's gate criteria are met.

## When the audit-response agent goes wrong

Failure modes:

- **Escalates everything.** Indicates the agent is being too conservative. The orchestrator can re-prompt with explicit instruction to use the rubric defaults, but if the second run still escalates everything, surface `[ESCALATION: response-agent-over-escalating]` and ask the user whether to override or re-prompt with different framing.

- **Addresses everything without disagreement.** Indicates the agent is rubber-stamping findings. If 100% of findings are `address` with no `disagree`s, the orchestrator runs the response agent once more with explicit prompt: "review your prior response and reconsider whether any findings should be disagreed with." If the second run still shows 100% address, the orchestrator surfaces `[ESCALATION: response-agent-no-disagreement]`.

- **Proposes revisions that contradict the conversation log.** The agent doesn't see the conversation log; it might propose changes the user explicitly rejected earlier. The orchestrator catches these via its own reading of the response document and either rewrites the revision (with a note) or escalates.

## Versioning

`audit-response-NNN.md` is committed once after first generation. Updates (e.g., after user responses to escalations) are appended to the same file with date-stamped entries, never overwritten. Hash chain: each amendment includes a short reference to the prior version.
