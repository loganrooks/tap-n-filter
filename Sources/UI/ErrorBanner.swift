import SwiftUI
import ViewModel

/// Full-width failure message shown above the footer while an error is
/// outstanding.
///
/// This replaces an `info.circle` button that sat beside the power control.
/// That button was labelled "Error details" and its only action was
/// `clearError()` — it destroyed the information it advertised — while the
/// message itself lived in a `.help()` tooltip, unreachable without a hover
/// and invisible to VoiceOver. The message is now rendered in the panel, and
/// dismissal is a separate, labelled control.
///
/// It is a sibling of the footer rather than part of `PowerToggle` on purpose.
/// `FooterView` lays the presets menu, power control, and quit button out in a
/// single centre-aligned `HStack`; a banner nested inside `PowerToggle` made
/// that control multi-row, so SwiftUI centred the presets and quit buttons
/// against the combined height and a two-line error visibly shoved them out of
/// alignment. A row of peer actions should stay one row tall.
public struct ErrorBanner: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        if let error = viewModel.lastError {
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
                .accessibilityHint("Hide this error message. The status pill keeps reporting a failure while audio is not flowing.")
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
    }
}
