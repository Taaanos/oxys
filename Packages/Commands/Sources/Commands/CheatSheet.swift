/// The headings of the cheat sheet, in the PRD's order. A command's group comes from the prefix of its ID
/// (`cull.rate.3` is Cull), so a new command needs no extra entry; a prefix not listed here fails a test.
public enum CheatGroup: Int, CaseIterable, Sendable, Comparable {
    case cull, navigation, zoom, info, selection, filter, file, help

    public static func < (a: CheatGroup, b: CheatGroup) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .cull: "Rate, Label and Reject"
        case .navigation: "Move and Switch View"
        case .zoom: "Zoom and Pan"
        case .info: "Info"
        case .selection: "Select"
        case .filter: "Filter and Sort"
        case .file: "Files"
        case .help: "Help"
        }
    }

    static let prefixes: [String: CheatGroup] = [
        "cull": .cull, "nav": .navigation, "view": .navigation, "grid": .navigation,
        "zoom": .zoom, "pan": .zoom, "info": .info, "select": .selection, "filter": .filter,
        "file": .file, "edit": .file, "help": .help,
    ]
}

extension Command {
    /// Nil only for an ID whose prefix has no cheat-sheet group (a test catches that).
    public var cheatGroup: CheatGroup? {
        CheatGroup.prefixes[String(id.rawValue.prefix { $0 != "." })]
    }
}

public struct CheatSection: Sendable {
    public var group: CheatGroup
    public var entries: [Entry]

    public struct Entry: Sendable, Identifiable {
        public var id: CommandID
        public var title: String
        /// Every key of the command in the current keymap; empty when the user unbound it.
        public var shortcuts: [Shortcut]
        public var advances: Bool
    }
}

public enum CheatSheet {
    /// The commands that work in `mode`, grouped, in table order; commands without a key are listed too
    /// (they are in the menu), since the cheat sheet shows what exists.
    public static func sections(table: CommandTable, keymap: Keymap, mode: ViewMode) -> [CheatSection] {
        let relevant = table.commands.filter { $0.modes.isEmpty || $0.modes.contains(mode) }
        return CheatGroup.allCases.compactMap { group in
            let entries = relevant.filter { $0.cheatGroup == group }.map {
                CheatSection.Entry(id: $0.id, title: $0.title, shortcuts: keymap.shortcuts(for: $0.id), advances: $0.shiftAdvances)
            }
            return entries.isEmpty ? nil : CheatSection(group: group, entries: entries)
        }
    }
}
