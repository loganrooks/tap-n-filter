import Effects
import SwiftUI
import ViewModel

/// One row in the chain editor: header with chevron / name / bypass / optional
/// wet-dry slider / remove button, plus an expanded controls panel when
/// `viewModel.expandedEffectID == node.id`.
///
/// The wet/dry slider visibility is controlled by the node's static
/// `showsWetDryByDefault` per ADR-007. EQ overrides to false; reverb keeps
/// the default true.
public struct EffectRow: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public let index: Int
    public let node: any EffectNode

    public init(index: Int, node: any EffectNode) {
        self.index = index
        self.node = node
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                EffectControlsView(node: node)
                    .padding(.leading, 18)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            chevron
            Text(node.displayName)
                .font(.body)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            bypassToggle
            if showsWetDry {
                wetDrySlider
            }
            removeButton
        }
    }

    private var chevron: some View {
        Button {
            if isExpanded {
                viewModel.expandedEffectID = nil
            } else {
                viewModel.expandedEffectID = node.id
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(node.displayName)" : "Expand \(node.displayName)")
        .accessibilityHint("Show or hide the parameter controls for this effect.")
    }

    private var bypassToggle: some View {
        Toggle(
            isOn: Binding(
                get: { !node.bypass },
                set: { newValue in viewModel.setBypass(nodeID: node.id, bypass: !newValue) }
            )
        ) {
            Text("On")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .accessibilityLabel("\(node.displayName) enabled")
        .accessibilityValue(node.bypass ? "Bypassed" : "Active")
        .accessibilityHint("Toggle to bypass or enable this effect.")
    }

    private var wetDrySlider: some View {
        Slider(
            value: Binding(
                get: { node.wetDryMix },
                set: { viewModel.updateWetDryMix(nodeID: node.id, value: $0) }
            ),
            in: 0.0 ... 1.0
        )
        .frame(width: 64)
        .accessibilityLabel("\(node.displayName) wet/dry")
        .accessibilityValue("\(Int(node.wetDryMix * 100)) percent")
    }

    private var removeButton: some View {
        Button {
            viewModel.removeEffect(at: index)
        } label: {
            Image(systemName: "minus.circle")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(node.displayName)")
        .accessibilityHint("Delete this effect from the chain.")
    }

    private var isExpanded: Bool {
        viewModel.expandedEffectID == node.id
    }

    /// Pick up the type-level default from the concrete node's metatype.
    private var showsWetDry: Bool {
        return type(of: node).showsWetDryByDefault
    }
}
