/// Another command that already uses a key the user wants (V-14).
public struct KeyConflict: Sendable, Equatable {
    public var command: CommandID
    public var title: String
    /// The modes where both commands would answer the key. Never empty: "every mode" is listed in full.
    public var modes: Set<ViewMode>
    /// The other command's key that clashes (for a `⇧` twin, the generated key).
    public var shortcut: Shortcut
    /// The clash is with the generated `⇧` twin of a cull key. That key cannot be taken alone: change the
    /// command's own key first.
    public var isShiftTwin: Bool

    public var isReassignable: Bool { !isShiftTwin }
}

public enum KeyCheck: Sendable, Equatable {
    /// Free: the key was assigned (for `assign`) or can be.
    case ok
    /// The command already has this key.
    case duplicate
    /// macOS or the app uses this key; the text says which.
    case reserved(String)
    case conflicts([KeyConflict])
}

/// The keymap file as the user edits it, with the rules of V-14: one place that adds, replaces, removes and resets
/// keys, checks for conflicts first, and keeps the file small (only commands that differ from the layer below).
/// A value with no AppKit in it: the app reads `file`, writes it, and applies `resolved`.
public struct KeymapEditor: Sendable {
    public let table: CommandTable
    public let presets: [KeymapPreset]
    public private(set) var file: KeymapFile
    public private(set) var resolved: ResolvedKeymap

    public init(table: CommandTable = .standard, file: KeymapFile = KeymapFile(), presets: [KeymapPreset] = KeymapPreset.bundled) {
        self.table = table
        self.presets = presets
        self.file = file
        resolved = Keymap.resolve(table: table, file: file, presets: presets)
    }

    /// Replaces the file (an import, or the file changed on disk).
    public mutating func load(_ file: KeymapFile) {
        self.file = file
        refresh()
    }

    /// A command's keys in force, in order, without `⇧` twins.
    public func shortcuts(for id: CommandID) -> [Shortcut] { resolved.keymap.shortcuts(for: id) }

    /// True when the file lists the command, so its keys are not the layer below's.
    public func isCustomized(_ id: CommandID) -> Bool { file.bindings[id.rawValue] != nil }

    public var customizedCount: Int { file.bindings.count }

    /// The preset in use, or nil for the Default keys.
    public var presetID: String? { file.preset }

    /// Uses another preset (nil: the Default keys). The user's own changes go, because they were made on top of the old
    /// keys; the app asks first. False when no bundled preset has that id.
    @discardableResult
    public mutating func selectPreset(_ id: String?) -> Bool {
        if let id, !presets.contains(where: { $0.id == id }) { return false }
        file.preset = id
        file.bindings = [:]
        refresh()
        return true
    }

    // MARK: checking

    /// What would happen if `shortcut` became a key of `id`. `replacing` is the key it would take the place of.
    public func check(_ shortcut: Shortcut, for id: CommandID, replacing old: Shortcut? = nil) -> KeyCheck {
        guard let command = table[id] else { return .ok }
        let own = shortcuts(for: id).filter { $0 != old }
        if own.contains(where: { USLayout.press(of: $0) == USLayout.press(of: shortcut) }) { return .duplicate }
        if let reason = ReservedShortcuts.reason(for: shortcut, modes: command.modes) { return .reserved(reason) }

        let wanted = command.bindings(for: shortcut).map { (press: USLayout.press(of: Shortcut($0.key, $0.modifiers)), modes: $0.modes) }
        var found: [CommandID: KeyConflict] = [:]
        for other in resolved.keymap.bindings where other.command != id {
            let press = USLayout.press(of: Shortcut(other.key, other.modifiers))
            guard let hit = wanted.first(where: { $0.press == press && Keymap.overlap($0.modes, other.modes) }),
                  let owner = table[other.command] else { continue }
            let overlap = Self.concrete(hit.modes).intersection(Self.concrete(other.modes))
            let conflict = KeyConflict(command: other.command, title: owner.title, modes: overlap,
                                       shortcut: Shortcut(other.key, other.modifiers), isShiftTwin: other.advances)
            // A real key of the other command beats its twin: that is the one the user can reassign.
            if let known = found[other.command], !known.isShiftTwin || other.advances { continue }
            found[other.command] = conflict
        }
        if found.isEmpty { return .ok }
        let order = Dictionary(uniqueKeysWithValues: table.commands.enumerated().map { ($1.id, $0) })
        return .conflicts(found.values.sorted { order[$0.command, default: 0] < order[$1.command, default: 0] })
    }

    private static func concrete(_ modes: Set<ViewMode>) -> Set<ViewMode> { modes.isEmpty ? Set(ViewMode.allCases) : modes }

    // MARK: editing

    /// Gives `shortcut` to `id`, in the place of `old` when given, else added at the end. Returns `.ok` when the
    /// file changed. A conflict is settled only with `reassign`: the other command loses the key. A clash with a
    /// `⇧` twin, a reserved key and a key the command has already never change the file.
    @discardableResult
    public mutating func assign(_ shortcut: Shortcut, to id: CommandID, replacing old: Shortcut? = nil,
                                reassign: Bool = false) -> KeyCheck {
        let result = check(shortcut, for: id, replacing: old)
        switch result {
        case .ok:
            break
        case .conflicts(let conflicts) where reassign && conflicts.allSatisfy(\.isReassignable):
            for conflict in conflicts {
                let taken = USLayout.press(of: conflict.shortcut)
                set(shortcuts(for: conflict.command).filter { USLayout.press(of: $0) != taken }, for: conflict.command)
            }
        default:
            return result
        }
        var keys = shortcuts(for: id)
        if let old, let index = keys.firstIndex(of: old) { keys[index] = shortcut } else { keys.append(shortcut) }
        set(keys, for: id)
        return .ok
    }

    public mutating func remove(_ shortcut: Shortcut, from id: CommandID) {
        set(shortcuts(for: id).filter { $0 != shortcut }, for: id)
    }

    /// Back to the layer below for one command.
    public mutating func reset(_ id: CommandID) {
        file.bindings[id.rawValue] = nil
        refresh()
    }

    /// Back to the preset's keys (the Default keys when no preset is in use). The preset stays.
    public mutating func resetAll() {
        file.bindings = [:]
        refresh()
    }

    /// Writes `keys` as the command's list, or drops the entry when they equal what the layer below gives.
    private mutating func set(_ keys: [Shortcut], for id: CommandID) {
        var below = file
        below.bindings[id.rawValue] = nil
        if Keymap.resolve(table: table, file: below, presets: presets).keymap.shortcuts(for: id) == keys {
            file.bindings[id.rawValue] = nil
        } else {
            file.bindings[id.rawValue] = keys.map(KeymapFile.Entry.init)
        }
        refresh()
    }

    private mutating func refresh() {
        resolved = Keymap.resolve(table: table, file: file, presets: presets)
    }
}
