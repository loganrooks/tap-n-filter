import SwiftUI

/// Top of the menubar window. V1 shows the project name only; a settings
/// affordance is planned for V0.2 per `docs/specs/ui.md`.
public struct HeaderView: View {

    public init() {}

    public var body: some View {
        HStack {
            Text("tap-n-filter")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
    }
}
