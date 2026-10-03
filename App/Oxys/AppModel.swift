import Canvas
import AppKit
import Commands
import Imaging
import Library
import Metadata
import Observation
import Sidecar
import SwiftUI

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
    let compare: CompareController
    let commands: CommandCenter
    /// `⇥` hides the toolbar (and, later, the panels); the pointer at the top edge brings it back (M-13).
    private(set) var chromeHidden = false
    /// The `?` sheet (M-23).
    var showCheatSheet = false
    var cheatScroll = ScrollPosition()
    /// Kept by the sheet's scroll view so the keys can move it: current offset, visible height and content height.
    var cheatMetrics: (offset: CGFloat, page: CGFloat, content: CGFloat) = (0, 0, 0)
    /// External editors (V-12) and the `⌥⌘E` chooser.
    let editors = EditorStore()
    var showEditorChooser = false
    /// Extract embedded JPEGs (V-13).
    let extract = ExtractJob()
    var editorChooserIndex = 0
    /// Auto-advance (V-11): rating, label and reject keys move to the next photo, and `⇧` turns that around.
    /// Set by `A` and by Settings → General; remembered across launches, off by default.
    var autoAdvance = UserDefaults.standard.bool(forKey: "autoAdvance") {
        didSet { if autoAdvance != UserDefaults.standard.bool(forKey: "autoAdvance") { UserDefaults.standard.set(autoAdvance, forKey: "autoAdvance") } }
    }
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

    /// Keys while the cheat sheet is up: `Esc` or `?` close it; arrows, Page, Home, End and Space scroll it.
    private func cheatSheetKey(_ code: UInt16, _ character: Character?) {
        let m = cheatMetrics
        let line: CGFloat = 40
        let maxY = max(0, m.content - m.page)
        func scroll(to y: CGFloat) { cheatScroll.scrollTo(y: min(max(0, y), maxY)) }
        if character == "?" { showCheatSheet = false; return }
        switch code {
        case PhysicalKey.escape.rawValue: showCheatSheet = false
        case PhysicalKey.downArrow.rawValue: scroll(to: m.offset + line)
        case PhysicalKey.upArrow.rawValue: scroll(to: m.offset - line)
        case PhysicalKey.space.rawValue, 121: scroll(to: m.offset + m.page - line)
        case 116: scroll(to: m.offset - m.page + line)
        case PhysicalKey.home.rawValue: scroll(to: 0)
        case PhysicalKey.end.rawValue: scroll(to: maxY)
        default: break
        }
    }

    /// Keys while the editor chooser is up.
    private func editorChooserKey(_ code: UInt16) {
        let list = editors.editors
        func move(_ step: Int) {
            guard !list.isEmpty else { return }
            var i = editorChooserIndex
            for _ in list {
                i = (i + step + list.count) % list.count
                if editors.isInstalled(list[i]) { editorChooserIndex = i; return }
            }
        }
        switch code {
        case PhysicalKey.escape.rawValue: showEditorChooser = false
        case PhysicalKey.downArrow.rawValue: move(1)
        case PhysicalKey.upArrow.rawValue: move(-1)
        case PhysicalKey.return.rawValue, 76: chooseEditor(at: editorChooserIndex)
        default:
            let digits: [PhysicalKey] = [.digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9]
            if let n = digits.firstIndex(where: { $0.rawValue == code }) { chooseEditor(at: n) }
        }
    }

    /// Opens the selection in the chooser's `index`th editor, then closes the chooser. A missing editor does nothing.
    func chooseEditor(at index: Int) {
        let list = editors.editors
        guard list.indices.contains(index), editors.isInstalled(list[index]) else { return }
        showEditorChooser = false
        edit(in: list[index])
    }

    /// Flushes the sidecar writes, so the editor reads the newest values, then opens the selection (or the active
    /// photo) in one call. A RAW+JPEG pair opens its RAW: the frame's own URL (V-10).
    func edit(in editor: ExternalEditor) {
        let urls = folder.cullTargets
        guard !urls.isEmpty else { return }
        folder.flushSidecarWrites()
        let count = urls.count
        editors.open(urls, in: editor) { [unowned self] error in
            announce(error ?? (count == 1 ? "Opened 1 file in \(editor.name)" : "Opened \(count.formatted()) files in \(editor.name)"))
        }
    }

    /// `⇧⌘E`: asks for a folder, then extracts each selected RAW's largest embedded JPEG there in the background.
    /// A RAW+JPEG pair extracts from its RAW. JPEG and HEIC originals are skipped and listed in the summary.
    func extractJPEGs() {
        let sources = folder.cullTargets
        guard !sources.isEmpty, !extract.isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Extract Here"
        panel.message = sources.count == 1 ? "Choose a folder for the embedded JPEG" : "Choose a folder for \(sources.count.formatted()) embedded JPEGs"
        if let last = UserDefaults.standard.string(forKey: "extractFolder") {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        UserDefaults.standard.set(destination.path, forKey: "extractFolder")
        announce(sources.count == 1 ? "Extracting 1 JPEG" : "Extracting \(sources.count.formatted()) JPEGs")
        // The sidecar's rating and label go into the JPEG's XMP. A DNG's own XMP is used when it has no sidecar.
        let wanted = Set(sources)
        let sidecars = Dictionary(folder.photos.compactMap { p in wanted.contains(p.url) ? p.sidecar.file.map { (p.url, $0) } : nil },
                                  uniquingKeysWith: { first, _ in first })
        extract.start(sources, into: destination, exactBytes: UserDefaults.standard.bool(forKey: "extractExactBytes"), sidecars: sidecars) { [unowned self] summary in
            announce(summary)
        }
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
    /// The filter and sort bar (`\`, M-20). Hiding it keeps the filter; the subtitle still says what is shown.
    private(set) var showFilterBar = false
    /// Bumped by ⌘F; the bar focuses its search field when it changes.
    private(set) var findRequest = 0
    private(set) var recentFolders: [URL] = NSDocumentController.shared.recentDocumentURLs

    /// The sidecar naming style chosen in Settings (`name.xmp` until changed).
    static var configuredNaming: SidecarNaming {
        SidecarNaming(rawValue: UserDefaults.standard.string(forKey: "sidecarNaming") ?? "") ?? .stem
    }

    /// Settings → General: a RAW and its camera JPEG are one frame (on until switched off).
    static var pairsRawAndJpeg: Bool {
        UserDefaults.standard.object(forKey: "pairRawJpeg") as? Bool ?? true
    }

    init() {
        commands = CommandCenter(folder: folder)
        grid = GridController(folder: folder, loupe: loupe)
        compare = CompareController(folder: folder, loupe: loupe)
        loupe.compareCanvases = { [compare] in compare.canvases }
        grid.onOpen = { [unowned self] in commands.mode = .loupe }
        commands.register("file.open") { [unowned self] _ in chooseFolder() }
        commands.register("file.reload") { [unowned self] _ in folder.reload() }
        commands.register("file.saveDecisions", isAvailable: { [unowned self] in folder.unsavedCount > 0 }) { [unowned self] _ in
            Task { _ = await saveDecisionsElsewhere() }
        }
        AppDelegate.confirmQuit = { [unowned self] in confirmQuit() }
        // Settings (M-22): the sidecar naming style applies at once. Existing sidecars are never renamed (M-22/Q1).
        folder.sidecarNaming = Self.configuredNaming
        folder.pairsRawAndJpeg = Self.pairsRawAndJpeg
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [unowned self, folder] _ in
            MainActor.assumeIsolated {
                let auto = UserDefaults.standard.bool(forKey: "autoAdvance")
                if autoAdvance != auto { autoAdvance = auto }
                let naming = AppModel.configuredNaming
                if folder.sidecarNaming != naming { folder.sidecarNaming = naming }
                // Pairing changes what the list is made of, so the open folder is read again (V-10/Q4).
                let pairing = AppModel.pairsRawAndJpeg
                if folder.pairsRawAndJpeg != pairing { folder.pairsRawAndJpeg = pairing; folder.flushSidecarWrites(); folder.reload() }
            }
        }
        // A card that was reseated or a share that came back: try the failed writes again when the app returns.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [folder] _ in
            MainActor.assumeIsolated { if folder.unsavedCount > 0 { folder.retryUnsaved() } }
        }
        for (id, step) in [("nav.next", FolderModel.Step.next), ("nav.previous", .previous),
                           ("nav.first", .first), ("nav.last", .last)] {
            // Grid has no canvas to time a frame on; Loupe's navigate also starts the key-to-frame interval.
            // In Compare the arrows step the active side (V-08).
            commands.register(CommandID(rawValue: id)) { [unowned self] _ in
                switch commands.mode {
                case .grid: folder.move(step)
                case .loupe: loupe.navigate(step, folder: folder)
                case .compare: compare.step(step)
                }
            }
        }
        commands.register("nav.up") { [unowned self] _ in grid.move(.up) }
        commands.register("nav.down") { [unowned self] _ in grid.move(.down) }
        registerSelection()
        commands.register("file.reveal", isAvailable: { [unowned self] in !folder.cullTargets.isEmpty }) { [unowned self] _ in
            let urls = folder.revealURLs   // a RAW+JPEG pair reveals both files (V-10)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            announce(urls.count == 1 ? "Revealed 1 file in Finder" : "Revealed \(urls.count.formatted()) files in Finder")
        }
        registerFilter()
        commands.modalActive = { [unowned self] in showCheatSheet || showEditorChooser }
        commands.modalKey = { [unowned self] code, character in
            if showEditorChooser { editorChooserKey(code) } else { cheatSheetKey(code, character) }
        }
        // Edit (V-12): `⌘E` opens in the default editor, `⌥⌘E` asks which.
        commands.register("file.edit", isAvailable: { [unowned self] in !folder.cullTargets.isEmpty && editors.defaultEditor != nil },
                          title: { [unowned self] in editors.defaultEditor.map { "Edit in \($0.name)" } ?? "Edit in External Editor" }) { [unowned self] _ in
            if let editor = editors.defaultEditor { edit(in: editor) }
        }
        commands.register("file.editIn", isAvailable: { [unowned self] in !folder.cullTargets.isEmpty && editors.defaultEditor != nil }) { [unowned self] _ in
            let list = editors.editors
            editorChooserIndex = editors.defaultEditor.flatMap { d in list.firstIndex { $0.id == d.id } } ?? 0
            showEditorChooser = true
        }
        // Extract (V-13): `⇧⌘E` picks a folder and starts; `⌘.` cancels a running job, or closes its summary.
        commands.register("file.extract", isAvailable: { [unowned self] in !folder.cullTargets.isEmpty && !extract.isRunning }) { [unowned self] _ in
            extractJPEGs()
        }
        commands.register("file.extractCancel", isAvailable: { [unowned self] in extract.isShowing }) { [unowned self] _ in
            if extract.isRunning { extract.cancel() } else { extract.dismiss() }
        }
        commands.register("help.cheatsheet") { [unowned self] _ in showCheatSheet.toggle() }
        commands.register("view.loupe") { [unowned self] _ in commands.mode = .loupe }
        commands.register("view.grid") { [unowned self] _ in commands.mode = .grid }
        commands.register("view.chrome", title: { [unowned self] in chromeHidden ? "Show Toolbar" : "Hide Toolbar" }) { [unowned self] _ in
            setChromeHidden(!chromeHidden)
        }
        commands.register("view.chromeTab", title: { [unowned self] in chromeHidden ? "Show Toolbar with Tab" : "Hide Toolbar with Tab" }) { [unowned self] _ in
            setChromeHidden(!chromeHidden)
        }
        commands.register("view.fullscreen", title: {
            NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }) { _ in NSApp.keyWindow?.toggleFullScreen(nil) }
        // Compare (V-08). Entering makes the pair first, so a refusal (fewer than two photos) leaves the mode alone.
        commands.register("compare.enter") { [unowned self] _ in
            if compare.begin(from: commands.mode) { commands.mode = .compare }
        }
        commands.register("compare.switchSide") { [unowned self] _ in compare.switchSide() }
        commands.register("compare.swap") { [unowned self] _ in compare.swap() }
        commands.register("compare.advance") { [unowned self] _ in compare.advance() }
        commands.register("grid.smaller") { [unowned self] _ in grid.resize(by: -1) }
        commands.register("grid.larger") { [unowned self] _ in grid.resize(by: 1) }
        // Zoom, pan and RAW work in Compare too (V-09): they act on the active pane, and the other follows while linked.
        commands.register("zoom.toggle", isOn: { [unowned self] in activeZoomInfo?.isActualSize == true }) { [unowned self] _ in
            if commands.mode == .compare { compare.toggleZoom() } else { loupe.toggleZoom() }
        }
        commands.register("zoom.actual") { [unowned self] _ in
            if commands.mode == .compare { compare.setZoom(.actual) } else { loupe.setZoom(.actual) }
        }
        commands.register("zoom.fit") { [unowned self] _ in
            if commands.mode == .compare { compare.setZoom(.fit) } else { loupe.setZoom(.fit) }
        }
        commands.register("zoom.in") { [unowned self] _ in
            if commands.mode == .compare { compare.stepZoom(.in) } else { loupe.stepZoom(.in) }
        }
        commands.register("zoom.out") { [unowned self] _ in
            if commands.mode == .compare { compare.stepZoom(.out) } else { loupe.stepZoom(.out) }
        }
        commands.register("zoom.link", isOn: { [unowned self] in compare.linked }) { [unowned self] _ in compare.toggleLink() }
        commands.register("zoom.raw", isOn: { [unowned self] in commands.mode == .compare ? compare.anyDeveloped : loupe.developState != .preview },
                          isAvailable: { [unowned self] in loupe.canDevelop },
                          title: { [unowned self] in loupe.canDevelop ? "Show RAW" : "Show RAW (off: RAW decode is Never in Settings)" }) { [unowned self] _ in
            if commands.mode == .compare { compare.toggleRaw() } else { loupe.toggleRaw() }
        }
        commands.register("zoom.rawAlways", isOn: { [unowned self] in loupe.rawMode == .always },
                          isAvailable: { [unowned self] in loupe.canDevelop },
                          title: { [unowned self] in loupe.canDevelop ? "Always Show RAW" : "Always Show RAW (off: RAW decode is Never in Settings)" }) { [unowned self] _ in
            loupe.toggleAlwaysRaw()
        }
        commands.register("cull.autoAdvance", isOn: { [unowned self] in autoAdvance }) { [unowned self] _ in
            autoAdvance.toggle()
            announce(autoAdvance ? "Auto-advance on" : "Auto-advance off")
        }
        commands.register("zoom.sticky", isOn: { [unowned self] in loupe.stickyZoom }) { [unowned self] _ in
            loupe.stickyZoom.toggle()
        }
        commands.register("overlay.peaking", isOn: { [unowned self] in loupe.peakingOn }) { [unowned self] _ in
            loupe.togglePeaking()
        }
        commands.register("overlay.peakingMode", title: { [unowned self] in "Peaking Mode: \(loupe.peakingMode.title) (switch to \(loupe.peakingMode.other.title))" }) { [unowned self] _ in
            loupe.switchPeakingMode()
        }
        commands.register("overlay.highlights", isOn: { [unowned self] in loupe.highlightsOn }) { [unowned self] _ in
            loupe.toggleHighlights()
        }
        commands.register("overlay.shadows", isOn: { [unowned self] in loupe.shadowsOn }) { [unowned self] _ in
            loupe.toggleShadows()
        }
        commands.register("overlay.clippingThresholds") { [unowned self] _ in
            loupe.toggleClippingPopover()
        }
        commands.register("info.cycle", title: { [unowned self] in "Cycle Info (now \(loupe.infoLevel.title))" }) { [unowned self] _ in
            loupe.cycleInfo()
        }
        commands.register("info.rating", isOn: { [unowned self] in loupe.showRatingCorner }) { [unowned self] _ in
            loupe.toggleRatingCorner()
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
            commands.register(CommandID(rawValue: id)) { [unowned self] _ in
                if commands.mode == .compare { compare.pan(direction, page: page) } else { loupe.pan(direction, page: page) }
            }
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
                // Grid acts on the whole selection when there is one (G-5); Loupe and Compare on the active photo.
                // In Compare that is the active side's, and `⇧` moves that side on, not the folder's cursor (V-08).
                // With auto-advance on, `⇧` is the opposite: apply and stay (V-11/Q1).
                let advance = autoAdvance != (phase == .performAdvancing)
                if commands.mode == .compare {
                    compare.cull(action, advance: advance)
                    return
                }
                loupe.cull(action, advance: advance, folder: folder,
                           targets: commands.mode == .grid ? folder.cullTargets : nil)
            }
        }
        commands.register("edit.undo", isAvailable: { [unowned self] in folder.undoName != nil },
                          title: { [unowned self] in folder.undoName.map { "Undo \($0)" } ?? "Undo" }) { [unowned self] _ in
            if commands.mode == .compare { compare.undo() } else { loupe.undo(folder: folder) }
        }
        commands.register("edit.redo", isAvailable: { [unowned self] in folder.redoName != nil },
                          title: { [unowned self] in folder.redoName.map { "Redo \($0)" } ?? "Redo" }) { [unowned self] _ in
            if commands.mode == .compare { compare.redo() } else { loupe.redo(folder: folder) }
        }
        commands.inspectorKey = { [unowned self] code, shift, option in inspectorKey(code: code, shift: shift, option: option) }
        commands.start()
        // Decisions are written as they are made; this waits for the last ones to land before the process exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated {
                folder.flushSidecarWrites()
                saveSession()
            }
        }
        // Developer hook, like OXYS_REPORT_LAUNCH: open a folder at launch for scripted checks.
        if let path = ProcessInfo.processInfo.environment["OXYS_OPEN"] {
            if PerfBench.scenario != nil { PerfBench.start(model: self, folder: URL(fileURLWithPath: path)) } else { open(URL(fileURLWithPath: path)) }
        }
        startSessionResume()
    }

    // MARK: filter and sort (M-20)

    func setFilterBar(_ on: Bool) { showFilterBar = on }

    private func registerFilter() {
        commands.register("filter.bar", isOn: { [unowned self] in showFilterBar }) { [unowned self] _ in
            showFilterBar.toggle()
            if !showFilterBar { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        commands.register("filter.enabled", isOn: { [unowned self] in folder.filter.isOn }) { [unowned self] _ in
            folder.toggleFilter()
            announceFilter(folder.filter.isOn ? "Filter on" : "Filter off")
            releaseKeyboardFromFilterBar()
        }
        commands.register("filter.find") { [unowned self] _ in
            showFilterBar = true
            findRequest += 1
        }
        commands.register("filter.clear", isAvailable: { [unowned self] in folder.filter.hasCriteria }) { [unowned self] _ in
            folder.updateFilter { $0.setMinimumStars(0); $0.labels = []; $0.rejects = .showAll; $0.search = "" }
            announceFilter("Filter cleared")
        }
        for n in 0...5 {
            commands.register(CommandID(rawValue: "filter.stars.\(n)"), isOn: { [unowned self] in folder.filter.stars == (n > 0 ? Set(n...5) : []) }) { [unowned self] _ in
                setFilter { $0.setMinimumStars(n) }
            }
        }
        commands.register("filter.label.any", isOn: { [unowned self] in folder.filter.labels.isEmpty }) { [unowned self] _ in
            setFilter { $0.labels = [] }
        }
        for label in ColorLabel.allCases {
            commands.register(CommandID(rawValue: "filter.label.\(label.rawValue)"),
                              isOn: { [unowned self] in folder.filter.labels.contains(label) }) { [unowned self] _ in
                setFilter { if !$0.labels.insert(label).inserted { $0.labels.remove(label) } }
            }
        }
        for (id, mode) in [("showAll", RejectFilter.showAll), ("hide", .hideRejected), ("only", .onlyRejected)] {
            commands.register(CommandID(rawValue: "filter.rejects.\(id)"), isOn: { [unowned self] in folder.filter.rejects == mode }) { [unowned self] _ in
                setFilter { $0.rejects = mode }
            }
        }
        commands.register("filter.rejects.cycle") { [unowned self] _ in
            setFilter {
                $0.rejects = switch $0.rejects {
                case .showAll: .hideRejected
                case .hideRejected: .onlyRejected
                case .onlyRejected: .showAll
                }
            }
        }
        commands.register("filter.sort.time", isOn: { [unowned self] in folder.filter.sortKey == .captureTime }) { [unowned self] _ in
            setFilter { $0.sortKey = .captureTime }
        }
        commands.register("filter.sort.name", isOn: { [unowned self] in folder.filter.sortKey == .filename }) { [unowned self] _ in
            setFilter { $0.sortKey = .filename }
        }
        commands.register("filter.sort.reverse", isOn: { [unowned self] in !folder.filter.ascending }) { [unowned self] _ in
            setFilter { $0.ascending.toggle() }
        }
    }

    /// Changes the filter and says what is showing now. Turns filtering on, so a key never seems to do nothing.
    func setFilter(_ change: (inout PhotoFilter) -> Void) {
        folder.updateFilter { change(&$0); $0.isOn = true }
        announceFilter(nil)
        releaseKeyboardFromFilterBar()
    }

    /// A click on the bar's stars, labels or pickers must not leave the keyboard in the search field: the keys belong
    /// to the photo unless `⌘F` or a click in the field asked. Runs after SwiftUI has moved focus.
    func releaseKeyboardFromFilterBar() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            window.makeFirstResponder(nil)
        }
    }

    private func announceFilter(_ lead: String?) {
        let shown = folder.visible.count, total = folder.photos.count
        let state = folder.filter.isNarrowing ? "\(shown.formatted()) of \(total.formatted()) shown, \(folder.filter.summary)" : "\(total.formatted()) shown"
        announce([lead, state].compactMap { $0 }.joined(separator: ". "))
    }

    // MARK: selection (M-19)

    /// The ⌥⌘A popover is up (so a second press closes it).
    private var criteriaPopover: NSPopover?

    private func registerSelection() {
        commands.register("select.all") { [unowned self] _ in folder.selectAll(); announceSelection() }
        commands.register("select.none", isAvailable: { [unowned self] in !folder.selection.isEmpty }) { [unowned self] _ in
            folder.selectNone(); announceSelection()
        }
        commands.register("select.cancel", isAvailable: { [unowned self] in !folder.selection.isEmpty }) { [unowned self] _ in
            folder.selectNone(); announceSelection()
        }
        commands.register("select.invert") { [unowned self] _ in folder.invertSelection(); announceSelection() }
        commands.register("select.deselectActive", isAvailable: { [unowned self] in
            folder.currentURL.map(folder.selection.contains) == true
        }) { [unowned self] _ in folder.deselectCurrent(); announceSelection() }
        commands.register("select.by") { [unowned self] _ in showCriteriaPopover() }
        for (id, move) in [("select.extendNext", GridGeometry.Move.right), ("select.extendPrevious", .left),
                           ("select.extendUp", .up), ("select.extendDown", .down)] {
            commands.register(CommandID(rawValue: id)) { [unowned self] _ in grid.extend(move) }
        }
    }

    /// Grid announces its own changes; Loupe has no list, so say it here.
    private func announceSelection() {
        guard commands.mode != .grid else { return }
        let count = folder.selection.count
        announce(count == 0 ? "Selection cleared" : count == 1 ? "1 photo selected" : "\(count) photos selected")
    }

    private func showCriteriaPopover() {
        if let criteriaPopover, criteriaPopover.isShown { criteriaPopover.close(); return }
        guard let view = NSApp.keyWindow?.contentView else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: SelectByView(
            apply: { [unowned self] criteria in
                if criteria.isEmpty { folder.selectNone() } else { folder.select(matching: criteria) }
            },
            done: { [weak popover] in popover?.close() }))
        popover.contentViewController = hosting
        let anchor = NSRect(x: view.bounds.midX - 1, y: view.bounds.maxY - 60, width: 2, height: 2)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        criteriaPopover = popover
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

    /// The zoom on screen that `Z` and the menu check mark speak of: the active pane's in Compare.
    private var activeZoomInfo: ZoomInfo? {
        guard commands.mode == .compare else { return loupe.zoomInfo }
        return compare.pair.flatMap { compare.pane($0.active).zoomInfo }
    }

    /// `⇥` and `⌥⌘T` are the only ways to hide and show the chrome. Moving the pointer to the top edge does nothing, so a pointer that drifts there cannot shift the canvas while the photographer judges a frame.
    func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
    }

    func open(_ url: URL) {
        saveSession()
        let session = sessions?.load(for: url)
        // Compare needs a live pair, so a session never reopens in it; a folder with no session starts in Grid.
        commands.mode = session.flatMap { ViewMode(rawValue: $0.mode) }.flatMap { $0 == .compare ? nil : $0 } ?? .grid
        grid.noteOpening()
        folder.open(url, restoring: session)
        sessions?.setLastFolder(FolderIdentity(url))
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
        alert.informativeText = "Their sidecars could not be written to the photo folder. Save them to another folder, or quit: Oxys keeps them and tries again when you reopen this folder."
        alert.addButton(withTitle: "Save Decisions To…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
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

    // MARK: session resume (V-15)

    /// Per-folder state in Application Support. Nil while a script drives the app (`OXYS_OPEN`, `OXYS_REPORT_LAUNCH`),
    /// so benches and checks neither read nor change the photographer's sessions; `OXYS_SESSION_DIR` turns it back on.
    private let sessions: SessionStore? = {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["OXYS_SESSION_DIR"] { return SessionStore(directory: URL(fileURLWithPath: dir, isDirectory: true)) }
        return env["OXYS_OPEN"] == nil && env["OXYS_REPORT_LAUNCH"] == nil ? SessionStore.standard : nil
    }()
    private var lastSavedSession: SessionState?

    /// Settings → General: open the folder from last time at launch (on until switched off).
    static var reopensLastFolder: Bool { UserDefaults.standard.object(forKey: "reopenLastFolder") as? Bool ?? true }

    /// Writes the open folder's session if it changed since the last write. Cheap, so it runs on a timer, when the
    /// app loses focus, when another folder opens and at quit.
    func saveSession() {
        guard let sessions, let state = folder.sessionState(mode: commands.mode == .grid ? "grid" : "loupe") else { return }
        if let lastSavedSession, lastSavedSession.sameContent(as: state) { return }
        if sessions.save(state) { lastSavedSession = state }
    }

    /// A save at most 15 s after the session state changes (P-09). The state is read once under observation tracking,
    /// so nothing runs, not even a timer, while the window is still. The first change arms one delayed save; that save
    /// reads the state again and re-arms the tracking.
    private func watchSession() {
        withObservationTracking {
            _ = commands.mode
            _ = folder.sessionState(mode: "grid")
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                saveSession()
                watchSession()
            }
        }
    }

    private func startSessionResume() {
        guard let sessions else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { saveSession() }
        }
        watchSession()
        Task.detached { sessions.prune() }
        if ProcessInfo.processInfo.environment["OXYS_OPEN"] == nil, Self.reopensLastFolder, let last = sessions.lastFolder { open(last) }
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentFolders = []
    }
}
