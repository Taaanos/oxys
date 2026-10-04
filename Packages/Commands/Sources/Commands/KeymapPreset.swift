import Foundation

/// A named set of keys that sits between the Default keys and the user's file (V-14). A preset is a data file
/// in `Presets/`, in the same format as `Keymap.json`, so a new preset needs no code.
public struct KeymapPreset: Sendable, Identifiable, Equatable {
    /// The file name without `.json`. A keymap file names its preset by this.
    public let id: String
    public var name: String
    public var file: KeymapFile

    public init(id: String, name: String, file: KeymapFile) {
        self.id = id
        self.name = name
        self.file = file
    }

    /// The presets that ship with the app, by name.
    public static let bundled: [KeymapPreset] = {
        guard let directory = Bundle.module.url(forResource: "Presets", withExtension: nil) else { return [] }
        return load(from: directory)
    }()

    /// Every `.json` file in `directory` that decodes as a keymap file. A file that does not decode is left out.
    public static func load(from directory: URL) -> [KeymapPreset] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let file = try? KeymapFile.decode(data) else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            return KeymapPreset(id: id, name: file.name ?? id, file: file)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
