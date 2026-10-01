import SwiftUI

@main
struct OxysApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // A single Window, not a WindowGroup: the PRD asks for exactly one window.
        Window("Oxys", id: "main") {
            Group {
                if KeySpikeSetup.enabled { KeySpikeView() } else { FolderView(model: model) }
            }
            .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            FolderCommands(model: model)
            if KeySpikeSetup.enabled { KeySpikeCommands() }
        }

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
