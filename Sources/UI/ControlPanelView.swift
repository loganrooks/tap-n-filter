import SwiftUI
import ViewModel

/// Root view shown in the menu bar dropdown.
///
/// Composed of `HeaderView`, `SourcePickerView`, `ChainEditorView`, and
/// `FooterView`, with an optional `DebugPanel` rendered below the footer
/// when `viewModel.showDebugPanel` is true (toggled via the ladybug button
/// in `HeaderView`). Width is fixed at 380 pt per `docs/specs/ui.md`.
/// Height is dynamic, capped at 700 pt by default and lifted to 900 pt
/// while the debug panel is shown to keep the log readable without
/// pushing the chain editor off-screen.
public struct ControlPanelView: View {

    /// View model injected via `@EnvironmentObject` from the scene root.
    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            SourcePickerView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ChainEditorView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            FooterView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if viewModel.showDebugPanel {
                Divider()
                DebugPanel()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 380)
        // Floor the overall height as well as cap it. Without a `minHeight`,
        // the menu-bar window's fitting-size pass can collapse the whole panel
        // when an interior flexible view (the chain editor's ScrollView)
        // reports a small ideal height — the macOS 27 regression. The floor
        // guarantees the window stays usable regardless of how a given OS
        // resolves the fitting size; the cap still bounds growth.
        .frame(minHeight: 420, maxHeight: viewModel.showDebugPanel ? 900 : 700)
    }
}
