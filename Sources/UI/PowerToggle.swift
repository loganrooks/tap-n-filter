import Capture
import SwiftUI
import ViewModel

/// Large rounded button that toggles the capture chain on and off.
///
/// State drives label, style, and action per `docs/specs/ui.md` §PowerToggle:
/// idle → "Start", starting/stopping → spinner, running → "Stop", failed →
/// "Retry".
public struct PowerToggle: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.lastError {
                errorBanner(error)
            }
            controls
        }
    }

    /// Inline, always-visible failure text.
    ///
    /// This replaces an `info.circle` button whose only action was
    /// `clearError()`: the control was labelled "Error details" but destroyed
    /// the very information it advertised, and the message itself was reachable
    /// only through a `.help()` tooltip. Rendering the message in the panel
    /// means a user who cannot hover — or who is using VoiceOver — still reads
    /// what failed, and dismissal is a separate, clearly-labelled affordance.
    private func errorBanner(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(error.userMessage)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
            .accessibilityHint("Hide this error message.")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error")
        .accessibilityValue(error.userMessage)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: tap) {
                Group {
                    switch viewModel.captureState {
                    case .idle:
                        Label("Start", systemImage: "play.fill")
                    case .starting:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                        }
                    case .running:
                        Label("Stop", systemImage: "stop.fill")
                    case .stopping:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Stopping…")
                        }
                    case .failed:
                        Label("Retry", systemImage: "exclamationmark.triangle")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .tint(buttonTint)
            .disabled(isDisabled)
            .accessibilityLabel("Power")
            .accessibilityValue(stateLabel)
            .accessibilityHint("Start or stop audio capture.")
        }
    }

    private func tap() {
        switch viewModel.captureState {
        case .idle:
            Task { await viewModel.powerOn() }
        case .running:
            Task { await viewModel.powerOff() }
        case .failed:
            // Per the button label, "Retry" should restart capture, not just
            // clear the error. The capture controller is already stopped in
            // .failed (powerOn's failure paths tear down before publishing
            // .failed), so calling powerOn directly is correct — no powerOff
            // first.
            viewModel.clearError()
            Task { await viewModel.powerOn() }
        case .starting, .stopping:
            // No-op; the button is disabled in these states.
            break
        }
    }

    private var isDisabled: Bool {
        switch viewModel.captureState {
        case .starting, .stopping: return true
        case .idle, .running, .failed: return false
        }
    }

    private var stateLabel: String {
        switch viewModel.captureState {
        case .idle: return "Off"
        case .starting: return "Starting"
        case .running: return "On"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }

    private var buttonTint: Color {
        switch viewModel.captureState {
        case .failed: return .red
        case .running: return .secondary
        default: return .accentColor
        }
    }
}
