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

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("tap-n-filter")
                .font(.headline)
            Text("V1 build in progress")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Phase 0 shell — full UI lands in Phase 3.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280)
    }
}
