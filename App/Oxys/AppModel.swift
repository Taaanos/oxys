import AppKit
import Commands
import Library
import Observation

/// Lets the model answer `applicationShouldTerminate` without the SwiftUI app owning an AppKit delegate by hand.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var confirmQuit: (() -> NSApplication.TerminateReply)?

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.confirmQuit?() ?? .terminateNow
    }
}

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
        commands.register("file.reload") { [unowned self] _ in folder.reload() }
        commands.register("file.saveDecisions", isAvailable: { [unowned self] in folder.unsavedCount > 0 }) { [unowned self] _ in
            Task { _ = await saveDecisionsElsewhere() }
        }
        AppDelegate.confirmQuit = { [unowned self] in confirmQuit() }
        // A card that was reseated or a share that came back: try the failed writes again when the app returns.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [folder] _ in
            MainActor.assumeIsolated { if folder.unsavedCount > 0 { folder.retryUnsaved() } }
        }
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
        commands.register("edit.undo", isAvailable: { [unowned self] in folder.undoName != nil },
                          title: { [unowned self] in folder.undoName.map { "Undo \($0)" } ?? "Undo" }) { [unowned self] _ in
            loupe.undo(folder: folder)
        }
        commands.register("edit.redo", isAvailable: { [unowned self] in folder.redoName != nil },
                          title: { [unowned self] in folder.redoName.map { "Redo \($0)" } ?? "Redo" }) { [unowned self] _ in
            loupe.redo(folder: folder)
        }
        commands.start()
        // Decisions are written as they are made; this waits for the last ones to land before the process exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [folder] _ in
            MainActor.assumeIsolated { folder.flushSidecarWrites() }
        }
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

    /// Asks for a folder and writes the unsaved decisions' sidecars there (M-11). True when everything was saved.
    @discardableResult
    func saveDecisionsElsewhere() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = "Choose where to save the sidecars. Move them next to the photos later."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        await folder.saveUnsaved(to: url)
        return !folder.hasUnsavedDecisions
    }

    /// The quit prompt (M-11): the one modal, shown only when decisions exist that are not on disk.
    func confirmQuit() -> NSApplication.TerminateReply {
        folder.retryAndFlush()
        guard folder.hasUnsavedDecisions else { return .terminateNow }
        let count = folder.photos.filter(\.sidecar.unsaved).count
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 decision is not saved" : "\(count) decisions are not saved"
        alert.informativeText = "Their sidecars could not be written to the photo folder. Save them to another folder, or quit and lose them."
        alert.addButton(withTitle: "Save Decisions To…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                NSApp.reply(toApplicationShouldTerminate: await saveDecisionsElsewhere())
            }
            return .terminateLater
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
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
