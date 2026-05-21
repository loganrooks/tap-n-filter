# ADR-007: Wet/Dry Mixing on Spectral-Shaping Effects

## Status

Accepted

## Context

The `EffectNode` protocol requires every effect to expose a `wetDryMix` parameter and implement internal wet/dry mixing via parallel paths through a mixer. This is the standard pattern for time-domain effects (reverb, delay, distortion), where the wet path produces a signal distinct from the input and dry/wet mixing reduces the effect's prominence.

For spectral-shaping effects (EQ, filters), wet/dry mixing has unexpected semantics. At `wetDryMix = 0.5`, half of the unfiltered signal is summed back in, partially defeating the filter. A user dragging a slider labeled "wet/dry" on an EQ from 100% to 50% probably expects a softer or less prominent EQ, but actually gets a partial bypass that re-introduces the frequencies they were filtering out.

The framing audit (F-004) noted this and that the `distant-engines` preset sets the EQ's `wetDryMix` to 1.0, suggesting the author already noticed the issue at preset-tuning time.

Two options:

1. Drop `wetDryMix` from the protocol's required surface; make it optional per node.
2. Keep the protocol-level requirement but hide the EQ's wet/dry slider in the UI by default.

## Decision

Option 2: **keep the protocol-level `wetDryMix` requirement; hide the slider in the default UI surface for spectral-shaping nodes.**

The `EffectNode` protocol continues to require every node to expose and implement `wetDryMix`. Concrete spectral-shaping nodes implement it normally (e.g., `EQNode`'s `wetDryMix` does what the protocol describes — wet equals filtered signal, dry equals unfiltered, mix sums them).

A new static property on `EffectNode` controls whether the UI shows the wet/dry slider in the always-visible header of the effect row:

```swift
public protocol EffectNode: AnyObject, Codable {
    // ... existing members ...

    /// Whether the EffectRow displays the wet/dry slider in the always-visible
    /// header. When false, the slider is still accessible via the expanded
    /// controls panel but is not in the default UI footprint.
    /// Default: true. Spectral-shaping effects (EQ, filters) override to false.
    static var showsWetDryByDefault: Bool { get }
}

extension EffectNode {
    public static var showsWetDryByDefault: Bool { true }
}
```

`EQNode` overrides this to `false`. `ReverbNode` uses the default `true`.

## Alternatives considered

### Option 1: Make `wetDryMix` optional per node

Cleaner conceptually — only nodes that benefit from wet/dry expose it — but breaks the uniformity of the protocol surface. The graph layer, the serialization format, the preset migration story, and the UI's per-row layout all become per-node-conditional. Adding a new spectral-shaping effect type would require deciding how to serialize the missing field, and existing presets with `wetDryMix` set on an EQ would either need migration or graceful-ignore handling.

Option 2 keeps the surface stable: every effect serializes the same fields, the registry's signature doesn't change, and the UI's per-effect customization is one boolean rather than a protocol-shape difference.

### Option: leave the wet/dry slider visible on EQ

Rejected. The user-experience cost (a slider that defeats the user's settings when moved away from 100%) outweighs the consistency benefit of "every row looks the same." The audit's framing of this as a real UX defect is correct.

## Consequences

**Enabled:**
- The protocol surface stays uniform across all effect types.
- Serialization, preset migration, and the registry are unchanged.
- The UI can hide unhelpful controls on a per-effect-type basis without restructuring.

**Precluded or constrained:**
- The UI has one more piece of per-effect-type state (`showsWetDryByDefault`) that the orchestrator must remember to set correctly when adding new effect types.
- Users who explicitly want to use wet/dry on an EQ for creative reasons (a partial-filter blend effect) must expand the effect's controls panel to access it — slightly less discoverable than the default-visible slider.

**Risks:**
- A future effect type's appropriate default for `showsWetDryByDefault` may not be obvious. Mitigation: document the rule (time-domain → true, spectral-shaping → false) in the protocol's doc comment.

## References

- `docs/specs/effect-node-protocol.md` — protocol definition.
- `docs/specs/ui.md` — EffectRow layout.
- `docs/audits/framing-audit-001.md` finding F-004.
- `docs/audits/audit-response-001.md` finding F-004.
