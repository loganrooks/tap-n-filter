import SwiftUI
import UI
import ViewModel

/// Phase 3 entry point. The menubar icon's system symbol is driven by the
/// view model's `menuBarIconName` so it reflects the live capture state per
/// `docs/specs/ui.md`.
@main
struct TapNFilterApp: App {

    /// Single app-wide view model. `@StateObject` ensures one instance lives
    /// for the lifetime of the process — the menubar window can open and
    /// close repeatedly, but the model (and the capture/engine it owns) is
    /// preserved across opens.
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            ControlPanelView()
                .environmentObject(viewModel)
        } label: {
            Image(systemName: viewModel.menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }
}
