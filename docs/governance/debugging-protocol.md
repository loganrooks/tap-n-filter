# Debugging Protocol for Frontier Problems

This protocol governs how we debug hard problems where there is little or no
documentation to look up — problems where the cause is unknown and we are
building a causal model of an opaque system from its observable behavior.
Examples: an OS API that behaves differently from its contract, a media
pipeline that corrupts data with no error, a race that only appears in
production. The audio-pipeline investigation under
`docs/investigations/2026-05-audio-pipeline.md` is the worked example this
protocol was extracted from.

It does not govern routine bug fixes where the cause is already known or
trivially found. Those go in a commit message. Use this protocol when you
catch yourself guessing at a mechanism, or when a fix you were confident in
fails to resolve the symptom.

## The stance: post-falsificationism

We are neither naive falsificationists nor naive verificationists, and the
distinction is operational rather than academic.

Naive falsificationism holds that one contrary observation kills a
hypothesis. That fails in practice because no mechanism is tested in
isolation (the Duhem-Quine point). When a prediction fails, the failure
implicates a whole web: the proposed mechanism, every auxiliary assumption
it rests on, the correctness of the fix you wrote, and the diagnostic
apparatus reporting the result. The failure tells you *something* in the web
is wrong. It does not tell you which. You choose where to revise, and that
choice has to be made in the open and defended.

Naive verificationism holds that confirming instances prove a hypothesis.
That fails because confirmation is cheap. A coherent story that fits the
data is the normal state of affairs, not a signal of truth. Coherence is a
warning that you may be pattern-matching to a plausible narrative — a
failure mode that is sharper for an LLM assistant, which is trained toward
plausible-sounding explanations.

What replaces them is a working discipline built on three commitments.

### Obtains versus load-bearing

A condition *obtaining* and a condition being *the cause of a symptom* are
two different claims with two different standards of evidence. Keep them
apart at all times.

- "Condition C obtains" can be **source-grounded**: read the code, read the
  log, trace the path. Cheap, high-confidence. Example: "the source node
  reports 44.1 kHz while the tap is 48 kHz" — a log readback established
  this directly.
- "Condition C is the cause of symptom S" is a **causal, load-bearing
  claim**. Confirming that C obtains gives no warrant for it. The claim
  rests on an auxiliary that is almost always left unstated: "no other
  condition at this boundary contributes to S."

The failure that produced this protocol was exactly this conflation. We
source-grounded that a sample-rate mismatch obtained, then treated that as
having established the rate mismatch was the cause of the audible artifact.
It was not. A second mismatch at the same boundary (interleaved versus
planar channel layout) was the dominant cause, and its evidence had been
sitting in the diagnostic log since the first instrumented run.

### Intervention is the test of cause

The only thing that establishes load-bearing-ness is intervention: change
the condition and watch whether the symptom moves. This is the experimental
realist's position (Hacking) — a cause you can manipulate to move an effect
is a cause you have warrant to believe in.

The consequence for debugging is direct. **A fix is an intervention, and an
intervention is an experiment.** It therefore earns the same discipline as
any experiment, including pre-registration of what its outcomes will mean.
A fix is not the end of an investigation. It is the test of the hypothesis
that motivated it.

### Programmes, not single shots

Judge a mechanistic theory across a series of interventions, not on one
result (Lakatos). A series is *progressive* when each intervention makes a
novel, risky prediction that then checks out — the de-interleave fix
predicted not only that pitch would correct but that the left-shift and the
crackle would resolve and the frame count would halve, four consequences of
one mechanism. A series is *degenerating* when each step only patches the
anomaly that prompted it and predicts nothing new. A degenerating series is
the signal that you are modeling a downstream symptom rather than the cause,
and it triggers a frame check.

## The loop

Each pass through a hard problem runs these steps. The gate is step 4: no
code that targets a hypothesized cause gets written before its
pre-registration entry exists.

1. **Observe.** State the symptom in specific, checkable terms. Separate the
   raw observation from any interpretation of it. "Audio plays roughly an
   octave low, imaging shifted left, with periodic crackle" is an
   observation. "The sample rate is wrong" is an interpretation, and it does
   not belong here.

2. **Model.** Propose a mechanism that would produce the symptom. Tag it
   `source-grounded` or `behavior-inferred`. List the auxiliaries it rests
   on — the things that must also be true for this mechanism to produce this
   symptom. The auxiliaries are where the next failure will hide, so they
   are written down now.

3. **Enumerate rivals.** Before committing to the mechanism, list the other
   mechanisms that could produce the same symptom. A symptom with one
   candidate cause is usually a symptom you have not thought about hard
   enough. "Pitched down" has at least two candidate causes at a format
   boundary: a rate mismatch and a channel-layout mismatch. We checked one
   and shipped a fix; the other was the real cause.

4. **Pre-register the intervention.** Before writing the fix, write the
   Intervention entry (template below). It must contain the discriminating
   prediction, and the discriminating prediction must include the risky
   branch — what you will conclude if the fix lands and the symptom
   persists. It must also distinguish two diagnostics: the one that tells
   you the fix *landed* (e.g., a format readback showing the rate changed)
   and the one that tells you the symptom *resolved* (the ear test). Without
   both, a failed fix is ambiguous between "wrong mechanism" and "fix did
   not take effect."

5. **Intervene and observe.** Run it. Record what landed and what resolved,
   as two separate facts.

6. **Revise holistically.** On a failed prediction, enumerate the candidate
   revision sites — mechanism wrong, an auxiliary false, fix mis-implemented,
   apparatus lying — and state which one you are revising and why that one.
   Silently blaming an auxiliary to protect a favored mechanism is the
   ad-hoc move that marks a degenerating programme. When the rate fix failed
   to move the audio, the "did it land" readback showed the rate had in fact
   changed, which ruled out "fix mis-implemented" and "apparatus lying" and
   forced the revision onto "rate is not the load-bearing cause." That
   routing should have happened immediately and from the data, without
   external prompting.

7. **Appraise the programme.** After each intervention, ask whether the
   series is progressive or degenerating. Three patches without a novel
   corroborated prediction fires a frame check.

## Artifacts

The investigation notebook carries four record types. Each has a distinct
job; do not collapse them.

- **Intervention ledger.** One row per fix attempted: the target mechanism,
  its type, the auxiliaries, the locked prediction including the failure
  branch, whether the fix landed, whether the symptom resolved, and the
  revision taken on failure. This table is the searchable "have we tried
  this before" index. A future session scans it instead of re-reading the
  whole notebook. Each row links to its full experiment entry.

- **Hypothesis ledger.** Beliefs about the system, in three states: active,
  inactive, ruled-out. Never delete a ruled-out hypothesis; record its
  resurrection condition instead.

- **Experiment log.** The full pre-registered entry for each experiment and
  each intervention, with the reasoning the ledger row summarizes.

- **Frame checks.** Entries written when the programme shows signs of
  degenerating, or when a result feels suspiciously coherent, or before an
  irreversible action.

## Intervention entry template

An intervention is an experiment, so it uses the experiment template from
`docs/investigations/README.md` with two required additions: the
**load-bearing test** and the **revision-on-failure** field. A compact form:

```markdown
### EXP-NNN — <intervention title>

**Date**: YYYY-MM-DD HH:MM (local)
**Type**: intervention (fix attempt)
**Target mechanism**: <which hypothesis / candidate cause this fix assumes>
**Mechanism type**: source-grounded | behavior-inferred
**Auxiliaries** (must hold for this fix to resolve the symptom):
- <auxiliary>

**Prediction** (locked before writing the code):
- **If load-bearing**: the fix lands (diagnostic D1 shows <X>) AND the
  symptom resolves (diagnostic D2 shows <Y>).
- **Risky branch**: if the fix lands (D1 shows <X>) but the symptom
  persists (D2 still shows the artifact), then <target mechanism> is not
  load-bearing, and the revision goes to <where>.
- **Did-not-land branch**: if D1 does not show <X>, the fix did not take
  effect; the mechanism is untested and the intervention is re-run, not
  revised.

**Landed?**: <D1 result>
**Resolved?**: <D2 result>
**Revision taken**: <which web element was revised, and why that one>
```

## Anti-patterns

Named so they can be called out in review, by a subagent, or by the auditor.

- **Smoking-gun fallacy.** Declaring a cause from a confirmed *condition*
  without an intervention that moves the symptom. The word "confirmed" is
  reserved for a load-bearing claim that survived an intervention.
- **Coherence capture.** Accepting the first mechanism that fits the data
  and skipping rival enumeration.
- **Silent web-repair.** On a failed prediction, quietly blaming an
  auxiliary to keep a favored mechanism alive.
- **Ambiguous fix.** Shipping a fix with no diagnostic that separates "did
  not land" from "landed but symptom persists."
- **Degenerating patch series.** Each fix explains only the anomaly that
  prompted it and predicts nothing new.

## Enforcement

The protocol binds through the project instructions in `CLAUDE.md`: a fix
that targets a hypothesized cause in an area under active investigation
requires a pre-registered Intervention entry before the code is written.
The phase verification subagent and the auditor check that fix-bearing
commits in those areas have matching Intervention entries, and that the
entries carry a genuine discriminating prediction rather than a
fill-in-the-blank one. Existence of an entry is mechanically checkable;
the quality of the prediction is a judgment the auditor makes.
