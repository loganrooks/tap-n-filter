import SwiftUI
import ViewModel

/// Scrollable list of recent log lines, mounted below the footer when the
/// user toggles the ladybug button in the header.
///
/// The panel reads from `AppViewModel.debugLog`, which captures every
/// `info`/`warning`/`error` the view model emits — including the full
/// error text for `powerOn` failures that the compact status pill no
/// longer shows. The same lines also go to the OS unified log, so the
/// debug panel is a convenience surface, not a separate sink.
public struct DebugPanel: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            entries
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.secondary)
            Text("Debug log")
                .font(.caption)
                .fontWeight(.semibold)
            Spacer()
            Text("\(viewModel.debugLog.entries.count) entries")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                viewModel.debugLog.clear()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear debug log")
        }
    }

    private var entries: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if viewModel.debugLog.entries.isEmpty {
                    Text("No log entries yet. Press Power to capture; warnings and errors will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(viewModel.debugLog.entries) { entry in
                    row(for: entry)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func row(for entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: levelIcon(entry.level))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(timeFormatter.string(from: entry.timestamp))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func levelIcon(_ level: DebugLogLevel) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func levelColor(_ level: DebugLogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}
