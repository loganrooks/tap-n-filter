import SwiftUI
import ViewModel

/// Bottom of the menubar window: presets menu on the left, power toggle on
/// the right.
public struct FooterView: View {

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            PresetMenu()
                .frame(width: 100, alignment: .leading)
            PowerToggle()
        }
    }
}
