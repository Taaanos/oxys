import SwiftUI

/// File → Open Folder… and Open Recent. M-05 moves these into the command table.
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
    }
}
