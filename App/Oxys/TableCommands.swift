import Commands
import Library
import SwiftUI

/// The menu bar, generated from the command table: app, File, Edit, View, Photo, Filter, Window, Help.
/// Items are disabled, never hidden. System menus (Edit, View, Window, Help) get the table's items added
/// to them; Photo and Filter are ours and appear once they have items.
struct TableCommands: Commands {
    let center: CommandCenter
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) { TableItems(center: center, menu: .app) }
        CommandGroup(replacing: .newItem) {
            TableItems(center: center, menu: .file)
            OpenRecentMenu(model: model)
        }
        CommandGroup(replacing: .undoRedo) { TableItems(center: center, menu: .edit) }
        CommandGroup(after: .toolbar) { TableItems(center: center, menu: .view) }
        if center.table.hasItems(in: .photo) {
            CommandMenu("Photo") { TableItems(center: center, menu: .photo) }
        }
        if center.table.hasItems(in: .filter) {
            CommandMenu("Filter") { TableItems(center: center, menu: .filter) }
        }
        CommandGroup(after: .windowArrangement) { TableItems(center: center, menu: .window) }
        CommandGroup(after: .help) { TableItems(center: center, menu: .help) }
    }
}

private extension CommandTable {
    func hasItems(in menu: AppMenu) -> Bool { !groups(in: menu).isEmpty }
}

private struct TableItems: View {
    let center: CommandCenter
    let menu: AppMenu

    var body: some View {
        let groups = center.table.groups(in: menu)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group) { command in item(command) }
        }
    }

    @ViewBuilder private func item(_ command: Command) -> some View {
        let shortcut = center.shortcut(for: command)
        let enabled = center.isEnabled(command)
        switch command.kind {
        case .action:
            Button(center.title(for: command)) { center.perform(command.id) }
                .keyboardShortcut(shortcut)
                .disabled(!enabled)
        case .toggle, .toggleOrHold:
            Toggle(command.title, isOn: Binding(get: { center.isOn(command) }, set: { _ in center.perform(command.id) }))
                .keyboardShortcut(shortcut)
                .disabled(!enabled)
        }
    }
}

private struct OpenRecentMenu: View {
    let model: AppModel

    var body: some View {
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
