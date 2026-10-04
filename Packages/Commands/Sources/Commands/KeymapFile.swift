import Foundation

/// The per-user keymap file (M-05/Q1): only the overrides, versioned.
///
/// ```json
/// { "version": 1,
///   "preset": "fastrawviewer",
///   "bindings": {
///     "nav.next": [ { "position": "rightArrow" }, { "position": "d" } ],
///     "nav.last": [],
///     "zoom.in": [ { "character": "=", "modifiers": ["command"] } ] } }
/// ```
/// A command listed here loses its default keys and gets exactly the ones given (an empty list unbinds it).
/// A key claimed here is taken away from any other command's default binding. Position keys use the
/// `PhysicalKey` case names; `modifiers` are `shift`, `control`, `option`, `command`.
///
/// `preset` (V-14) names a bundled preset that sits between the Default keys and this file. A preset file has
/// the same shape and also carries a `name` for the picker.
public struct KeymapFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var preset: String?
    public var name: String?
    public var bindings: [String: [Entry]]

    public struct Entry: Codable, Sendable, Equatable {
        public var position: String?
        public var character: String?
        public var modifiers: [String]?

        public init(position: String? = nil, character: String? = nil, modifiers: [String]? = nil) {
            self.position = position
            self.character = character
            self.modifiers = modifiers
        }
    }

    public init(version: Int = KeymapFile.currentVersion, preset: String? = nil, name: String? = nil,
                bindings: [String: [Entry]] = [:]) {
        self.version = version
        self.preset = preset
        self.name = name
        self.bindings = bindings
    }

    /// Sorted keys and indentation, so a person can still read and edit the file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> KeymapFile {
        try JSONDecoder().decode(KeymapFile.self, from: data)
    }
}

extension KeymapFile.Entry {
    public init(_ shortcut: Shortcut) {
        switch shortcut.key {
        case .position(let key): self.init(position: key.name)
        case .character(let c): self.init(character: String(c))
        }
        var names: [String] = []
        if shortcut.modifiers.contains(.shift) { names.append("shift") }
        if shortcut.modifiers.contains(.control) { names.append("control") }
        if shortcut.modifiers.contains(.option) { names.append("option") }
        if shortcut.modifiers.contains(.command) { names.append("command") }
        modifiers = names.isEmpty ? nil : names
    }

    /// The shortcut this entry names, or a one-line reason it cannot be used.
    public func shortcut() -> Result<Shortcut, KeymapEntryError> {
        var mods: KeyModifiers = []
        for name in modifiers ?? [] {
            switch name {
            case "shift": mods.insert(.shift)
            case "control": mods.insert(.control)
            case "option": mods.insert(.option)
            case "command": mods.insert(.command)
            default: return .failure(.init("unknown modifier \"\(name)\"."))
            }
        }
        switch (position, character) {
        case (let name?, nil):
            guard let key = PhysicalKey(name: name) else { return .failure(.init("unknown key \"\(name)\".")) }
            return .success(Shortcut(.position(key), mods))
        case (nil, let text?):
            guard text.count == 1, let c = text.first else { return .failure(.init("\"character\" must be one character.")) }
            // ⇧ and ⌥ are part of producing the character, so a character binding cannot name them.
            guard mods.isDisjoint(with: [.shift, .option]) else {
                return .failure(.init("a character key cannot list shift or option; use \"position\"."))
            }
            return .success(Shortcut(.character(c), mods))
        default:
            return .failure(.init("give exactly one of \"position\" and \"character\"."))
        }
    }
}

public struct KeymapEntryError: Error, Sendable, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
}

/// The keymap in force, and what was wrong with the user's file (so a typo never costs the user their keys).
public struct ResolvedKeymap: Sendable {
    public var keymap: Keymap
    public var problems: [String]

    public init(keymap: Keymap, problems: [String]) {
        self.keymap = keymap
        self.problems = problems
    }
}

extension Keymap {
    /// Bindings for one command, in order. The first is what menus show.
    public func shortcuts(for command: CommandID) -> [Shortcut] {
        bindings.filter { $0.command == command && !$0.advances }.map { Shortcut($0.key, $0.modifiers) }
    }

    /// The Default preset with the user's overrides applied. Bad entries are skipped and reported; an
    /// unreadable file leaves the defaults alone. A file that names a preset gets that preset's keys between the two.
    public static func resolve(table: CommandTable, userFile: Data?, presets: [KeymapPreset] = KeymapPreset.bundled) -> ResolvedKeymap {
        guard let userFile else { return resolve(table: table, file: nil, presets: presets) }
        let file: KeymapFile
        do { file = try KeymapFile.decode(userFile) } catch {
            let defaults = resolve(table: table, file: nil, presets: presets)
            return ResolvedKeymap(keymap: defaults.keymap, problems: ["Keymap file is not valid: \(error.localizedDescription)"])
        }
        return resolve(table: table, file: file, presets: presets)
    }

    /// The same, from a file that is already decoded.
    public static func resolve(table: CommandTable, file: KeymapFile?, presets: [KeymapPreset] = KeymapPreset.bundled) -> ResolvedKeymap {
        var bindings = table.defaultBindings
        guard let file else { return ResolvedKeymap(keymap: Keymap(bindings), problems: []) }
        guard file.version == KeymapFile.currentVersion else {
            return ResolvedKeymap(keymap: Keymap(bindings),
                                  problems: ["Keymap file has version \(file.version); this app reads version \(KeymapFile.currentVersion)."])
        }
        var problems: [String] = []
        if let id = file.preset {
            if let preset = presets.first(where: { $0.id == id }) {
                apply(preset.file, to: &bindings, table: table, label: "Preset \(preset.name)", problems: &problems)
            } else {
                problems.append("Keymap: unknown preset \"\(id)\".")
            }
        }
        apply(file, to: &bindings, table: table, label: "Keymap", problems: &problems)
        return ResolvedKeymap(keymap: Keymap(bindings), problems: problems)
    }

    /// One layer: the commands it lists lose their keys and get its keys; its keys are taken from other commands.
    private static func apply(_ file: KeymapFile, to bindings: inout [KeyBinding], table: CommandTable,
                              label: String, problems: inout [String]) {
        var claimed: [(command: CommandID, shortcut: Shortcut, modes: Set<ViewMode>)] = []
        var overridden: Set<CommandID> = []
        for (name, entries) in file.bindings.sorted(by: { $0.key < $1.key }) {
            guard let command = table[CommandID(rawValue: name)] else {
                problems.append("\(label): unknown command \"\(name)\".")
                continue
            }
            overridden.insert(command.id)
            for entry in entries {
                switch entry.shortcut() {
                case .failure(let error):
                    problems.append("\(label): \(name): \(error.message)")
                case .success(let shortcut):
                    if let other = claimed.first(where: {
                        $0.shortcut == shortcut && overlap($0.modes, command.modes)
                    }) {
                        problems.append("\(label): \(name) and \(other.command.rawValue) both use the same key; kept \(other.command.rawValue).")
                    } else {
                        claimed.append((command.id, shortcut, command.modes))
                    }
                }
            }
        }

        bindings.removeAll { b in
            overridden.contains(b.command)
                || claimed.contains { $0.shortcut == Shortcut(b.key, b.modifiers) && overlap($0.modes, b.modes) }
        }
        for claim in claimed {
            if let command = table[claim.command] { bindings.append(contentsOf: command.bindings(for: claim.shortcut)) }
        }
    }

    static func overlap(_ a: Set<ViewMode>, _ b: Set<ViewMode>) -> Bool {
        a.isEmpty || b.isEmpty || !a.isDisjoint(with: b)
    }
}
