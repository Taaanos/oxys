import Foundation

/// The per-user keymap file (M-05/Q1): only the overrides, versioned.
///
/// ```json
/// { "version": 1,
///   "bindings": {
///     "nav.next": [ { "position": "rightArrow" }, { "position": "d" } ],
///     "nav.last": [],
///     "zoom.in": [ { "character": "=", "modifiers": ["command"] } ] } }
/// ```
/// A command listed here loses its default keys and gets exactly the ones given (an empty list unbinds it).
/// A key claimed here is taken away from any other command's default binding. Position keys use the
/// `PhysicalKey` case names; `modifiers` are `shift`, `control`, `option`, `command`.
public struct KeymapFile: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
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

    public init(version: Int = KeymapFile.currentVersion, bindings: [String: [Entry]]) {
        self.version = version
        self.bindings = bindings
    }
}

/// The keymap in force, and what was wrong with the user's file (so a typo never costs the user their keys).
public struct ResolvedKeymap: Sendable {
    public var keymap: Keymap
    public var problems: [String]
}

extension Keymap {
    /// Bindings for one command, in order. The first is what menus show.
    public func shortcuts(for command: CommandID) -> [Shortcut] {
        bindings.filter { $0.command == command && !$0.advances }.map { Shortcut($0.key, $0.modifiers) }
    }

    /// The Default preset with the user's overrides applied. Bad entries are skipped and reported; an
    /// unreadable file leaves the defaults alone.
    public static func resolve(table: CommandTable, userFile: Data?) -> ResolvedKeymap {
        var bindings = table.defaultBindings
        guard let userFile else { return ResolvedKeymap(keymap: Keymap(bindings), problems: []) }
        var problems: [String] = []

        let file: KeymapFile
        do { file = try JSONDecoder().decode(KeymapFile.self, from: userFile) } catch {
            return ResolvedKeymap(keymap: Keymap(bindings), problems: ["Keymap file is not valid: \(error.localizedDescription)"])
        }
        guard file.version == KeymapFile.currentVersion else {
            return ResolvedKeymap(keymap: Keymap(bindings),
                                  problems: ["Keymap file has version \(file.version); this app reads version \(KeymapFile.currentVersion)."])
        }

        var claimed: [(command: CommandID, shortcut: Shortcut, modes: Set<ViewMode>)] = []
        var overridden: Set<CommandID> = []
        for (name, entries) in file.bindings.sorted(by: { $0.key < $1.key }) {
            guard let command = table[CommandID(rawValue: name)] else {
                problems.append("Keymap: unknown command \"\(name)\".")
                continue
            }
            overridden.insert(command.id)
            for entry in entries {
                switch Self.shortcut(from: entry) {
                case .failure(let error):
                    problems.append("Keymap: \(name): \(error.message)")
                case .success(let shortcut):
                    if let other = claimed.first(where: {
                        $0.shortcut == shortcut && Self.overlap($0.modes, command.modes)
                    }) {
                        problems.append("Keymap: \(name) and \(other.command.rawValue) both use the same key; kept \(other.command.rawValue).")
                    } else {
                        claimed.append((command.id, shortcut, command.modes))
                    }
                }
            }
        }

        bindings.removeAll { b in
            overridden.contains(b.command)
                || claimed.contains { $0.shortcut == Shortcut(b.key, b.modifiers) && Self.overlap($0.modes, b.modes) }
        }
        for claim in claimed {
            if let command = table[claim.command] { bindings.append(contentsOf: command.bindings(for: claim.shortcut)) }
        }
        return ResolvedKeymap(keymap: Keymap(bindings), problems: problems)
    }

    private static func overlap(_ a: Set<ViewMode>, _ b: Set<ViewMode>) -> Bool {
        a.isEmpty || b.isEmpty || !a.isDisjoint(with: b)
    }

    private static func shortcut(from entry: KeymapFile.Entry) -> Result<Shortcut, KeymapEntryError> {
        var modifiers: KeyModifiers = []
        for name in entry.modifiers ?? [] {
            switch name {
            case "shift": modifiers.insert(.shift)
            case "control": modifiers.insert(.control)
            case "option": modifiers.insert(.option)
            case "command": modifiers.insert(.command)
            default: return .failure(.init("unknown modifier \"\(name)\"."))
            }
        }
        switch (entry.position, entry.character) {
        case (let name?, nil):
            guard let key = PhysicalKey(name: name) else { return .failure(.init("unknown key \"\(name)\".")) }
            return .success(Shortcut(.position(key), modifiers))
        case (nil, let text?):
            guard text.count == 1, let c = text.first else { return .failure(.init("\"character\" must be one character.")) }
            // ⇧ and ⌥ are part of producing the character, so a character binding cannot name them.
            guard modifiers.isDisjoint(with: [.shift, .option]) else {
                return .failure(.init("a character key cannot list shift or option; use \"position\"."))
            }
            return .success(Shortcut(.character(c), modifiers))
        default:
            return .failure(.init("give exactly one of \"position\" and \"character\"."))
        }
    }
}

private struct KeymapEntryError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
