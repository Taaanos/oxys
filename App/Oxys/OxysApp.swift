import SwiftUI

@main
struct OxysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
            TableCommands(center: model.commands, model: model)
            if KeySpikeSetup.enabled { KeySpikeCommands() }
        }

        Settings {
            SettingsView()
        }
    }
}
