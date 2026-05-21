# /goal prompt

This file contains the exact `/goal` condition text to use when launching the agent-driven build of tap-n-filter. Paste the contents of the fenced block below as the argument to `/goal` in a fresh Claude Code session opened in this repository.

## Prerequisites

Before running `/goal`:

1. You are in a Claude Code session with auto-mode enabled (`/auto`) and reasoning set to max.
2. Your working directory is the root of the tap-n-filter repo (this directory).
3. You have accepted the workspace trust dialog. `/goal` does not run without it.
4. You have `gh` authenticated and configured for your account.
5. You have Xcode 16+ installed with the macOS 14.4 SDK.
6. You have the Codex GitHub App and CodeRabbit GitHub App installed and authorized for your account (Phase 0 will verify and surface clear errors if missing).

## The condition

```
The tap-n-filter project is complete when ALL of the following are true:

(a) docs/orchestration/state.json exists, validates against its schema, and shows status="passed" for every phase from "-1" through "4".
(b) docs/orchestration/state.json field "release_candidate_path" points to a signed, notarized .dmg or .app at that path.
(c) The transcript of this session contains the exact string "[EAR_TEST: PASS]" written by the user (Phase 2 gate).
(d) The transcript contains the exact string "[ACCEPT]" written by the user (Phase 4 gate).
(e) The main branch on GitHub has a v0.1.0 release tag.

You are the orchestrator for this build. On your first turn, read in this order: docs/orchestration/plan.md, docs/orchestration/state.json, docs/governance/quality-gates.md, then the phase doc for whichever phase has status="pending" or "in_progress" in state.json (initially Phase -1).

For each phase: read the phase spec under docs/orchestration/phases/, execute the work as specified, then run the verification protocol in docs/governance/verification-protocol.md. Only advance the phase status in state.json to "passed" when verification returns PASS. Do not skip phases. Do not skip Phase -1 (Framing Audit).

Decisions made during build go to docs/decisions/ as ADRs (commits), dissent-log.md (option-between-options), or uncertainty-log.md (open questions). Hidden reasoning is the failure mode the framing audit and per-phase audits look for.

For human-input gates (Phase 2 ear test, Phase 4 acceptance): produce the required artifact, surface the exact halt marker specified in the phase spec, then stop the turn and wait for the user's response. Do not advance until the user has typed the required confirmation string in chat.

Surface phase transitions with the exact format: "PHASE <N> GATE: PASS. Advancing to Phase <N+1>." or "PHASE <N> GATE: FAIL. <one-sentence reason>" or "PHASE <N> GATE: AWAITING <ear_test|acceptance>".

If you discover a load-bearing question whose answer is not derivable from the docs, halt and surface "[ESCALATION: <topic>]: <question>". Wait for user response. Update docs/decisions/ once resolved.

Stop after 200 turns. If 200 turns elapse without completion, surface a status summary referencing state.json and stop.

Do not push to main. Open a PR for every phase. Request both CodeRabbit and Codex review on each PR per docs/governance/review-protocol.md. Phases -1 through 3 self-merge after PR review and verification pass. Phase 4 waits for user [ACCEPT].
```

## Length

The condition above is approximately 2,400 characters, well under the 4,000-character `/goal` limit. It can be edited if the build surfaces structural reasons to revise, but treat edits as significant — the condition is what the build verifies against.

## What happens after you paste it

The orchestrator's first turn begins immediately with the condition as the directive. Expect the first turn to consist of: reading the plan, reading state.json, reading the Phase -1 spec, then beginning the framing audit by spawning the auditor subagent. You will not need to type anything between the start of the build and the first human-input gate.

The first time you'll be asked to do anything is the audit-response cycle, if-and-only-if the audit-response agent escalates a finding per `docs/governance/escalation-criteria.md`. If the audit goes cleanly, you skip directly to Phase 0.

Total expected turn count: 80–150 in the typical case. The cap is 200 for safety.

## Stopping early

`/goal clear` ends the goal at any point. Work in progress is preserved on disk. Resuming the session with `--resume` restores the goal if it was still active when the session ended. See https://code.claude.com/docs/en/goal.
