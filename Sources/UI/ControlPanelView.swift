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
        .frame(maxHeight: viewModel.showDebugPanel ? 900 : 700)
    }
}
