# ADR-002: Plugin Architecture

## Status

Accepted

## Context

tap-n-filter's value depends on the effect chain being configurable: users add and remove effects to taste, save presets, share them. The question is how the app represents effects internally and how new effect types are added.

Two main options:

1. **Closed set with a protocol.** The app ships a fixed set of effect types in V1 (EQ, Reverb). New effects are added by writing a new Swift class conforming to an `EffectNode` protocol and shipping a new app version. Third parties cannot add effects without rebuilding the app.

2. **AUv3 plugin hosting.** The app hosts Audio Unit version 3 plugins, which are sandboxed audio effect bundles that third parties can distribute independently of the host app.

These aren't mutually exclusive — a future app could ship its own effects AND host AUv3 plugins from other vendors. The question is what V1 commits to.

## Decision

V1 ships **a closed set with a protocol**: the `EffectNode` protocol (`docs/specs/effect-node-protocol.md`) defines what an effect is, and V1 ships two concrete implementations (`EQNode`, `ReverbNode`). Adding a new effect type in V1 means writing a new Swift class, registering it with `EffectNodeRegistry`, and shipping an updated app.

V1 does **not** host AUv3 plugins.

V2 (or later) is expected to add AUv3 hosting via a future `AUv3Node: EffectNode` that wraps a hosted AUv3 unit and exposes its parameters through the same `EffectNode` interface. The `EffectNode` protocol is designed with this extension in mind — its surface accommodates AUv3-style hosting without modification.

## Alternatives considered

### Ship AUv3 hosting in V1

Tempting because AUv3 hosting opens the app to the entire AUv3 ecosystem, including the user's existing plugin collection. Rejected for V1 because:

1. **Sandbox tension.** AUv3 plugins typically expect their host to be sandboxed; some plugins refuse to load in non-sandboxed hosts. Adding AUv3 in V1 would force a sandbox decision (see ADR-003) that the project isn't ready to commit to.

2. **Complexity.** Hosting AUv3 correctly involves parameter automation, persistent plugin state, plugin window management, and several edge cases that take real work to get right. V1's job is to get capture and a basic effect chain working; adding AUv3 doubles the implementation scope.

3. **Audience.** V1's target audience is users who want a few specific effects (lowpass, reverb) for ambient listening. The user doesn't need an open plugin ecosystem to validate the product. V2 can add it for power users.

### Open plugin format unique to tap-n-filter

Define a tap-n-filter-specific plugin format that's neither AUv3 nor Audio Hardware Plug-In. Rejected because:

1. No third-party developer would write plugins for a new format unless tap-n-filter has substantial adoption first.
2. The marginal value over AUv3 (which already exists, is well-documented, and has a developer ecosystem) is unclear.
3. Designing a stable plugin ABI is a significant project in itself.

### Scriptable effects via Lua, JavaScript, or similar

A future-Reaktor or future-Pure Data path where users describe effects in a high-level language. Rejected for V1 because the audience is users running other people's presets, not users designing their own DSP from scratch. If this audience emerges, it's V2+.

## Consequences

**Enabled:**
- V1 has a clean, focused effect set. Two effects, both well-implemented.
- Adding new effects in V1 is straightforward: one Swift file, one registration call.
- The `EffectNode` protocol can be designed without the constraints AUv3 hosting imposes.
- V1 can be unsandboxed (ADR-003), which preserves the V2 AUv3 hosting path.

**Precluded or constrained:**
- Users cannot extend V1 with third-party effects.
- The V1 ecosystem is just tap-n-filter's bundled effects plus user-shared presets of those effects.
- The architecture must accommodate AUv3 in V2 without major refactoring, which constrains the V1 protocol design.

**Risks:**
- The `EffectNode` protocol's V1 design might not actually accommodate AUv3 hosting cleanly when V2 is built. Mitigation: the protocol surface in `effect-node-protocol.md` was designed with AUv3 patterns in mind (input/output buses, async attach/detach, snapshot/restore for plugin state). The first concrete AUv3 implementation in V2 will reveal whether the surface holds; if not, an ADR-002a will document the protocol update.

- Users who try the app and find it lacking compared to AUv3-capable hosts may bounce. Mitigation: V1's positioning is explicit (a focused tool for a specific listening pattern), not a general-purpose plugin host.

## V2 path

When V2 adds AUv3 hosting, the changes will be additive:

1. New `AUv3Node: EffectNode` wrapping `AVAudioUnit` instances hosted via `AVAudioUnitComponentManager`.
2. New UI for browsing installed AUv3 plugins and adding them to the chain.
3. New preset format extension (`AUv3State` extras in `EffectState.extras`) to capture plugin-specific state.
4. Sandbox decision revisited — V2 may move to sandboxed distribution for App Store availability, at which point the AUv3 hosting story becomes natural.

The V1 architecture is laid out so that none of these requires breaking V1's `EffectNode` protocol or the `.tnf` preset format. Backward compatibility with V1 presets is required for V2.

## References

- `docs/specs/effect-node-protocol.md` — the protocol.
- `docs/specs/audio-graph.md` — the graph.
- `docs/specs/preset-format.md` — the `.tnf` format.
- `docs/decisions/ADR-003-no-sandbox-v1.md` — sandbox decision, related.
- `docs/decisions/uncertainty-log.md` — entry on AUv3 hosting unknowns.
