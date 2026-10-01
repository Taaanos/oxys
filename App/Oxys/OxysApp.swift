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
    @AppStorage("prefetchBudgetMB") private var budgetMB = 0

    var body: some View {
        Form {
            Stepper(value: $budgetMB, in: 0...32_768, step: 256) {
                Text(budgetMB == 0 ? "Frame cache: automatic (up to 2 GB)" : "Frame cache: \(budgetMB) MB")
            }
            Text("The rest of Settings arrives with M-22.").foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420, height: 160)
    }
}
