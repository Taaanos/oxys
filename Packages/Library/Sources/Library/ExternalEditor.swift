import Foundation

/// An application that ⌘E can open photos in (V-12). Pure data: finding the app on disk is the caller's job.
public struct ExternalEditor: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Looked up with Launch Services first.
    public var bundleID: String?
    /// For an app the user added, or a place to look when the bundle ID finds nothing.
    public var path: String?
    /// How the files reach the app.
    public var launch: Launch
    /// The three the PRD names. They cannot be removed, only disabled by being missing.
    public var isPreset: Bool

    public enum Launch: String, Sendable, Codable, Hashable {
        /// Launch Services opens the files with the app (`NSWorkspace.open`).
        case workspace
        /// The app's own executable is started with the file paths as arguments. ART and RawTherapee are GTK
        /// apps: through Launch Services they get `file://` URIs and read them as a relative folder.
        case arguments
    }

    public init(id: String, name: String, bundleID: String? = nil, path: String? = nil, isPreset: Bool = false, launch: Launch = .workspace) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.isPreset = isPreset
        self.launch = launch
    }

    private enum CodingKeys: String, CodingKey { case id, name, bundleID, path, isPreset, launch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        isPreset = try c.decode(Bool.self, forKey: .isPreset)
        launch = try c.decodeIfPresent(Launch.self, forKey: .launch) ?? .workspace
    }

    public static let presets: [ExternalEditor] = [
        ExternalEditor(id: "lightroom-classic", name: "Lightroom Classic", bundleID: "com.adobe.LightroomClassicCC7",
                       path: "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app", isPreset: true),
        ExternalEditor(id: "rawtherapee", name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee",
                       path: "/Applications/RawTherapee.app", isPreset: true, launch: .arguments),
        ExternalEditor(id: "art", name: "ART", bundleID: "us.pixls.art.ART",
                       path: "/Applications/ART.app", isPreset: true, launch: .arguments),
    ]

    /// An editor for an app the user picked. The ID is the path, so adding the same app twice finds the first one.
    public static func custom(name: String, bundleID: String?, path: String) -> ExternalEditor {
        ExternalEditor(id: "custom:" + path, name: name, bundleID: bundleID, path: path)
    }
}

/// The editor list and which one is the default. Saved as JSON in user defaults.
public struct EditorList: Sendable, Codable, Equatable {
    /// Editors the user added; the presets are always present and come first.
    public private(set) var added: [ExternalEditor]
    public var defaultID: String?

    public init(added: [ExternalEditor] = [], defaultID: String? = nil) {
        self.added = added
        self.defaultID = defaultID
    }

    public var all: [ExternalEditor] { ExternalEditor.presets + added }

    public subscript(id: String) -> ExternalEditor? { all.first { $0.id == id } }

    public mutating func add(_ editor: ExternalEditor) {
        guard self[editor.id] == nil else { return }
        added.append(editor)
    }

    public mutating func remove(id: String) {
        added.removeAll { $0.id == id }
        if defaultID == id { defaultID = nil }
    }

    /// The editor ⌘E uses: the chosen one if it is still listed and installed, else the first installed one in list order.
    /// Nil when no editor is installed.
    public func resolvedDefault(isInstalled: (ExternalEditor) -> Bool) -> ExternalEditor? {
        if let id = defaultID, let chosen = self[id], isInstalled(chosen) { return chosen }
        return all.first(where: isInstalled)
    }
}
