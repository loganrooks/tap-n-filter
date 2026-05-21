import SwiftUI
import ViewModel

/// Root view shown in the menubar dropdown.
///
/// Composed of `HeaderView`, `SourcePickerView`, `ChainEditorView`, and
/// `FooterView`. Width is fixed at 320 pt per `docs/specs/ui.md`. Height is
/// dynamic, capped at 600 pt with a `ScrollView` inside the chain editor.
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
        }
        .frame(width: 320)
        .frame(maxHeight: 600)
    }
}
