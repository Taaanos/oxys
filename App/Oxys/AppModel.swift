import Canvas
import AppKit
import Commands
import Library
import Metadata
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
    let grid: GridController
    let commands: CommandCenter
    /// `⇥` hides the toolbar (and, later, the panels); the pointer at the top edge brings it back (M-13).
    private(set) var chromeHidden = false
    /// The inspector sidebar (⌥⌘I), remembered across launches. Hidden along with the toolbar by `⇥` (M-13).
    private(set) var showInspector = UserDefaults.standard.bool(forKey: "showInspector")
    /// True after "Move Focus to Inspector" until `Esc`: `⇥`, `⇧⇥`, `↑` and `↓` walk the inspector's rows and
    /// `⌘C` copies the focused one. Driven by our own key handling, not SwiftUI focus, which cannot take the
    /// keyboard from the image view.
    private(set) var inspectorActive = false
    private(set) var inspectorFocusID: String?
    /// The inspector's rows in order, kept up to date by the view.
    var inspectorRows: [(id: String, label: String, value: String)] = []
    var inspectorValue: String? {
        guard inspectorActive, let id = inspectorFocusID else { return nil }
        return inspectorRows.first { $0.id == id }?.value
    }

    func activateInspector(at id: String? = nil) {
        inspectorActive = true
        inspectorFocusID = id ?? inspectorFocusID.flatMap { id in inspectorRows.contains { $0.id == id } ? id : nil } ?? inspectorRows.first?.id
        if id == nil, let row = inspectorRows.first(where: { $0.id == inspectorFocusID }) { announce("\(row.label), \(row.value)") }
    }

    func deactivateInspector() { inspectorActive = false }

    /// Keys while the inspector is active; true when consumed.
    func inspectorKey(code: UInt16, shift: Bool, option: Bool) -> Bool {
        // `⌥↑` and `⌥↓` walk the rows whenever the inspector is open, like chat apps' message navigation.
        // They take over Loupe's pan keys then; `⌥⇧` still pans a whole view.
        if option, !shift, showInspector, !chromeHidden, commands.mode != .compare,
           code == PhysicalKey.upArrow.rawValue || code == PhysicalKey.downArrow.rawValue {
            // A first press lands on the first or last row, as `moveInspectorFocus` does with no row focused.
            if !inspectorActive { inspectorActive = true; inspectorFocusID = nil }
            moveInspectorFocus(code == PhysicalKey.downArrow.rawValue ? 1 : -1, wraps: false)
            return true
        }
        guard inspectorActive, !option else { return false }
        switch code {
        case PhysicalKey.escape.rawValue: deactivateInspector()
        case PhysicalKey.tab.rawValue: moveInspectorFocus(shift ? -1 : 1, wraps: true)
        case PhysicalKey.downArrow.rawValue: moveInspectorFocus(1, wraps: false)
        case PhysicalKey.upArrow.rawValue: moveInspectorFocus(-1, wraps: false)
        default: return false
        }
        return true
    }

    private func moveInspectorFocus(_ step: Int, wraps: Bool) {
        let rows = inspectorRows
        guard !rows.isEmpty else { return }
        let current = inspectorFocusID.flatMap { id in rows.firstIndex { $0.id == id } }
        var next = current.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        next = wraps ? (next + rows.count) % rows.count : min(max(next, 0), rows.count - 1)
        inspectorFocusID = rows[next].id
        announce("\(rows[next].label), \(rows[next].value)")
    }

    private func announce(_ phrase: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: phrase, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    @ObservationIgnored private var pointerMonitor: Any?
    private(set) var recentFolders: [URL] = NSDocumentController.shared.recentDocumentURLs

    init() {
        commands = CommandCenter(folder: folder)
        grid = GridController(folder: folder, loupe: loupe)
        grid.onOpen = { [unowned self] in commands.mode = .loupe }
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
            // Grid has no canvas to time a frame on; Loupe's navigate also starts the key-to-frame interval.
            commands.register(CommandID(rawValue: id)) { [unowned self] _ in
                if commands.mode == .grid { folder.move(step) } else { loupe.navigate(step, folder: folder) }
            }
        }
        commands.register("nav.up") { [unowned self] _ in grid.move(.up) }
        commands.register("nav.down") { [unowned self] _ in grid.move(.down) }
        commands.register("view.loupe") { [unowned self] _ in commands.mode = .loupe }
        commands.register("view.grid") { [unowned self] _ in commands.mode = .grid }
        commands.register("view.chrome", title: { [unowned self] in chromeHidden ? "Show Toolbar" : "Hide Toolbar" }) { [unowned self] _ in
            setChromeHidden(!chromeHidden)
        }
        commands.register("grid.smaller") { [unowned self] _ in grid.resize(by: -1) }
        commands.register("grid.larger") { [unowned self] _ in grid.resize(by: 1) }
        commands.register("zoom.toggle", isOn: { [unowned self] in loupe.zoomInfo?.isActualSize == true }) { [unowned self] _ in
            loupe.toggleZoom()
        }
        commands.register("zoom.actual") { [unowned self] _ in loupe.setZoom(.actual) }
        commands.register("zoom.fit") { [unowned self] _ in loupe.setZoom(.fit) }
        commands.register("zoom.in") { [unowned self] _ in loupe.stepZoom(.in) }
        commands.register("zoom.out") { [unowned self] _ in loupe.stepZoom(.out) }
        commands.register("zoom.sticky", isOn: { [unowned self] in loupe.stickyZoom }) { [unowned self] _ in
            loupe.stickyZoom.toggle()
        }
        commands.register("info.cycle", title: { [unowned self] in "Cycle Info (now \(loupe.infoLevel.title))" }) { [unowned self] _ in
            loupe.cycleInfo()
        }
        commands.register("info.histogram", isOn: { [unowned self] in loupe.showHistogram }) { [unowned self] _ in
            loupe.toggleHistogram()
        }
        commands.register("info.inspector", isOn: { [unowned self] in showInspector }) { [unowned self] _ in
            setInspector(!showInspector)
        }
        commands.register("info.inspectorFocus", isAvailable: { [unowned self] in showInspector && !chromeHidden }) { [unowned self] _ in
            activateInspector()
        }
        commands.register("info.fieldNext", isAvailable: { [unowned self] in loupe.showExif && !inspectorActive }) { [unowned self] _ in
            loupe.moveExifFocus(1)
        }
        commands.register("info.fieldPrevious", isAvailable: { [unowned self] in loupe.showExif && !inspectorActive }) { [unowned self] _ in
            loupe.moveExifFocus(-1)
        }
        commands.register("info.copy", isAvailable: { [unowned self] in inspectorValue != nil || (loupe.showExif && loupe.exif != nil) }) { [unowned self] _ in
            if let inspectorValue { copyToPasteboard(inspectorValue) } else { loupe.copyExif() }
        }
        commands.register("info.maps", isAvailable: { [unowned self] in loupe.exif?.gps != nil }) { [unowned self] _ in
            loupe.showInMaps()
        }
        let pans: [(String, PanDirection, Bool)] = [
            ("pan.left", .left, false), ("pan.right", .right, false), ("pan.up", .up, false), ("pan.down", .down, false),
            ("pan.pageLeft", .left, true), ("pan.pageRight", .right, true), ("pan.pageUp", .up, true), ("pan.pageDown", .down, true),
        ]
        for (id, direction, page) in pans {
            commands.register(CommandID(rawValue: id)) { [unowned self] _ in loupe.pan(direction, page: page) }
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
        commands.inspectorKey = { [unowned self] code, shift, option in inspectorKey(code: code, shift: shift, option: option) }
        commands.start()
        // Decisions are written as they are made; this waits for the last ones to land before the process exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [folder] _ in
            MainActor.assumeIsolated { folder.flushSidecarWrites() }
        }
        // Developer hook, like OXYS_REPORT_LAUNCH: open a folder at launch for scripted checks.
        if let path = ProcessInfo.processInfo.environment["OXYS_OPEN"] { open(URL(fileURLWithPath: path)) }
    }

    func setInspector(_ on: Bool) {
        showInspector = on
        UserDefaults.standard.set(on, forKey: "showInspector")
        if !on { deactivateInspector() }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        if hidden, pointerMonitor == nil {
            // The window only reports pointer moves when asked; asking costs one cheap check per move.
            NSApp.keyWindow?.acceptsMouseMovedEvents = true
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.pointerMoved(event) }
                return event
            }
        } else if !hidden, let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
        }
    }

    private func pointerMoved(_ event: NSEvent) {
        guard chromeHidden, let window = event.window, window.isKeyWindow,
              event.locationInWindow.y >= window.contentLayoutRect.maxY - 6 else { return }
        setChromeHidden(false)
    }

    func open(_ url: URL) {
        commands.mode = .grid
        grid.noteOpening()
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
