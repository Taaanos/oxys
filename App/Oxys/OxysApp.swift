import SwiftUI

@main
struct OxysApp: App {
    var body: some Scene {
        // A single Window, not a WindowGroup: the PRD asks for exactly one window.
        Window("Oxys", id: "main") {
            EmptyStateView()
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsStubView()
        }
    }
}

private struct SettingsStubView: View {
    var body: some View {
        Text("Settings arrive with M-22.")
            .foregroundStyle(.secondary)
            .frame(width: 360, height: 160)
    }
}
