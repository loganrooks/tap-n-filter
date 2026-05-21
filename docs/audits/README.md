# Audits

This directory holds the project's audit and verification reports.

## Contents

- `design-rationale.md` — the author's account of why the bundle is structured as it is. This is the artifact the framing auditor reads alongside the bundle itself. It's not an audit; it's audit input.
- `framing-audit-NNN.md` — produced by the framing auditor (Phase -1) and any subsequent re-audits.
- `audit-response-NNN.md` — produced by the audit-response agent in response to each audit.
- `verification/phase-<N>.md` — per-phase verification reports from the verification subagent.
- `verification/phase-<N>-rerun-M.md` — re-run reports when a phase fails verification and is re-evaluated.

## Lifecycle

Reports are written once by their respective subagents and committed verbatim. The orchestrator does not edit reports.

Where a finding is addressed, the address happens in other docs (specs, ADRs, etc.), not by editing the report. The report itself remains as the project record of what the auditor or verifier said.

User escalation responses are appended to the relevant report (audit-response or verification) with date-stamped entries. The original report content above is preserved.

## Confidentiality

All reports are committed to the public repo. They contain no secrets. Findings about user-domain decisions (aesthetic preferences, naming) are written in third-person and reference the user as "the project owner" or by GitHub handle, not by personal details.

## Cross-references

Reports reference:

- The phase spec being verified (for verification reports).
- The bundle files being audited (for audit reports).
- The ADRs, dissent log entries, and uncertainty log entries created or referenced.
- The PRs and commits involved.

## Reading order for someone new to the project

If you're trying to understand why tap-n-filter is the way it is, read in this order:

1. The README for the basic project description.
2. `design-rationale.md` for the author's account.
3. The framing audit and audit response for the external perspective and any resolved disagreements.
4. The relevant ADRs (linked from both the rationale and the audit response).
5. The phase specs under `docs/orchestration/phases/` for the build-time detail.
6. The verification reports for the build-time outcomes.

The dissent log and uncertainty log provide additional texture but aren't required for a first pass.
