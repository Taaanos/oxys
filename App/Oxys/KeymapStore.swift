import AppKit
import Commands
import Observation
import os

/// The keymap file and the editor over it (V-14). The file is the single source of truth: every edit reads it
/// again first, so a change made by hand or by another copy is not lost, then writes the result at once and
/// tells the command center, so menus and the cheat sheet change in the same moment. There is no Save button.
///
/// A file that does not parse, or has another version, puts the store in `blocked`: the app runs on the Default
/// keys, editing is off, and nothing overwrites the file until the user chooses Start Over.
@MainActor @Observable
final class KeymapStore {
    enum State: Equatable {
        case ready
        /// Why the file cannot be used.
        case blocked(String)
    }

    private(set) var editor: KeymapEditor
    private(set) var state: State = .ready
    /// The last write failure, shown in the pane until the next edit works.
    private(set) var writeError: String?
    let url: URL
    /// Called with every new keymap, including the first read when the callback is set.
    @ObservationIgnored var onChange: (ResolvedKeymap) -> Void = { _ in }
    @ObservationIgnored private static let log = Logger(subsystem: "com.thanosam.Oxys", category: "commands")

    /// `~/Library/Application Support/Oxys/Keymap.json` (M-05/Q1). `OXYS_KEYMAP` moves it in the Bench build.
    static var defaultURL: URL {
        if let path = DevHooks.environment["OXYS_KEYMAP"] { return URL(fileURLWithPath: path) }
        return URL.applicationSupportDirectory.appending(path: "Oxys/Keymap.json", directoryHint: .notDirectory)
    }

    init(table: CommandTable = .standard, url: URL = KeymapStore.defaultURL) {
        self.url = url
        editor = KeymapEditor(table: table)
        readFile()
        for problem in problems { Self.log.error("\(problem, privacy: .public)") }
        // The app becomes active after the user edited the file in another program.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { if reload() { publish() } }
        }
    }

    /// The keymap the app runs on: the editor's, or the Default keys while the file is blocked.
    var resolved: ResolvedKeymap {
        if case .blocked(let reason) = state {
            return ResolvedKeymap(keymap: Keymap.resolve(table: editor.table, file: nil).keymap, problems: [reason])
        }
        return editor.resolved
    }

    var problems: [String] { resolved.problems }
    var isBlocked: Bool { if case .blocked = state { true } else { false } }

    // MARK: reading

    /// Reads the file into the editor. True when what the app runs on changed.
    @discardableResult
    func reload() -> Bool {
        let before = (editor.file, state)
        readFile()
        return before.0 != editor.file || before.1 != state
    }

    private func readFile() {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile || (error as? CocoaError)?.code == .fileNoSuchFile {
                state = .ready
                editor.load(KeymapFile())
                return
            }
            return block("The file cannot be read: \(error.localizedDescription)")
        }
        do {
            let file = try KeymapFile.decode(data)
            guard file.version == KeymapFile.currentVersion else {
                return block("The file has version \(file.version). This app reads version \(KeymapFile.currentVersion).")
            }
            state = .ready
            editor.load(file)
        } catch {
            block("The file is not valid: \(error.localizedDescription)")
        }
    }

    private func block(_ reason: String) {
        state = .blocked(reason)
        editor.load(KeymapFile())
    }

    // MARK: editing

    /// Gives `shortcut` to `id` (see `KeymapEditor.assign`). Nil when nothing could be done: the file is blocked or
    /// the write failed.
    @discardableResult
    func assign(_ shortcut: Shortcut, to id: CommandID, replacing old: Shortcut? = nil, reassign: Bool = false) -> KeyCheck? {
        edit { $0.assign(shortcut, to: id, replacing: old, reassign: reassign) }
    }

    func remove(_ shortcut: Shortcut, from id: CommandID) {
        edit { $0.remove(shortcut, from: id); return .ok }
    }

    func reset(_ id: CommandID) {
        edit { $0.reset(id); return .ok }
    }

    func resetAll() {
        edit { $0.resetAll(); return .ok }
    }

    @discardableResult
    private func edit(_ body: (inout KeymapEditor) -> KeyCheck) -> KeyCheck? {
        let changedOnDisk = reload()
        guard !isBlocked else {
            if changedOnDisk { publish() }
            return nil
        }
        let previous = editor
        let result = body(&editor)
        guard editor.file != previous.file else {
            if changedOnDisk { publish() }
            return result
        }
        do {
            try write(editor.file)
            writeError = nil
            publish()
            return result
        } catch {
            editor = previous
            writeError = "The keys could not be saved: \(error.localizedDescription)"
            Self.log.error("Keymap write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Atomic, so a crash never leaves half a file. With nothing to say the file goes away, as on a new install.
    private func write(_ file: KeymapFile) throws {
        if file.bindings.isEmpty, file.preset == nil {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.encoded().write(to: url, options: .atomic)
    }

    private func publish() { onChange(resolved) }

    // MARK: import, export and a file that cannot be read

    /// What importing `source` would do, for the confirmation: the file and what `resolve` finds wrong in it.
    struct ImportPreview {
        var file: KeymapFile
        var problems: [String]
    }

    func previewImport(from source: URL) -> Result<ImportPreview, KeymapImportError> {
        do {
            let file = try KeymapFile.decode(Data(contentsOf: source))
            guard file.version == KeymapFile.currentVersion else {
                return .failure(KeymapImportError("The file has version \(file.version). This app reads version \(KeymapFile.currentVersion)."))
            }
            return .success(ImportPreview(file: file, problems: Keymap.resolve(table: editor.table, file: file).problems))
        } catch {
            return .failure(KeymapImportError("The file is not a keymap file: \(error.localizedDescription)"))
        }
    }

    /// Replaces the keys with the preview's. The file is written as it was read, so an entry this app does not know stays.
    func commitImport(_ preview: ImportPreview) {
        edit { $0.load(preview.file); return .ok }
    }

    func export(to destination: URL) throws {
        try editor.file.encoded().write(to: destination, options: .atomic)
    }

    /// The file moves to `Keymap.json.bak` (a copy from before replaces an older one) and the keys are Default again.
    func startOver() {
        guard isBlocked else { return }
        let backup = url.appendingPathExtension("bak")
        do {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: url, to: backup)
            writeError = nil
        } catch {
            writeError = "The old file could not be moved: \(error.localizedDescription)"
            return
        }
        reload()
        publish()
    }

    func revealInFinder() {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

struct KeymapImportError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
