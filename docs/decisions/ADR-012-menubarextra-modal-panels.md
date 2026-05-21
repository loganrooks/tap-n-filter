# ADR-012: NSSavePanel / NSOpenPanel Presentation From MenuBarExtra

## Status

Accepted

## Context

The Phase 3 spec calls for preset save/load via `NSSavePanel` and `NSOpenPanel`. SwiftUI ships `.fileExporter` and `.fileImporter` modifiers that are the natural choice — but `docs/specs/ui.md` §PresetMenu and the failure-modes note in `docs/orchestration/phases/03-ui-control.md` flag both modifiers as known-flaky when presented from a `MenuBarExtra` window:

- The popover sometimes dismisses before the panel appears, leaving the user with an orphaned modal and no obvious way back to the menu.
- On some macOS 14.x patch levels the modifier silently no-ops the first invocation after the popover opens.
- File-type filtering through `UTType` propagates inconsistently when the modifier is attached inside a `MenuBarExtra` body.

The first two issues are observable in production AudioCap-style apps; the third surfaces specifically when the `MenuBarExtra` window is decorated with `.menuBarExtraStyle(.window)`.

## Decision

Use AppKit `NSSavePanel` / `NSOpenPanel` directly, presented through a sheet on the current key window when one is available and falling back to `runModal()` otherwise.

The implementation lives in `Sources/UI/PresetMenu.swift`:

```swift
private func runModalPanel(
    _ panel: NSSavePanel,
    completion: @escaping (NSApplication.ModalResponse, URL?) -> Void
) {
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: window) { response in
            completion(response, panel.url)
        }
    } else {
        let response = panel.runModal()
        completion(response, panel.url)
    }
}
```

Rationale for the fallback chain:

- `NSApp.keyWindow` is the menubar window when it's open and focused. Presenting the panel as a sheet on it keeps the popover docked while the panel is interacted with, which is the user experience the user expects when triggering a panel from a menu item.
- `NSApp.mainWindow` is the next-best anchor when the menubar window doesn't qualify as `keyWindow` (a known AppKit quirk: a `MenuBarExtra` popover sometimes does not register as key on macOS 14.x).
- `runModal()` is the last-resort path. It blocks the calling thread but produces a guaranteed-visible modal panel; we land here when no AppKit window exists, which in practice means the app is starting up or the user invoked the action from a hotkey while the popover was closed.

File-type filtering uses `UTType(filenameExtension: "tnf") ?? .json`. The `.json` fallback ensures Finder still opens the file in a sensible way if the system has no `.tnf` declaration, while the primary path uses the declared type.

## Alternatives considered

### `.fileExporter` / `.fileImporter` SwiftUI modifiers

Rejected per the issues above. The reliability gap is well documented in SwiftUI bug reports for `MenuBarExtra` on macOS 14.x. A robust UI cannot depend on a modifier that no-ops or dismisses underneath itself.

### Temporary `NSWindow` parent for `beginSheetModal`

Rejected as overkill. The current key/main window already exists in every case we observe in production; falling through to `runModal()` is simpler than spinning up a transparent window solely to anchor a sheet.

### Bundle a small SwiftUI wrapper that mimics `.fileExporter` but uses `NSSavePanel` under the hood

Rejected for V1. The two call sites (Save As, Open) are trivial to write directly. A general-purpose wrapper would be one more abstraction we'd have to maintain without a clear second consumer.

## Consequences

**Enabled:**

- Preset save/load works reliably from the menubar dropdown across macOS 14.4 and later.
- The presentation surface is exactly the standard AppKit modal — users get every system feature (sidebar shortcuts, recent files, tag editing, iCloud Drive).
- The `MenuBarExtra` popover dismisses cleanly when the panel appears, which matches the system behaviour for `NSSavePanel` triggered from anywhere else.

**Precluded or constrained:**

- The keyboard shortcuts (`Cmd+S`, `Cmd+O`) only fire when the menubar window has focus. This matches AppKit conventions but means the user must open the menu before the shortcut works. A global hotkey is out of scope for V1.
- The fallback path uses `runModal()`, which blocks the caller. In a SwiftUI Button action this is acceptable; the alternative (spawning a window just to host a sheet) is more complex without a user-visible benefit.

**Risks:**

- `NSApp.keyWindow` may eventually start reporting the menubar popover correctly on future macOS releases, at which point the fallback chain could be simplified. The current code handles either case so no migration is needed.

## References

- `docs/specs/ui.md` §PresetMenu — the spec citing the known-flaky modifiers.
- `docs/orchestration/phases/03-ui-control.md` failure-modes — the orchestrator's note on the workaround.
- `Sources/UI/PresetMenu.swift` — the implementation.
