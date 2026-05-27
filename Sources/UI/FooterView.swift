import AppKit
import SwiftUI
import ViewModel

/// Bottom of the menubar window: presets menu on the left, power toggle in
/// the middle, quit button on the right.
public struct FooterView: View {

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            PresetMenu()
                .frame(width: 100, alignment: .leading)
            PowerToggle()
            quitButton
        }
    }

    /// Closes the entire application. MenuBarExtra apps stay alive after the
    /// dropdown closes by design, so without an explicit terminate the only
    /// way out is Activity Monitor. Per user feedback (2026-05-22): "having
    /// an exit button" was a Day-One ask.
    ///
    /// Keyboard shortcut: Cmd-Q matches the macOS convention; AppKit handles
    /// the shortcut even when no NSWindow is keyWindow because the
    /// MenuBarExtra window receives the key event.
    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "power.circle")
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .help("Quit tap-n-filter (⌘Q)")
        .accessibilityLabel("Quit tap-n-filter")
        .accessibilityHint("Closes the application entirely.")
    }
}
