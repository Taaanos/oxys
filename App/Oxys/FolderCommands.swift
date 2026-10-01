import Library
import SwiftUI

/// File → Open Folder…, Open Recent and the Go menu. M-05 moves these into the command table.
struct FolderCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }
                }
                if !model.recentFolders.isEmpty { Divider() }
                Button("Clear Menu") { model.clearRecents() }
                    .disabled(model.recentFolders.isEmpty)
            }
        }
        CommandMenu("Go") {
            Button("Next Photo") { model.loupe.navigate(.next, folder: model.folder) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Photo") { model.loupe.navigate(.previous, folder: model.folder) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("First Photo") { model.loupe.navigate(.first, folder: model.folder) }
                .keyboardShortcut(.home, modifiers: [])
            Button("Last Photo") { model.loupe.navigate(.last, folder: model.folder) }
                .keyboardShortcut(.end, modifiers: [])
        }
    }
}
