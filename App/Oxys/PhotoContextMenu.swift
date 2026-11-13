import AppKit
import Commands
import Library

/// Builds and handles the right-click context menu on photo items in Grid, Loupe, Compare, and FilmStrip (V-32).
@MainActor
final class PhotoContextMenu: NSObject {
    private unowned let model: AppModel
    private var airDropURLs: [URL] = []

    init(model: AppModel) {
        self.model = model
    }

    /// Returns a populated context menu for `clickedURL` (or the active photo when nil).
    /// In Grid, right-clicking an unselected photo selects only that photo; right-clicking inside an existing
    /// selection preserves the selection. In FilmStrip, it makes the clicked photo current.
    func menu(clicking clickedURL: URL? = nil, inGrid: Bool = false) -> NSMenu? {
        if let clickedURL {
            if inGrid {
                if !model.folder.selection.contains(clickedURL) {
                    model.folder.click(clickedURL, mode: .replace)
                }
            } else {
                model.folder.setCurrent(clickedURL)
            }
        }
        guard !model.folder.cullTargets.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let rateMenu = NSMenu()
        let rateIDs: [CommandID] = ["cull.rate.1", "cull.rate.2", "cull.rate.3", "cull.rate.4", "cull.rate.5"]
        for id in rateIDs {
            rateMenu.addItem(commandItem(id))
        }
        rateMenu.addItem(.separator())
        rateMenu.addItem(commandItem("cull.rate.0"))
        let rateRoot = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
        rateRoot.submenu = rateMenu
        menu.addItem(rateRoot)

        menu.addItem(commandItem("cull.reject"))

        let labelMenu = NSMenu()
        let labelIDs: [CommandID] = ["cull.label.red", "cull.label.yellow", "cull.label.green", "cull.label.blue", "cull.label.purple"]
        for id in labelIDs {
            labelMenu.addItem(commandItem(id))
        }
        let labelRoot = NSMenuItem(title: "Label", action: nil, keyEquivalent: "")
        labelRoot.submenu = labelMenu
        menu.addItem(labelRoot)

        menu.addItem(.separator())
        menu.addItem(commandItem("file.reveal"))
        menu.addItem(commandItem("file.copyPath"))

        let targets = model.folder.cullTargets
        airDropURLs = targets
        let airDropItem = NSMenuItem(title: "Share via AirDrop…", action: #selector(shareViaAirDrop(_:)), keyEquivalent: "")
        airDropItem.target = self
        if let service = NSSharingService(named: .sendViaAirDrop) {
            airDropItem.isEnabled = !targets.isEmpty && service.canPerform(withItems: targets)
        } else {
            airDropItem.isEnabled = false
        }
        menu.addItem(airDropItem)

        menu.addItem(.separator())
        menu.addItem(commandItem("file.edit"))

        let editInMenu = NSMenu()
        for editor in model.editors.editors {
            let item = NSMenuItem(title: editor.name, action: #selector(openInEditor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = editor.id
            item.isEnabled = !targets.isEmpty && model.editors.isInstalled(editor)
            editInMenu.addItem(item)
        }
        let editInRoot = NSMenuItem(title: "Edit In", action: nil, keyEquivalent: "")
        editInRoot.submenu = editInMenu
        editInRoot.isEnabled = !targets.isEmpty
        menu.addItem(editInRoot)

        menu.addItem(.separator())
        menu.addItem(commandItem("file.extract"))
        return menu
    }

    private func commandItem(_ id: CommandID) -> NSMenuItem {
        let center = model.commands
        guard let cmd = CommandTable.standard[id] else {
            return NSMenuItem(title: id.rawValue, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(title: center.title(for: cmd), action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = center.isEnabled(cmd)
        if center.isOn(cmd) { item.state = NSControl.StateValue.on }
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CommandID else { return }
        model.commands.perform(id)
    }

    @objc private func shareViaAirDrop(_ sender: NSMenuItem) {
        let urls = airDropURLs
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }

    @objc private func openInEditor(_ sender: NSMenuItem) {
        guard let editorID = sender.representedObject as? String,
              let editor = model.editors.editors.first(where: { $0.id == editorID }) else { return }
        model.edit(in: editor)
    }
}
