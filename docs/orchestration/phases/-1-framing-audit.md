# Phase -1: Framing Audit

The framing audit runs before any code is written. Its job is to find load-bearing flaws in the design bundle while changing them is still cheap. A bad foundational decision discovered in Phase 3 costs days. The same decision caught in Phase -1 costs an hour.

## Purpose

Identify and resolve issues in the design bundle (everything under `docs/`) before the build begins. Specifically:

1. Decisions presented with weak or post-hoc reasoning.
2. Aesthetic preferences disguised as technical choices.
3. Unstated alternatives that should have been considered.
4. Authority laundering — citing sources as if they settled a question without engaging with applicability.
5. Scope creep disguised as forward-looking design.
6. Load-bearing assumptions left implicit.
7. Conflation of "user said X" with "user meant Y."

A senior software engineer or product manager doing a design review would catch these. This phase has the same effect, performed by a cold-context Claude Opus subagent reading the bundle for the first time.

## Inputs

The framing auditor reads, in order:

1. `docs/audits/design-rationale.md` — author's account of why the bundle is structured as it is. This is the artifact the auditor cross-checks the bundle against.
2. `docs/orchestration/plan.md` — overall phase plan.
3. All phase specs under `docs/orchestration/phases/`.
4. All spec docs under `docs/specs/`.
5. All ADRs under `docs/decisions/`.
6. The dissent log and uncertainty log under `docs/decisions/`.
7. The governance protocols under `docs/governance/`.

The auditor does not read code. There is no code yet.

## Process

### Step 1: Spawn the framing auditor

The orchestrator spawns a Task subagent of type `general-purpose` with the auditor prompt template at `docs/governance/audit-protocol.md`. The prompt is verbatim, with the inputs listed above attached. The auditor returns a structured report following the schema in `docs/governance/audit-protocol.md`.

The auditor writes its report to `docs/audits/framing-audit-001.md`. The orchestrator commits this report as-is — the orchestrator does not edit the auditor's findings.

### Step 2: Spawn the audit-response agent

The orchestrator spawns a second Task subagent — separate fresh context — with the audit-response prompt template at `docs/governance/audit-response-protocol.md`. Inputs are:

- The audit report from Step 1.
- The full design bundle (same inputs as the auditor).
- The escalation criteria at `docs/governance/escalation-criteria.md`.

The audit-response agent produces, for each finding in the audit:

- An action: `address`, `disagree`, or `escalate`.
- The actual response: revised text for an `address`, reasoning for a `disagree`, the question to ask the user for an `escalate`.

The audit-response agent writes its responses to `docs/audits/audit-response-001.md` and commits.

### Step 3: Process escalations

The orchestrator reads `audit-response-001.md`. For each finding tagged `escalate`, the orchestrator surfaces `[ESCALATION: audit-001-<finding-id>]: <question text>` in transcript and waits for user response. Multiple escalations can be surfaced together. The orchestrator records user responses in `state.json` under `human_inputs.audit_escalations`.

If there are no escalations, this step is skipped.

### Step 4: Address findings

For each finding tagged `address`, the orchestrator applies the revision described in `audit-response-001.md`. Revisions can include: editing spec docs, editing phase docs, adding ADRs, adding uncertainty log entries, removing scope from V1.

For each finding tagged `disagree`, the orchestrator records the disagreement reasoning in `audit-response-001.md`. No change to other docs is required, but the disagreement entry serves as documentation for future readers.

The orchestrator commits all changes from Step 4 in a single commit with message `audit: address findings from framing-audit-001`.

### Step 5: Re-verify

After all findings are processed, the orchestrator runs the standard verification subagent (per `docs/governance/verification-protocol.md`) against this phase's gate criteria. The verification subagent reads the audit report, the response, the user escalation responses (if any), and the current state of the bundle, and returns PASS or FAIL.

## Gate criteria

Phase -1 gate PASSES when all of the following are true:

1. `docs/audits/framing-audit-001.md` exists and follows the schema in `docs/governance/audit-protocol.md`.
2. `docs/audits/audit-response-001.md` exists and has a response for every finding in the audit.
3. Every High-severity finding has either been addressed (`action: address`) or documented with explicit accepting reasoning (`action: disagree`) or resolved via user escalation (`action: escalate` with user response recorded in `state.json`).
4. No finding remains in `unresolved` state.
5. All revisions described in `audit-response-001.md` have been applied to the corresponding docs in this commit.
6. The verification subagent returns PASS.

If any High-severity finding remains unresolved after Step 4, the orchestrator returns to Step 3 (escalate to user) rather than advancing to Step 5.

## Failure modes

- **Auditor returns no findings.** Treat with suspicion. An audit that finds nothing in a multi-thousand-line bundle is likely a verification failure of the audit, not a genuinely clean bundle. The orchestrator should re-spawn the auditor once with a stronger prompt invocation. If the second run also returns no findings, log the result in the uncertainty log and proceed — but the verification subagent's framing-audit-lite question will treat this as a flag.
- **Auditor returns dozens of low-severity findings and few high-severity ones.** This is acceptable. Low-severity findings can be batch-disagreed-with by the audit-response agent with a single justification line. The point is the high-severity ones.
- **Audit-response agent escalates every finding.** Treat with suspicion. The response agent's job is to resolve what it can resolve, escalating only on the criteria in `escalation-criteria.md`. If it escalates everything, the orchestrator surfaces `[ESCALATION: audit-response-agent-over-escalating]` and asks the user to either re-prompt the agent or override it.

## Outputs

- `docs/audits/framing-audit-001.md` — auditor's report.
- `docs/audits/audit-response-001.md` — response document, one entry per finding.
- Updates to any of `docs/orchestration/`, `docs/specs/`, `docs/decisions/`, `docs/governance/` per Step 4.
- `state.json` updated: phase `-1` to `passed`, current_phase to `0`, audit_report and audit_response paths recorded.
- A commit per major step (audit committed separately from response committed separately from address-findings commit).
- No PR for Phase -1 — the audit runs against the as-scribed bundle in the working directory before any feature branch exists. Phase 0 opens the first PR.

## Duration

Estimated 5–15 orchestrator turns. Most of the time is the auditor and audit-response subagent runs (each is one turn from the orchestrator's perspective). Step 4 may add several turns if there are many findings to address.

If Phase -1 exceeds 25 turns, surface `[ESCALATION: phase-minus-1-runaway]` and wait for guidance.
