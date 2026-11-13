/// The headings of the cheat sheet, in the PRD's order. A command's group comes from the prefix of its ID
/// (`cull.rate.3` is Cull), so a new command needs no extra entry; a prefix not listed here fails a test.
public enum CheatGroup: Int, CaseIterable, Sendable, Comparable {
    case cull, navigation, compare, zoom, overlays, info, selection, filter, file, help

    public static func < (a: CheatGroup, b: CheatGroup) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .cull: "Rate, Label and Reject"
        case .navigation: "Move and Switch View"
        case .compare: "Compare"
        case .zoom: "Zoom and Pan"
        case .overlays: "Overlays"
        case .info: "Info"
        case .selection: "Select"
        case .filter: "Filter and Sort"
        case .file: "Files"
        case .help: "Help"
        }
    }

    static let prefixes: [String: CheatGroup] = [
        "cull": .cull, "nav": .navigation, "view": .navigation, "grid": .navigation,
        "compare": .compare, "zoom": .zoom, "pan": .zoom, "overlay": .overlays, "info": .info, "select": .selection, "filter": .filter,
        "file": .file, "edit": .file, "help": .help,
    ]
}

extension Command {
    /// Nil only for an ID whose prefix has no cheat-sheet group (a test catches that).
    public var cheatGroup: CheatGroup? {
        CheatGroup.prefixes[String(id.rawValue.prefix { $0 != "." })]
    }
}

import Foundation

public struct CheatSection: Sendable {
    public var group: CheatGroup
    public var entries: [Entry]

    public struct Entry: Sendable, Identifiable {
        public var id: CommandID
        public var group: CheatGroup
        public var title: String
        public var symbol: String?
        /// Every key of the command in the current keymap; empty when the user unbound it.
        public var shortcuts: [Shortcut]
        public var advances: Bool
        public var isEnabled: Bool
        public var isOn: Bool
    }
}

public enum CheatSheet {
    /// The commands that work in `mode`, grouped, in table order; commands without a key are listed too
    /// (they are in the menu), since the command bar shows what exists.
    public static func sections(
        table: CommandTable,
        keymap: Keymap,
        mode: ViewMode,
        title: (Command) -> String = \.title,
        isEnabled: (Command) -> Bool = { _ in true },
        isOn: (Command) -> Bool = { _ in false }
    ) -> [CheatSection] {
        let relevant = table.commands.filter { $0.modes.isEmpty || $0.modes.contains(mode) }
        return CheatGroup.allCases.compactMap { group in
            let entries = relevant.filter { $0.cheatGroup == group }.map { command in
                CheatSection.Entry(
                    id: command.id,
                    group: group,
                    title: title(command),
                    symbol: command.symbol,
                    shortcuts: keymap.shortcuts(for: command.id),
                    advances: command.shiftAdvances,
                    isEnabled: isEnabled(command),
                    isOn: isOn(command)
                )
            }
            return entries.isEmpty ? nil : CheatSection(group: group, entries: entries)
        }
    }

    /// Searches and ranks `sections` by `query`. Every whitespace-separated token must match the entry's
    /// title, group title, or any of its shortcut labels. Within the same match tier, enabled entries come first.
    @MainActor public static func search(sections: [CheatSection], query: String) -> [CheatSection.Entry] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        let entries = sections.flatMap(\.entries)
        guard !tokens.isEmpty else { return entries }

        var ranked: [(tier: Int, index: Int, entry: CheatSection.Entry)] = []
        for (index, entry) in entries.enumerated() {
            let foldedTitle = fold(entry.title)
            let foldedGroup = fold(entry.group.title)
            let foldedKeys = entry.shortcuts.map { fold(KeyLabels.label(for: $0)) }
            let words = foldedTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

            var worstTier = 0
            var matched = true
            for token in tokens {
                if foldedTitle.hasPrefix(token) {
                    worstTier = max(worstTier, 0)
                } else if words.contains(where: { $0.hasPrefix(token) }) {
                    worstTier = max(worstTier, 1)
                } else if foldedTitle.contains(token) {
                    worstTier = max(worstTier, 2)
                } else if foldedGroup.contains(token) || foldedKeys.contains(where: { $0.contains(token) }) {
                    worstTier = max(worstTier, 3)
                } else {
                    matched = false
                    break
                }
            }
            if matched {
                ranked.append((worstTier, index, entry))
            }
        }

        return ranked.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.entry.isEnabled != b.entry.isEnabled { return a.entry.isEnabled && !b.entry.isEnabled }
            return a.index < b.index
        }.map(\.entry)
    }

    /// Moves selection across enabled entries in `entries` by `delta` (`+1` or `-1`), wrapping around.
    public static func stepSelection(in entries: [CheatSection.Entry], from current: CommandID?, by delta: Int) -> CommandID? {
        let enabled = entries.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        guard let current, let idx = enabled.firstIndex(where: { $0.id == current }) else {
            return delta >= 0 ? enabled.first?.id : enabled.last?.id
        }
        let next = ((idx + delta) % enabled.count + enabled.count) % enabled.count
        return enabled[next].id
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
