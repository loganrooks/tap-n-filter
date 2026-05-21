# Phase 3: UI and Control

Replace the debug UI from Phase 1 with the real menubar interface. Source picker, effect chain editor, parameter sliders, preset save/load, persistence. The UI should be usable for daily ambient listening by end of phase.

## Scope

In:
- A SwiftUI `MenuBarExtra` window with the full control surface.
- Source picker: dropdown of running applications with audio output (filtered list using `NSRunningApplication`).
- Effect chain editor: ordered list of effects, add/remove/reorder, per-effect controls.
- Per-effect parameter controls: sliders for continuous params, picker for enum params, toggle for bypass.
- Preset save/load via `NSSavePanel` and `NSOpenPanel`. Loading a `.tnf` replaces the current graph. Saving captures the current graph state.
- A "factory presets" submenu with `distant-engines` and `dry` (the two V1 bundled presets; see `docs/specs/preset-format.md`).
- Persistence: the app remembers the last-used graph and source between launches via `UserDefaults` (graph stored as serialized `GraphPreset` JSON).
- Master power toggle: start/stop the entire chain.
- A status line showing capture state and current source.
- Accessibility: every control has a meaningful `accessibilityLabel`. Keyboard navigation works.

Out:
- Visual spectrum display or metering (planned for V0.2).
- Multiple concurrent sources (V2).
- AUv3 plugin hosting (V2).
- Marketplace UI (V3).
- Drag-and-drop of effects between chains (not relevant for single-chain V1).

## Reference

`docs/specs/ui.md` describes the UI structure in detail. The orchestrator reads it before writing any view code.

## Architecture

```
   App (SwiftUI App protocol)
       │
       ▼
   MenuBarExtra (menubar window)
       │
       ▼
   ControlPanelView
       │
       ├── SourcePickerView
       ├── ChainEditorView
       │       │
       │       ▼
       │   [EffectRow for each node]
       │       │
       │       ▼
       │   EffectControlsView
       │       │
       │       ├── ParameterSlider × N
       │       ├── BypassToggle
       │       └── WetDryMixSlider
       │
       ├── PresetMenu
       └── PowerToggle
```

View state is owned by a single `AppViewModel` (an `ObservableObject`) which holds:
- The current `Graph`.
- The `CaptureController`.
- The current source.
- UI presentation state (which effect is expanded, etc.).

Engine and capture lifecycle is driven by the view model in response to view events.

## Tasks

### 3.1 ControlPanelView

The root view shown in the menubar dropdown. Header with the project name, then `SourcePickerView`, then `ChainEditorView`, then footer with `PresetMenu` and `PowerToggle`. Width 320pt, dynamic height based on chain length.

### 3.2 SourcePickerView

A `Picker` showing a list of `CaptureSource` candidates. The list is populated by enumerating `NSRunningApplication` for apps with `activationPolicy == .regular` and known audio-capable identifiers. The list refreshes every 5 seconds via a Timer.

Selecting a source while the chain is running stops the current capture, switches source, restarts. The view model handles the transition cleanly.

### 3.3 ChainEditorView

Ordered list of `EffectRow`s. Each row shows:
- Effect display name.
- Bypass toggle.
- Wet/dry slider.
- Expand/collapse chevron revealing `EffectControlsView`.
- Remove button.
- Drag handle (uses SwiftUI's `.draggable` and `.dropDestination` for reordering).

Below the list, an "Add effect" button presents a menu of available effect types (in V1: EQ, Reverb). Selecting an option appends a default-configured node to the chain.

### 3.4 EffectControlsView

Renders one slider per `EffectParameter`. Slider range is the parameter's `range`, label is the `displayName`, suffix is the `unit` symbol ("Hz", "dB", etc.).

For enum-valued parameters (e.g., reverb preset), renders a `Picker` instead of a slider.

Changes are pushed through to the underlying `EffectNode` via `setParameter` immediately on slider drag (with throttling at 30 Hz to avoid flooding).

### 3.5 PresetMenu

Three sub-menus:
- "Save As..." → opens `NSSavePanel`, saves current `GraphPreset`.
- "Load..." → opens `NSOpenPanel` filtered to `.tnf`, loads into the current graph.
- "Factory Presets" → submenu with each bundled preset, loads on selection.

### 3.6 PowerToggle

A large rounded button at the bottom of the panel. States:
- "Off" → tap starts capture and engine.
- "Starting" → spinner.
- "On" → tap stops.
- "Failed" → tap clears error and returns to "Off". A small error icon next to the toggle reveals the error message on hover.

### 3.7 Persistence

On every change to the graph or source, the view model serializes the current state to `UserDefaults` under the key `lastSession`. On app launch, the view model attempts to restore from this key; if deserialization fails (schema change, corrupted data), it falls back to loading the `distant-engines` preset and logs a warning.

### 3.8 Accessibility audit

The accessibility gate has two parts: a programmatic check the verification subagent can re-run, and a manual VoiceOver pass the orchestrator performs.

Programmatic check:

1. The orchestrator builds the app and launches an `XCUIApplication` test target that walks the menubar UI.
2. The test uses `XCUIElementQuery` to enumerate every interactive element in the `ControlPanelView` hierarchy.
3. For each element, the test asserts:
   - `accessibilityLabel` is non-empty.
   - For sliders and pickers, `accessibilityValue` is non-empty when the element has a current value.
   - For elements identified by the spec as `accessibilityHint`-eligible (controls whose action is non-obvious), the hint is non-empty.
4. The test dumps the full accessibility tree as JSON to `test-artifacts/phase-3-accessibility-tree.json` and commits it as evidence.

The verification subagent re-runs this test (or reads the committed JSON dump plus the test-pass log) to confirm the assertions hold.

Manual VoiceOver pass:

1. The orchestrator runs the app with VoiceOver enabled.
2. The orchestrator navigates through every control using only VoiceOver gestures + keyboard, and confirms each control is reachable and produces a sensible spoken response.
3. The orchestrator records observations in `docs/audits/verification/phase-3-accessibility.md`.

The manual pass catches qualitative issues (labels that are technically present but unhelpful, navigation order that's surprising). The programmatic check catches structural omissions (a control with no label at all). Both are required for the phase to pass.

Keyboard navigation:
- Tab cycles through controls.
- Arrow keys adjust sliders.
- Space toggles bypass and power.

### 3.9 Tests

- SwiftUI snapshot tests for `ControlPanelView` in three states: idle, running, failed.
- View model unit tests for source switching, preset loading, persistence round-trip.
- Manual accessibility audit using VoiceOver (orchestrator runs through the app with VoiceOver, records issues in `docs/audits/verification/phase-3-accessibility.md`).

## Gate criteria

Phase 3 PASSES when the verification subagent confirms:

1. All views from 3.1–3.6 exist with the specified structure.
2. Source switching, effect add/remove/reorder, parameter changes, preset save/load, persistence, and power toggle all work without crashes.
3. Snapshot tests pass.
4. View model tests pass.
5. The accessibility audit passes both parts: (a) the programmatic accessibility-tree test at `test-artifacts/phase-3-accessibility-tree.json` shows every interactive element has a non-empty `accessibilityLabel` (and non-empty `accessibilityValue` where applicable), confirmed by the verification subagent re-reading the JSON or the test log; and (b) the manual VoiceOver pass documented in `docs/audits/verification/phase-3-accessibility.md` reports no major issues.
6. CodeRabbit and Codex review pass.
7. `state.json` shows phase `3` → `passed`.

This phase does not have a human-in-loop gate. The verification subagent reads the snapshots and the audit log and decides.

## Failure modes

- **MenuBarExtra has known sizing limitations.** SwiftUI's `MenuBarExtra` window has constraints on resizing and on certain interactions (drag-and-drop in particular has been finicky historically). If a feature can't be implemented within those constraints, the orchestrator writes an ADR and offers a degraded path (e.g., reorder via up/down arrows instead of drag-and-drop).
- **NSSavePanel and NSOpenPanel don't behave well from a MenuBarExtra window.** The known workaround is to present them from a temporary `NSWindow` or to use the AppKit equivalent. The orchestrator documents the chosen workaround in code comments and an ADR.
- **Snapshot tests are brittle across macOS versions.** The orchestrator pins macOS test version in CI to one specific runner and notes this in `coding-standards.md`.

## Outputs

- View hierarchy in `Sources/UI/`.
- View model in `Sources/ViewModel/`.
- Snapshot tests in `Tests/UISnapshotTests/`.
- A passing PR titled `phase-3: ui and control`.
- ADRs for any UI-level workarounds discovered.
- `state.json` updated.
