import SwiftUI
import ViewModel

/// In-panel settings section, revealed by the gear button in `HeaderView`.
///
/// This section is hidden by default (`showSettings == false`) and does not
/// affect `ControlPanelView`'s default layout or height. It mirrors the
/// `DebugPanel` gating pattern in `ControlPanelView` exactly.
///
/// Layer A scope: this view only stores and exposes the
/// "Preserve Bluetooth quality during capture" preference. No CoreAudio or
/// device-switching logic is present here — that belongs to a separate,
/// gated Layer B (ADR-019, EXP-037).
public struct SettingsSectionView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Toggle(isOn: $viewModel.preserveBluetoothQuality) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preserve Bluetooth quality during capture")
                        .font(.body)
                    Text(
                        "Keeps Bluetooth headphones at full audio quality (A2DP) "
                        + "while capture is active."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Preserve Bluetooth quality during capture")
            .accessibilityHint(
                "When on, the app keeps Bluetooth headphones at full quality "
                + "while capture is running."
            )
        }
    }
}
