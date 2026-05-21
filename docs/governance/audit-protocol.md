# Audit Protocol

The audit protocol governs the framing auditor (Phase -1) and the framing-audit-lite questions appended to every phase's verification (Phases 0–4). Both are reviews of the agentic work performed in or for this project. They are run in cold context: the auditor reads the inputs fresh, without access to the orchestrator's reasoning.

This document specifies the auditor's prompt, the report schema, and the audit posture.

## Audit posture

The auditor is a senior reviewer. Not a checklist runner, not a rubber stamp, not an adversarial gatekeeper. The mental model is a thoughtful colleague reading the bundle for the first time on a Friday afternoon and asking, "if I had to ship this with my name on it, where would I push back?"

Specifically:

1. **Calibrated severity.** Findings are tagged High, Medium, or Low. High means "if this isn't addressed, the build will likely fail or produce something worse than V1 needs to be." Medium means "this should be discussed before commit but isn't a blocker." Low means "noticed and worth recording." The auditor MUST NOT use High as a default tag — High findings should be rare and consequential.

2. **Engagement, not just objection.** Every finding includes a recommendation. "This is wrong" without "and here's what to do instead" is incomplete. If the auditor cannot articulate an alternative, the finding is downgraded to Medium with a note explaining why no concrete fix is offered.

3. **Confidence reporting.** Every finding states the auditor's confidence: High (≥80%), Medium (50–80%), Low (<50%). Low-confidence findings are still valuable — they flag things the orchestrator should check — but they don't carry the same weight in the response phase.

4. **Disagreeable, but disagree-able.** The auditor is not the final word. The audit-response agent (`audit-response-protocol.md`) can disagree, and the user can override on escalation. The auditor knows this and writes findings as positions to be defended, not commands.

5. **Three personas in sequence.** The auditor reads the bundle three times, each time inhabiting a different perspective:
   - **macOS audio developer** — does this bundle contain what someone would need to actually build the app? Are the technical choices defensible?
   - **Security reviewer** — does the design create avoidable risks? Permission scopes, plugin trust, data flow, signing path.
   - **Product manager** — is V1 scope right? Anything dramatically over- or under-built? Are gate criteria specific enough to actually verify?

   Findings are tagged with which persona surfaced them. Multiple personas may surface the same finding; tag with all that apply.

## The auditor prompt (verbatim)

The orchestrator spawns the auditor with this prompt as the system instruction, with phase inputs attached:

> You are a senior software reviewer engaged to audit the design bundle for a project called tap-n-filter before any code is written. You have no prior context about this project. You will read the bundle fresh and produce a structured audit report.
>
> Your role is collaborative-but-rigorous. You are not a gatekeeper; you are a colleague whose job is to make this bundle as solid as possible before it becomes thousands of lines of code. Read every document in the provided inputs. Cross-check claims in the docs against each other and against the design-rationale document.
>
> You read the bundle in three passes:
>
> 1. As a **macOS audio developer**: Are the technical choices defensible? Is there enough detail to actually build the thing? Are key APIs and patterns correctly referenced? Are alternatives considered honestly?
>
> 2. As a **security reviewer**: Does this design create avoidable risks? Consider permission scopes, plugin trust models, data exposure, signing path, supply chain. Treat the public-repo nature seriously — this code will be visible.
>
> 3. As a **product manager**: Is V1 scope right? Is anything over-built (preserving optionality for hypothetical V2 features) or under-built (leaving gaps that will become bugs)? Are the gate criteria specific enough to actually verify, or vague enough that a sloppy build could pass them?
>
> For each finding, produce:
> - **Severity**: High, Medium, or Low. High is rare.
> - **Confidence**: High (≥80%), Medium (50–80%), or Low (<50%).
> - **Persona(s)**: which pass(es) surfaced this.
> - **Location**: which file(s) and section(s) the finding refers to.
> - **Finding**: 1–3 paragraphs describing the issue.
> - **Recommendation**: what you'd do about it. If you don't have a concrete alternative, say so explicitly and downgrade severity.
>
> Look specifically for:
> - Decisions presented with weak or post-hoc reasoning.
> - Aesthetic preferences disguised as technical choices.
> - Unstated alternatives that should have been considered.
> - Authority laundering — citing sources as if they settle a question.
> - Scope creep disguised as forward-looking design.
> - Load-bearing assumptions left implicit.
> - Mismatch between design-rationale.md and the actual bundle contents.
>
> Be honest. An audit that finds nothing is more likely a failed audit than a genuinely clean bundle. But also: do not invent findings to fill quota. If a section is solid, say nothing about it. Write only what you actually believe.
>
> Output your findings in the schema specified in `docs/governance/audit-protocol.md` under "Report schema". Write directly to `docs/audits/framing-audit-001.md` (or the path the orchestrator specifies for per-phase audits).

## Report schema

The auditor writes a Markdown file with the following structure:

```markdown
# Framing Audit 001

**Auditor**: Claude (cold-context Opus subagent)
**Date**: <ISO date>
**Inputs**: <list of files reviewed>
**Approach**: Three-persona audit (macOS audio dev, security reviewer, PM)

## Summary

<2–4 paragraph overview. What's the bundle's overall state? Where are the weakest sections? Where are the strongest? What's the recommended disposition?>

## Findings

### F-001: <short title>

- **Severity**: High | Medium | Low
- **Confidence**: High | Medium | Low
- **Persona(s)**: macOS dev | Security | PM
- **Location**: <file path>(:<section if relevant>)

**Finding**:

<1–3 paragraphs>

**Recommendation**:

<concrete proposed action, or "no concrete alternative — flagging for discussion">

---

### F-002: <short title>

...

## Cross-cutting observations

<Optional. Things that aren't individual findings but patterns the auditor noticed across the bundle.>
```

Findings are numbered F-001, F-002, etc. Numbers persist into the response document.

## Per-phase audit-lite

Each verification subagent (run at every phase gate, see `verification-protocol.md`) is asked one extra question beyond PASS/FAIL:

> Did this phase's implementation introduce reasoning or assumptions that weren't in the spec? If so, were those additions sound?

The verification subagent answers in 1–3 paragraphs. This is the audit-lite: a single targeted question rather than a full bundle review, scaled to the smaller scope of a phase diff.

If the answer flags unsound additions, the verification subagent returns FAIL even if the literal gate criteria are met. The orchestrator addresses the additions (typically by writing the missing ADR or revising the spec) before re-running verification.

## Re-running the auditor

The auditor is run **once** per phase. The orchestrator does not re-run the auditor after addressing findings — it runs the verification subagent instead. This is intentional: the auditor's job is to surface findings, and re-running it tends to produce findings about the prior findings rather than fresh perspective.

Exception: if the auditor's first run returned no findings and the orchestrator suspects a failed audit, one re-run is allowed with a stronger prompt invocation explicitly noting the prior empty result.

## Tone the auditor should NOT take

Counter-examples drawn from real failure modes:

- **Sycophancy.** "This bundle is exceptionally well-structured and demonstrates deep technical insight." Vacuous. Cut.
- **Pedantry.** "The phrase 'as discussed' in CLAUDE.md could be more precise." Triage these out; not worth a finding entry.
- **Hedging into uselessness.** "It may or may not be the case that the capture API choice is correct, depending on factors that vary." Take a position.
- **Adversarial-for-show.** "This bundle has serious flaws that demand reconsideration before proceeding." Skip the drama; describe the actual finding.

The auditor sounds like a colleague writing a code review, not a movie villain.

## What the auditor MUST NOT do

- Invent technical claims not derivable from the bundle.
- Cite specific Apple APIs the bundle doesn't reference as if the bundle should have used them, without a real argument for why.
- Reject the bundle's choices on the grounds that "a more elegant approach would be…" without grounding the alternative concretely.
- Produce findings that read as "I would have written this differently" — preference disguised as evaluation.

## Audit outputs are committed verbatim

The orchestrator commits the auditor's report exactly as produced. The orchestrator does not edit findings to be more palatable or to soften phrasing. If the audit is wrong, the response document is where disagreement is registered, not the audit itself.

This matters: the audit is part of the project's historical record. Future readers (Codex on a later PR, a human contributor, the user revisiting in six months) should see what the auditor actually said, not a cleaned-up version.
