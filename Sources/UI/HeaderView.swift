import SwiftUI
import ViewModel

/// Top of the menubar window. Shows the project name plus a status pill
/// that reflects `captureState` so the user knows at a glance whether
/// audio is actively being filtered. Phase 3 §3.1 also calls for a
/// "status line showing capture state and current source"; the pill
/// satisfies that requirement with a compact, accessible affordance.
public struct HeaderView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            Text("tap-n-filter")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            statusPill
            debugToggle
        }
    }

    private var debugToggle: some View {
        Button {
            viewModel.toggleDebugPanel()
        } label: {
            Image(systemName: viewModel.showDebugPanel ? "ladybug.fill" : "ladybug")
                .frame(width: 14, height: 14)
                .foregroundStyle(viewModel.showDebugPanel ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.showDebugPanel ? "Hide debug log" : "Show debug log")
        .accessibilityHint("Toggle the debug log panel at the bottom of the window.")
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(pillColor)
                .frame(width: 8, height: 8)
            Text(pillLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture status")
        .accessibilityValue(pillLabel)
    }

    private var pillColor: Color {
        // An unacknowledged error always wins. The capture controller's
        // rollback paths publish `.idle` after a teardown, so a failure
        // can leave `captureState == .idle` with `lastError` set — the
        // status pill would otherwise read "Off" and the user would not
        // know what happened. Make the error state the primary signal.
        if viewModel.lastError != nil { return .red }
        switch viewModel.captureState {
        case .idle: return .secondary
        case .starting, .stopping: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    private var pillLabel: String {
        // Status only — short and stable. The actual error text lives in the
        // debug log panel (toggle via the ladybug button) so the header stays
        // compact and a long error string never has to fit in a pill.
        if viewModel.lastError != nil { return "Failed" }
        switch viewModel.captureState {
        case .idle: return "Off"
        case .starting: return "Starting"
        case .running:
            if let name = viewModel.currentSource?.displayName {
                return "Filtering \(name)"
            }
            return "On"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }
}
