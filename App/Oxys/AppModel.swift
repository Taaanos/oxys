import AppKit
import Library
import Observation

/// App-wide state: the open folder and the Open Recent list.
@MainActor @Observable
final class AppModel {
    let folder = FolderModel()
    private(set) var recentFolders: [URL] = NSDocumentController.shared.recentDocumentURLs

    init() {
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
