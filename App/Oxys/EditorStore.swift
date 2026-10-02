import AppKit
import Library
import Observation

/// The external editors (V-12): the list, the default, and which apps are installed. The list is saved as JSON in
/// user defaults and applies at once. Installed apps are found with Launch Services, then at the preset's usual path.
@MainActor @Observable
final class EditorStore {
    private static let key = "editors"

    private(set) var list: EditorList
    /// Bumped when an app may have been installed or removed, so menus and the settings pane look again.
    private(set) var revision = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(EditorList.self, from: data) {
            list = saved
        } else {
            list = EditorList()
        }
        // An app may be installed or removed while Oxys runs.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { revision += 1 }
        }
    }

    var editors: [ExternalEditor] { _ = revision; return list.all }

    func appURL(for editor: ExternalEditor) -> URL? {
        if let id = editor.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        if let path = editor.path, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    func isInstalled(_ editor: ExternalEditor) -> Bool { _ = revision; return appURL(for: editor) != nil }

    /// What `⌘E` opens: the chosen default, else the first installed editor.
    var defaultEditor: ExternalEditor? { _ = revision; return list.resolvedDefault(isInstalled: { appURL(for: $0) != nil }) }

    func setDefault(_ id: String?) { list.defaultID = id; save() }

    func add(appAt url: URL) {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let editor = ExternalEditor.custom(name: name, bundleID: bundle?.bundleIdentifier, path: url.path)
        list.add(editor)
        save()
    }

    func remove(_ id: String) { list.remove(id: id); save() }

    /// Opens every file in one call. The caller flushes pending sidecar writes first.
    /// `completion` runs on the main actor with an error text, or nil when the editor accepted the files.
    func open(_ urls: [URL], in editor: ExternalEditor, completion: @escaping @MainActor (String?) -> Void) {
        guard let app = appURL(for: editor) else { completion("\(editor.name) is not installed"); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
            let text = error.map { "\(editor.name) could not open the files: \($0.localizedDescription)" }
            Task { @MainActor in completion(text) }
        }
    }

    private func save() {
        revision += 1
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
