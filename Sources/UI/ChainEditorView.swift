import Effects
import Graph
import SwiftUI
import ViewModel

/// Ordered editor for the effect chain. Renders one `EffectRow` per node
/// followed by an `AddEffectButton` whose menu pulls available effect types
/// from `EffectNodeRegistry.shared`.
public struct ChainEditorView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.graph.nodes.enumerated()), id: \.element.id) { index, node in
                        EffectRow(index: index, node: node)
                    }
                }
            }
            .frame(maxHeight: 360)

            AddEffectButton()
        }
    }
}

/// Menu button that appends a new effect to the chain. The menu items are
/// sourced from `EffectNodeRegistry.shared.registeredTypeIdentifiers` so new
/// effect types appear automatically.
public struct AddEffectButton: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        Menu {
            ForEach(EffectNodeRegistry.shared.registeredTypeIdentifiers, id: \.self) { identifier in
                Button(displayName(for: identifier)) {
                    viewModel.addEffect(of: identifier)
                }
                .accessibilityLabel("Add \(displayName(for: identifier))")
            }
        } label: {
            Label("Add Effect", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Add effect")
        .accessibilityHint("Choose an effect type to append to the chain.")
    }

    /// Map a `typeIdentifier` to a user-visible label. V1 hard-codes the two
    /// built-ins; adding a new effect type means adding an entry here.
    private func displayName(for typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "tnf.eq": return "Parametric EQ"
        case "tnf.reverb": return "Reverb"
        default: return typeIdentifier
        }
    }
}
