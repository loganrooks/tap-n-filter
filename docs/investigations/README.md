# Investigations

Long-running technical investigations that span multiple sessions and need
to survive context compaction. Each file in this directory is a **lab
notebook** for one investigation: a chronological record of experiments,
findings, environmental state, and references.

The point of these notebooks is to make work resumable from a cold start.
A future Claude (or human) should be able to read the notebook, understand
what's been tried, what was ruled out and why, and pick up the next
experiment without repeating prior work.

## Epistemic posture

These notebooks adopt a **post-falsificationist** stance. It is neither
naive falsificationism (one contrary observation kills a hypothesis) nor
naive verificationism (confirming instances prove one). Both fail in
practice, and the stance is defined by taking those failures seriously.

Naive falsificationism fails because no mechanism is tested in isolation
(Duhem-Quine): a failed prediction implicates a whole web — the proposed
mechanism, its auxiliaries, the correctness of any fix written to test it,
and the diagnostic apparatus. The failure shows something in the web is
wrong without showing which. You choose where to revise, and the choice is
made explicit and defended rather than applied silently to protect a
favored hypothesis. Naive verificationism fails because confirmation is
cheap: a coherent story that fits the data is the default, not a signal of
truth, and coherence is sharper as a warning for an LLM assistant trained
toward plausible narratives. The framework borrows from Lakatos (hypotheses
cluster into a hard core plus protective belt; a series of interventions is
progressive when it makes novel corroborated predictions and degenerating
when it only patches anomalies) and from Hacking (a cause you can manipulate
to move an effect is one you have warrant to believe).

The full procedure for using this stance while debugging — the
hypothesize, intervene, predict, revise loop and its gates — lives in
`docs/governance/debugging-protocol.md`. The commitments below are the
notebook-facing summary.

- **Distinguish source-grounded from behavior-inferred claims.** When
  you've read the code or spec and traced the path, that's
  *source-grounded* — high confidence cheaply. When you've observed
  behavior and inferred a cause, that's *behavior-inferred* — confidence
  is bounded by the auxiliaries (test apparatus, environmental state,
  diagnostic correctness). Tag every claim with one or the other.

- **Distinguish a condition that obtains from a condition that is
  load-bearing.** "C obtains" (the source node runs at 44.1 kHz) can be
  source-grounded directly. "C causes symptom S" is a separate claim that
  confirming C does not establish — it rests on the usually-unstated
  auxiliary that nothing else contributes to S. Only an intervention that
  moves S establishes load-bearing-ness. Reserve the word "confirmed" for a
  load-bearing claim that survived an intervention.

- **Treat a fix as an experiment.** A fix targeting a hypothesized cause is
  an intervention, and an intervention is the test of the hypothesis. It is
  pre-registered like any experiment, with the discriminating prediction
  written before the code. See the Intervention ledger below.

- **Pre-register predictions before running an experiment.** Write down
  what each possible outcome would mean *before* the run, including the
  risky branch — what a failed fix would force you to conclude. Locked once
  the experiment starts. This is the single most effective guard against
  post-hoc story-retrofitting.

- **Watch for paradigm trouble, not just hypothesis trouble.** When the
  protective belt of a hypothesis fails 3+ times the same way, the
  problem may not be the belt — the whole frame may be wrong (you're
  debugging a downstream symptom, not the cause). A *frame check* entry
  is mandatory at that point.

Rigor should scale with the cost of being wrong, not aspire to absolute.
For our context (engineering with shipping pressure, mostly reversible
local changes), this protocol is the minimum viable rigor. Deploy more
machinery (numeric confidence calibration, race-condition reproducibility
analysis, etc.) when the stakes justify it.

## When to start a new notebook

Start one when you have a hard technical question that will take more than
a single session to answer. Examples that qualify:

- "Why does this combination of macOS APIs behave differently than the
  documented contract?"
- "What's the right architecture for X given constraints Y and Z?"
- "Production silently fails under condition Q — root cause?"

Don't start one for narrow bug fixes that you can land in a single PR.
Those go in commit messages and code comments.

## File layout

```
docs/investigations/
  README.md                              # this file
  YYYY-MM-<topic>.md                     # one file per investigation
```

The date prefix groups them by when the investigation **started** (not the
last edit). The topic slug is the shortest phrase that disambiguates it.

## Notebook structure

Every notebook has the following sections, in this order. Keep the section
headings exact — they're the anchors a future reader scans for.

1. **Status** — one paragraph at the top with: latest understanding,
   open headline question, last-updated timestamp. This is the only
   thing a busy reader will read; make it count.

2. **TL;DR** — three to seven bullets summarising the major findings so
   far. Punchy, evidence-cited.

3. **Environment** — every variable the experiments depend on:
   macOS version, Swift toolchain, signing identity + cert hash, code
   signing requirement, CDHash, TCC services granted (per-binary), audio
   hardware connected, Bluetooth state. If a future experiment fails to
   reproduce, this section is the diff target.

4. **Hypothesis ledger** — three subsections:
   - **Active hypotheses**: claims currently believed.
   - **Inactive**: hypotheses paused after 3+ same-null experiments on
     their protective belt (the Lakatosian "abandon the programme"
     trigger). Inactive ≠ ruled out — they can resurrect if their
     auxiliaries shift.
   - **Ruled out**: hypotheses disproved by a specific experiment with
     a stated resurrection condition. *Never delete a ruled-out
     hypothesis* — that's how we end up rediscovering them.

   Every entry uses these fields:
   - **Claim**: one sentence.
   - **Type**: `source-grounded` (read the code/spec) or
     `behavior-inferred` (observed behavior, inferred cause).
   - **Auxiliaries**: assumptions the confidence rests on. If any of
     these are challenged, the entry's status returns to active.
   - **Would shift confidence down**: a specific observation that, if
     seen, would reduce belief. (Risky prediction, Popper-style.)
   - **Resurrection condition** (inactive / ruled out only): what
     evidence would bring this back into play.

5. **Intervention ledger** — one compact table row per fix attempted, so
   a future session can scan "have we tried this?" without re-reading the
   experiment log. Columns: `EXP-NNN` (links to the full entry), date,
   target mechanism, mechanism type, landed? (did the fix take effect),
   resolved? (did the symptom go away), and the revision taken if it did
   not resolve. A fix is an intervention and an intervention is an
   experiment, so every row also has a full pre-registered entry in the
   experiment log. See `docs/governance/debugging-protocol.md` for the
   intervention entry template and the obtains-versus-load-bearing
   discipline that governs the "resolved?" column.

6. **Experiment log** — chronological, every experiment as one entry.
   Use the template below. Number them `EXP-NNN` so cross-references work.

7. **External references** — every source consulted, with the quote
   relied on. URLs alone aren't enough; the quote is what survives if
   the URL link-rots.

8. **Open questions** — `Q1`, `Q2`, ... — questions we don't have
   answers to yet. When a question is resolved, move it out of this
   section and add a "resolved by EXP-NNN" link to the experiment that
   resolved it.

9. **Glossary** — domain-specific terms the reader needs. Spell out
   acronyms (HFP, A2DP, TCC, AUHAL, IOProc, CDHash, TID, etc.) the first
   time they appear in the notebook and again here for quick lookup.

10. **Programme health checkpoints** — *Frame check* entries (`FC-NNN`)
    triggered when the protective belt fails repeatedly. See "Programme
    health triggers" below. Mandatory section header even if empty;
    absence of frame checks should be a deliberate decision, not an
    oversight.

11. **Changelog** — major notebook updates, dated. "Added EXP-013",
    "Reorganized hypothesis ledger", etc. Not every word edit — just
    the moments worth flagging.

## Programme health triggers

Any one of these fires a mandatory `FC-NNN` Frame check entry:

- **3 consecutive same-null experiments** on the same hypothesis. The
  protective belt isn't working; consider moving the hypothesis to
  inactive and reframing.
- **A result that feels suspiciously coherent with everything you
  already believed.** Coherence is a red flag for AI-generated
  reasoning especially — assistants are trained toward plausible
  narratives, which means any "this explains everything" story should
  earn its way by making a *new risky prediction*.
- **Cost-of-being-wrong escalation**: if the next action is irreversi-
  ble (destructive op, production deploy, architectural commit), the
  notebook requires a frame check on the precedent reasoning before
  acting.

A Frame check entry uses this template:

```markdown
### FC-NNN — <short title>

**Date**: YYYY-MM-DD HH:MM (local)
**Trigger**: <which of the above fired, with the EXP-NNN refs>

**Current frame** (the paradigm we've been operating in):
- ...

**Alternative frame(s) to consider**:
- ...

**Distinguishing observations**: what would tell these frames apart?

**Decision**: keep current frame / switch to alternative / hold both /
escalate to user.

**Lesson** (if retroactive): what should we have done earlier?
```

## Experiment entry template

Each experiment is a short, standalone section that another reader can
audit without context. The **Prediction** block is the most important
discipline — it must be written *before* the run and not edited
afterward.

```markdown
### EXP-NNN — <short imperative title>

**Date**: YYYY-MM-DD HH:MM (local)
**Author**: <session label or human name>
**Question**: <one sentence — what are we testing?>
**Hypothesis under test**: <which H-N from the ledger, or "exploratory">

**Prediction** (locked before the run):
- **Outcome A** (predicted): <description> → <hypothesis support /
  refutation / shift in confidence>
- **Outcome B**: <description> → <interpretation>
- **Outcome C** (inconclusive / unexpected): <description> → <what we'd
  do next>

**Variables held constant**:
- <variable>: <value>

**Variables changed**:
- <variable>: <from> → <to>

**Auxiliaries held** (what we're trusting *not* to be the cause):
- <auxiliary>: <why we're trusting it>

**Method**: how to reproduce. Cite exact commands, file paths, button
clicks, browser state — anything required to replicate the run.

**Artifacts**:
- `<absolute path to log file or capture file>` (raw data)

**Observations**: tag each one.
- [source-grounded] <claim, with file:line or spec ref>
- [behavior-inferred] <claim>: observed `<X>`, inferred `<Y>` because
  `<reasoning>`.

**Conclusion**: which prediction matched. State the inferential gap
between raw observation and conclusion. If the experiment refuted a
hypothesis, name it. If it raised a new one, name that too.

**Follow-ups**: questions or experiments this raised. Cross-reference Q*
entries or future EXP-NNN ids.
```

## Resuming a notebook from cold

If you've just compacted, cleared, or otherwise lost context, the first
thing to do is read the **Status** and **TL;DR** sections of any active
notebook in this directory. Then scan the **Hypothesis ledger** to see
where we are. Only after that should you read individual experiments.
Don't skip to writing code.
