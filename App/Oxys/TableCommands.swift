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
            CommandMenu("Photo") {
                TableItems(center: center, menu: .photo)
                EditInMenu(model: model)
            }
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
            Button { center.perform(command.id) } label: { MenuTitle(title: center.title(for: command), symbol: command.symbol) }
                .keyboardShortcut(shortcut)
                .disabled(!enabled)
        case .toggle, .toggleOrHold:
            Toggle(isOn: Binding(get: { center.isOn(command) }, set: { _ in center.perform(command.id) })) {
                MenuTitle(title: command.title, symbol: command.symbol)
            }
                .keyboardShortcut(shortcut)
                .disabled(!enabled)
        }
    }
}

/// A menu item's title with its symbol (D-10). Without a symbol it is the plain text, so the item is as before.
private struct MenuTitle: View {
    let title: String
    let symbol: String?

    var body: some View {
        if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
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

/// "Edit In" (V-12): one item per editor; the ones whose app is not installed are disabled, not hidden.
private struct EditInMenu: View {
    let model: AppModel

    var body: some View {
        Menu("Edit In") {
            ForEach(model.editors.editors) { editor in
                Button(editor.name) { model.edit(in: editor) }
                    .disabled(model.folder.cullTargets.isEmpty || !model.editors.isInstalled(editor))
            }
        }
    }
}
