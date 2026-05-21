# ADR-013: Effect-Chain Reorder Uses Up/Down Buttons

## Status

Accepted

## Context

Phase 3 §3.3 calls for the chain editor to support reordering via
drag-and-drop using SwiftUI's `.draggable` / `.dropDestination`. The
`docs/specs/ui.md` description leaves the door open: "Vertical `LazyVStack`
(or `List` if drag-and-drop reordering is desired and `LazyVStack` proves
awkward)".

Two constraints make drag-and-drop the wrong fit for V0.1.0:

1. **`MenuBarExtra` window limitations.** The Phase 3 spec failure-modes
   section calls out: "SwiftUI's `MenuBarExtra` window has constraints on
   resizing and on certain interactions (drag-and-drop in particular has
   been finicky historically)." Reorder via `.onMove` on `List` inside a
   `MenuBarExtra` window has shown to be unreliable on macOS 14.x and
   14.4 specifically — drag targets can disappear when the menu window
   loses focus mid-drag, and the drop indicator does not always render.

2. **Accessibility coverage.** Drag-and-drop is invisible to keyboard
   navigation and to VoiceOver users without a custom rotor action. The
   Phase 3 accessibility gate (§3.8) requires every interactive element
   to be reachable via Tab / VoiceOver, with a meaningful announcement.
   Drag handles do not satisfy that bar without extra plumbing.

The Phase 3 failure-modes section explicitly authorises a degraded path:
"If a feature can't be implemented within those constraints, the
orchestrator writes an ADR and offers a degraded path (e.g., reorder via
up/down arrows instead of drag-and-drop)."

## Decision

Implement reorder with two icon-only buttons (`chevron.up`, `chevron.down`)
in the `EffectRow` header. Each button calls
`AppViewModel.moveEffect(from:to:)` with the appropriate target index per
SwiftUI's `List.onMove` post-removal convention:

| Action       | `from` | `to`     |
|--------------|--------|----------|
| Move row up  | `i`    | `i - 1`  |
| Move row down| `i`    | `i + 2`  |

The Up button is disabled on the first row; the Down button is disabled
on the last row. Both buttons carry `.accessibilityLabel("Move
<name> up"/"down")` so VoiceOver announces a meaningful action.

## Alternatives considered

### Drag-and-drop inside a `LazyVStack`

Rejected. `LazyVStack` does not support `.onMove`. Implementing the
drag-and-drop dance manually via `.draggable` / `.dropDestination` plus a
custom drop indicator is possible but brittle in `MenuBarExtra` (see
context above) and adds ~200 lines of UI plumbing for a feature the user
can also accomplish via a remove-then-readd workflow when the buttons
fail.

### Switch the chain editor to `List`

Rejected. `List` in a `MenuBarExtra` window introduces its own sizing
quirks (the implicit `ScrollView` it embeds fights the parent `VStack`'s
intrinsic-height layout), and the row backgrounds the chain editor draws
clash with `List`'s default selection/hover treatment. The sizing
quirks and the styling conflict are both regressions; reorder is the
only feature gained, so the tradeoff is unfavourable.

### Defer reorder to V0.2

Rejected. The Phase 3 gate criterion 2 explicitly names "effect
add/remove/reorder" as a required behaviour. Shipping V0.1.0 without
any reorder path would fail the gate.

## Consequences

**Enabled:**

- Reorder is reachable via keyboard (Tab to the up/down button, Space to
  activate) and via VoiceOver.
- Boundary disabling means a user pressing "Up" on the first row hears
  the button is disabled rather than seeing a no-op silently.
- The `LazyVStack` chain editor stays compatible with `MenuBarExtra`'s
  sizing model.

**Precluded or constrained:**

- Moving an effect by more than one position requires multiple button
  presses. Power users may find this slower than drag-and-drop. V0.2
  considers a context-menu "Move to top / Move to bottom" affordance.
- Drag-and-drop reorder is not available even on platforms / future
  macOS versions where `MenuBarExtra` becomes more drag-friendly. V0.2
  re-evaluates.

**Risks:**

- If the chain grows beyond ~10 effects, button-by-button reorder is
  tedious. V0.1.0 is unlikely to hit this — the V1 effect catalog is
  two types — but V0.2's plugin work could push this past the
  comfortable limit, motivating a richer reorder UI.

## References

- `docs/orchestration/phases/03-ui-control.md` §3.3 (Chain editor),
  §Failure modes.
- `docs/specs/ui.md` §ChainEditorView.
- `Sources/UI/EffectRow.swift` — the implementation site.
- `Sources/ViewModel/AppViewModel.swift` — `moveEffect(from:to:)`.
