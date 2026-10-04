import SwiftUI

@main
struct OxysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() { DevHooks.start() }

    var body: some Scene {
        // A single Window, not a WindowGroup: the PRD asks for exactly one window.
        Window("Oxys", id: "main") {
            Group {
                #if OXYS_DEV_HOOKS
                if KeySpikeSetup.enabled { KeySpikeView() } else { FolderView(model: model) }
                #else
                FolderView(model: model)
                #endif
            }
            .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            TableCommands(center: model.commands, model: model)
            #if OXYS_DEV_HOOKS
            if KeySpikeSetup.enabled { KeySpikeCommands() }
            #endif
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
