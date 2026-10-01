import AppKit
import Commands
import Library
import Observation

/// App-wide state: the open folder and the Open Recent list.
@MainActor @Observable
final class AppModel {
    let folder = FolderModel()
    let loupe = LoupeController()
    let commands: CommandCenter
    private(set) var recentFolders: [URL] = NSDocumentController.shared.recentDocumentURLs

    init() {
        commands = CommandCenter(folder: folder)
        commands.register("file.open") { [unowned self] _ in chooseFolder() }
        for (id, step) in [("nav.next", FolderModel.Step.next), ("nav.previous", .previous),
                           ("nav.first", .first), ("nav.last", .last)] {
            commands.register(CommandID(rawValue: id)) { [unowned self] _ in loupe.navigate(step, folder: folder) }
        }
        let cullActions: [(String, CullAction)] = [
            ("cull.rate.0", .setRating(0)), ("cull.rate.1", .setRating(1)), ("cull.rate.2", .setRating(2)),
            ("cull.rate.3", .setRating(3)), ("cull.rate.4", .setRating(4)), ("cull.rate.5", .setRating(5)),
            ("cull.rate.down", .stepRating(-1)), ("cull.rate.up", .stepRating(1)), ("cull.reject", .toggleReject),
            ("cull.label.red", .toggleLabel(.red)), ("cull.label.yellow", .toggleLabel(.yellow)),
            ("cull.label.green", .toggleLabel(.green)), ("cull.label.blue", .toggleLabel(.blue)),
            ("cull.label.purple", .toggleLabel(.purple)),
        ]
        for (id, action) in cullActions {
            commands.register(CommandID(rawValue: id)) { [unowned self] phase in
                loupe.cull(action, advance: phase == .performAdvancing, folder: folder)
            }
        }
        commands.start()
        // Developer hook, like OXYS_REPORT_LAUNCH: open a folder at launch for scripted checks.
        if let path = ProcessInfo.processInfo.environment["OXYS_OPEN"] { open(URL(fileURLWithPath: path)) }
    }

    func open(_ url: URL) {
        folder.open(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentFolders = NSDocumentController.shared.recentDocumentURLs
    }

    /// ⌘O. Choosing a folder replaces the current one.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Accepts the first dropped folder; anything else is ignored.
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        else { return false }
        open(url)
        return true
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentFolders = []
    }
}
