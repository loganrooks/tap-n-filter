import SwiftUI

@main
struct TapNFilterApp: App {
    var body: some Scene {
        MenuBarExtra("tap-n-filter", systemImage: "waveform") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Phase 1 debug UI.
///
/// A minimal control surface for driving the capture lifecycle manually.
/// Full source-picker and effect controls arrive in Phase 3; this view exists
/// only to retire the Phase 1 gate criteria (passthrough test, permission
/// handling verification).
struct ContentView: View {
    @StateObject private var viewModel = Phase1DebugViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // MARK: Header
            Text("tap-n-filter")
                .font(.headline)

            Divider()

            // MARK: Bundle ID input
            VStack(alignment: .leading, spacing: 4) {
                Text("Bundle ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("com.apple.Safari", text: $viewModel.bundleID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isRunning)
            }

            // MARK: Start / Stop buttons
            HStack(spacing: 8) {
                Button("Start") {
                    viewModel.start()
                }
                .disabled(!viewModel.isIdle || viewModel.isRunning)

                Button("Stop") {
                    viewModel.stop()
                }
                .disabled(!viewModel.isRunning)
            }

            // MARK: Record toggle
            Toggle("Record output", isOn: $viewModel.recordOutput)
                .disabled(viewModel.isRunning)
                .font(.caption)

            Divider()

            // MARK: Status line
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(viewModel.isPermissionDenied ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // MARK: System Settings link (permission denied only)
            if viewModel.isPermissionDenied {
                // The exact pane URL is tracked under U-008 and will be
                // verified during the Phase 1 manual passthrough test.
                // Privacy_Microphone is used as a conservative fallback;
                // macOS 14.4+ may expose a distinct "Audio Capture" pane.
                Link(
                    "Open System Settings",
                    destination: URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    )!
                )
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
