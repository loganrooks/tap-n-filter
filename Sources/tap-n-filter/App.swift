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
                // The Core Audio process-tap API is gated by the same TCC
                // bucket as Screen Recording in macOS 14.4+: System Settings
                // → Privacy & Security → Screen & System Audio Recording.
                // The URL fragment for that pane is `Privacy_ScreenCapture`
                // (the same fragment used by the pre-14 "Screen Recording"
                // pane). The exact pane label and URL fragment are still
                // tracked under U-008 pending live verification, but
                // Privacy_ScreenCapture is the documented best guess and
                // closer to the right pane than Privacy_Microphone.
                Link(
                    "Open System Settings",
                    destination: URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )!
                )
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
