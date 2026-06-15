# Review Tiers

`review-protocol.md` defines *how* the project reviews a PR: CodeRabbit plus Codex
plus the verification subagent, the verdict-block discipline, and the journal.
This file defines *which* review weight a given PR gets, so cross-vendor and
heavyweight review is spent where blast radius justifies it and small changes stay
fast.

Tier is a function of blast radius and reversibility, not line count.

## Tiers

### Tier 1 — Light

Mechanical changes, docs, and low-blast-radius work: doc edits, comment fixes, a
self-contained test, a localized refactor with no protocol-surface change.

Review: CodeRabbit (automatic) plus a quick within-platform `/code-review`
(low/medium effort). No Codex pass required. Self-merge after CI and a clean
CodeRabbit review.

### Tier 2 — Standard

A normal feature or fix: a new effect node, a UI control, a view-model change, a
bug fix with a contained surface.

Review: CodeRabbit plus `@codex review` (the default cross-vendor pass) plus the
verification subagent when the change touches a gated spec. Address findings per
`review-protocol.md` before merge.

### Tier 3 — Heavyweight

High blast radius, safety-critical, or irreversible: capture/engine/graph
lifecycle changes; audio-safety code (the output limiter); CoreAudio sparse-API
work; device switching (HFP Layer B); anything in an area under an active
investigation; and public or irreversible actions (release, signing,
notarization, adding a new top-level dependency).

Review: CodeRabbit plus **Codex GPT-5.5 at xhigh effort** (via `@codex review`,
or `codex:rescue` pinned `model=gpt-5.5 effort=xhigh` for a deep diagnosis pass)
plus a Claude reviewer panel of two to three distinct lenses plus
**`/code-review ultra`** at the milestone boundary. For epics marked heavyweight
in the roadmap, add the phase-style ceremony: a framing audit and a dedicated
verification subagent. Do not merge on unresolved high-severity findings without a
written, user-approved override.

## Standing UI gate

Any PR that touches UI layout carries a mandatory manual check on the maintainer's
newest-macOS machine before merge: open the menu, confirm the effect list renders
and scrolls. GitHub-hosted runners lag new macOS releases by roughly five to six
months, so CI cannot catch a day-one-of-new-OS layout regression (ADR-022). This
gate is the only guard for that class until a self-hosted newest-OS runner exists.

## How to pick a tier

Default to Tier 2. Drop to Tier 1 only when the change is mechanical and cannot
affect runtime behavior off the diff. Raise to Tier 3 when any of these is true:
it changes a protocol other types implement; it touches the audio render path or
device configuration; it is hard to reverse; it adds a dependency; or it lives in
an area with an open investigation notebook.

The infrastructure already exists. The `reviewer_profiles` map in the review
journal supports multiple bots and severity vocabularies, `@codex review` is the
in-place cross-vendor GPT lever, and `/code-review ultra` is the heavy
multi-agent pass. Applying tiers is a matter of discipline, not new tooling.
