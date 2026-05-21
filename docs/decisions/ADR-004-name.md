# ADR-004: Name

## Status

Accepted

## Context

The project needed a name before the bundle could be scribed (file paths reference it, the GitHub repo uses it, the README leads with it). A name is hard to change after a public repo exists, so this is recorded as an ADR even though it's not architectural in the strict sense.

The conversation around naming was extensive. Several names were proposed and rejected. The rejection patterns matter for understanding the choice and for avoiding similar mistakes if V2 introduces sub-products.

## Decision

The project is named **tap-n-filter**.

The name describes what the app does, plainly: it taps audio (via Core Audio process taps — the `tap` is literal) and filters it (the effect chain). There is no metaphor. There is no concept-load.

## Alternatives considered (and why they were rejected)

The proposal sequence, in order:

### "Manifold"

Rejected. The pitch tried to connect the name to philosophical or aesthetic concepts (Kantian manifolds, F1 manifolds) that the project doesn't actually engage with. The connections were strained, and the user (correctly) called this out as a failure mode: post-hoc justification for a name that was chosen for sound rather than for sense.

### "Substrate"

Rejected. Same problem as Manifold — gestures at depth the project doesn't have. The word also has weight in machine learning ("the substrate of computation"), continental philosophy (Aristotelian hypokeimenon, lineages through Spinoza), and chemistry. None of those are relevant to an audio filter, and importing the weight is a small dishonesty.

### "Lathe"

Rejected. Suggests precision shaping of solid material. Audio filtering is not precision shaping of solid material; it's a different metaphor (more like coloring water). The fit is wrong.

### "Tap"

Rejected as standalone — too generic, too short to be searchable, conflicts with various other "Tap" products in the macOS ecosystem.

### "Reroute"

Rejected. Suggests redirecting traffic, which is part of what the app does, but undersells the processing side. The user pointed out that the app's defining behavior is the filtering, not just the routing.

### "Refract"

Rejected. The metaphor — splitting white light into colored components — sounded poetic but didn't actually describe what filtering does. Filtering attenuates frequencies; it doesn't split a signal into components.

### "Steep"

Rejected. Too obscure as a verb without context; the tea metaphor felt cute rather than informative.

## Why "tap-n-filter" was chosen

After the rejections, the user surfaced "tap-n-filter" directly. The name has these properties:

1. **It describes what the thing does.** No metaphor, no concept-load. A tap (literal: the Core Audio API) plus a filter (literal: the effect chain).
2. **It's searchable.** A multi-word hyphenated name has unique-enough phrasing to be findable.
3. **It doesn't gesture at depth it doesn't have.** The app is a focused audio tool. The name matches.
4. **It scans informally.** The "n" elision in "tap-n-filter" makes it read casually rather than corporate. Fits the indie-tool register.

The choice is also a course-correction. The earlier proposals (Manifold, Substrate, Lathe) drifted toward names that sounded important. The user pushed back on this drift. tap-n-filter is the result of not doing that.

## Consequences

**Enabled:**
- A name that matches what the project actually is.
- A name that doesn't promise depth the project doesn't deliver.
- A name short enough for the menubar (the icon's tooltip).

**Precluded or constrained:**
- The name is informal. Users coming from professional audio tool conventions might find it less serious. The trade-off is conscious.
- The name doesn't lend itself to sub-product naming if V2 introduces multiple modules. If "tap-n-filter" needed to expand into "tap-n-filter Studio" or similar, the name would feel constrained. V1 doesn't have this problem; V2 can take it up if it arises.

**Risks:**
- Naming conflicts. The orchestrator searched for existing macOS apps named "tap-n-filter" or "tapnfilter" at scribing time and found none. A check on Phase 0 (when the GitHub repo is created) re-verifies.
- The name might age poorly if the project diversifies. Not a V1 concern.

## Lesson recorded

The drift toward concept-loaded names was a real failure mode in the conversation. The orchestrator's role in future decisions should preserve this lesson: when reaching for a name that sounds important, check whether the importance is actually present in the thing being named. If not, choose the plainer name.

This lesson generalizes beyond naming. The framing audit (Phase -1) looks for the same pattern in technical decisions: capabilities justified by aesthetic reach rather than concrete need.

## References

- The original conversation log (transcript) for the full rejection sequence.
- `docs/audits/design-rationale.md` for the broader account of how the design ended up where it did.
- `docs/governance/audit-protocol.md` — the failure mode to look for.
