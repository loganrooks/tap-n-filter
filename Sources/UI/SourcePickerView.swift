import AppKit
import Capture
import Darwin
import SwiftUI
import ViewModel

/// Source-selection control. Lists running applications with capturable audio
/// output and lets the user pick one. Disabled during capture state transitions.
public struct SourcePickerView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The picker selects by `pid` (Hashable). The closure maps the
            // selected pid back to the matching CaptureSource on set, which
            // is the only place we need the full value.
            Picker(
                "Source",
                selection: Binding<pid_t?>(
                    get: { viewModel.currentSource?.pid },
                    set: { pid in
                        if let pid, let match = viewModel.availableSources.first(where: { $0.pid == pid }) {
                            viewModel.setSource(match)
                        } else {
                            viewModel.setSource(nil)
                        }
                    }
                )
            ) {
                Text("Select a source")
                    .tag(Optional<pid_t>.none)
                ForEach(viewModel.availableSources) { source in
                    SourceRow(source: source)
                        .tag(Optional(source.pid))
                }
            }
            .labelsHidden()
            .disabled(isInTransition)
            .accessibilityLabel("Audio source")
            .accessibilityValue(viewModel.currentSource?.displayName ?? "None")
            .accessibilityHint("Pick which app's audio to capture. Changing while running stops capture.")
        }
    }

    /// True during `.starting` or `.stopping`; the source list must not change
    /// underneath an in-flight transition.
    private var isInTransition: Bool {
        switch viewModel.captureState {
        case .starting, .stopping: return true
        case .idle, .running, .failed: return false
        }
    }
}

/// One row in the source picker. Shows the app icon and display name.
public struct SourceRow: View {

    public let source: CaptureSource

    public init(source: CaptureSource) {
        self.source = source
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(source.displayName)
        }
    }

    /// Resolve the app icon from the running-application registry.
    /// Returns nil if the bundle ID is no longer running — the row still
    /// renders the display name in that case.
    private var icon: NSImage? {
        guard let bundleID = source.bundleIdentifier else { return nil }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }
        return candidates.first?.icon
    }
}
