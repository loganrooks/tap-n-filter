# ADR-006: Graph Mutation Lifecycle

## Status

Accepted

## Context

The `Graph` type (`docs/specs/audio-graph.md`) supports both attach-time wiring and runtime mutations (add, remove, move). Both interact with `AVAudioEngine`'s lifecycle. The question is which engine states permit which operations.

Three relevant engine states:

- **Not started.** The engine has been constructed but `start()` has not been called. Free reconfiguration is permitted.
- **Running.** `start()` has been called and the render loop is active. `pause()` suspends the render loop without tearing down the audio graph; the engine is still considered "running" for the purpose of structural reconfiguration.
- **Stopped.** `stop()` has been called after a `start()`. The render loop is fully torn down. Reconfiguration is permitted again.

`AVAudioEngine.attach`, `connect`, and `disconnect` calls behave differently across these states. While Apple's documentation suggests calls during `running` are permitted for some operations, in practice structural changes (attaching new nodes, reconnecting buses) require a full `stop()`; on a `pause()`-ed engine, structural calls may silently no-op, leaving the audio graph in an inconsistent state. This has been observed in third-party AVAudioEngine code and is consistent with Apple's "use Manual Rendering Mode for fully-controlled reconfiguration" guidance.

## Decision

All `Graph.attach`, `Graph.detach`, and any node-set mutation (`add`, `remove`, `move`) followed by re-attach require the engine to be **not started or fully stopped**. The graph asserts on this precondition. The caller (`AppViewModel`) is responsible for transitioning the engine to a permissible state before invoking these operations.

The mutation sequence is:

1. Save current snapshot for rollback.
2. `engine.stop()`.
3. `graph.detach()`.
4. Mutate the graph.
5. `graph.attach(to: engine, source:, destination:)`.
6. `engine.start()`.

For parameter updates (changing an `AVAudioUnit`'s parameter value via `setParameter`), the engine can remain running — those updates are thread-safe by Apple's contract.

## Alternatives considered

### Use `engine.pause()` instead of `engine.stop()`

Rejected. `pause()` suspends rendering but does not place the engine in a state where `connect` / `disconnect` calls are reliably honored. The original draft of `audio-graph.md` proposed this; the framing audit (F-002) caught it. Behavior differences across macOS minor versions make this approach especially fragile.

### Use `AVAudioEngine.enableManualRenderingMode` for mutations

Manual rendering mode permits full control over the engine, but switching into manual rendering for a mutation and back into auto-rendering is more complex than stopping and starting. For V1's mutation rate (low — users add or remove effects occasionally, not continuously), the simpler `stop`/`start` pattern is preferable.

### Reconstruct the engine on every mutation

Rejected as expensive. `AVAudioEngine` construction is non-trivial; doing it on every chain mutation would add hundreds of milliseconds of latency and would tear down the capture's aggregate-device input connection unnecessarily.

## Consequences

**Enabled:**
- Mutations are well-defined: the user adds an effect, hears a brief silence (~100 ms), and the new chain is live.
- The graph's invariants are protected by an explicit precondition rather than by hoping `pause()` does what it suggests.

**Precluded or constrained:**
- Mutations always interrupt audio briefly. V1 accepts this; V2 can experiment with fade-out / mutate / fade-in if the interruption is annoying in practice.
- The caller must manage engine state correctly. The view model has this responsibility; nothing in the graph layer assumes it.

**Risks:**
- A future contributor might call `graph.add` directly without stopping the engine. Mitigation: the graph asserts on the engine's `isRunning` state and traps with a descriptive message in debug builds.

## References

- `docs/specs/audio-graph.md` — graph spec; references this ADR from the "Graph mutations during playback" subsection.
- `docs/specs/effect-node-protocol.md` — node-level wet/dry pattern that depends on this lifecycle.
- `docs/audits/framing-audit-001.md` finding F-002 — the source of this decision.
- `docs/audits/audit-response-001.md` finding F-002 — the response that triggered creation.
