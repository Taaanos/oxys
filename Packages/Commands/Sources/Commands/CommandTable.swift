/// Every command the app has, in menu order within each group. Adding an entry here gives it a menu item and
/// its default keys; the app registers the handler. Later stories append to `standard`.
public struct CommandTable: Sendable {
    public let commands: [Command]
    private let byID: [CommandID: Command]

    public init(_ commands: [Command]) {
        self.commands = commands
        byID = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: CommandID) -> Command? { byID[id] }

    /// The menu's commands as groups (one divider between groups), in table order.
    public func groups(in menu: AppMenu) -> [[Command]] {
        let inMenu = commands.filter { $0.menu?.menu == menu }
        return Dictionary(grouping: inMenu, by: { $0.menu?.group ?? 0 })
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    /// The Default preset: every command's own keys.
    public var defaultBindings: [KeyBinding] {
        commands.flatMap { command in command.defaultKeys.flatMap(command.bindings(for:)) }
    }

    public static let standard = CommandTable([
        Command("file.open", "Open Folder…", menu: .init(.file),
                keys: [Shortcut(.position(.o), [.command])]),
        // The "3 new files, reload" banner's action (M-10).
        Command("file.reload", "Reload Folder", menu: .init(.file), requires: .photos,
                keys: [Shortcut(.position(.r), [.command, .option])]),
        // Decisions that could not be written next to the photos go to another folder (M-11).
        Command("file.saveDecisions", "Save Decisions To…", menu: .init(.file), requires: .photos,
                keys: [Shortcut(.position(.s), [.command, .shift])]),

        // Undo and redo (M-09). The titles in the menu gain the action's name ("Undo Set Rating").
        Command("edit.undo", "Undo", menu: .init(.edit, group: 0), requires: .photos,
                keys: [Shortcut(.position(.z), [.command])]),
        Command("edit.redo", "Redo", menu: .init(.edit, group: 0), requires: .photos,
                keys: [Shortcut(.position(.z), [.command, .shift])]),

        Command("nav.next", "Next Photo", menu: .init(.photo, group: 0), requires: .photos, repeats: true,
                keys: [Shortcut(.position(.rightArrow))]),
        Command("nav.previous", "Previous Photo", menu: .init(.photo, group: 0), requires: .photos, repeats: true,
                keys: [Shortcut(.position(.leftArrow))]),
        Command("nav.first", "First Photo", menu: .init(.photo, group: 0), requires: .photos,
                keys: [Shortcut(.position(.home))]),
        Command("nav.last", "Last Photo", menu: .init(.photo, group: 0), requires: .photos,
                keys: [Shortcut(.position(.end))]),

        // Cull (M-06). Each has a ⇧ twin that also moves to the next photo. Keypad digits mirror the digit row.
        Command("cull.rate.0", "Clear Rating", menu: .init(.photo, group: 1), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit0)), Shortcut(.position(.keypad0))]),
        Command("cull.rate.1", "1 Star", menu: .init(.photo, group: 1), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit1)), Shortcut(.position(.keypad1))]),
        Command("cull.rate.2", "2 Stars", menu: .init(.photo, group: 1), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit2)), Shortcut(.position(.keypad2))]),
        Command("cull.rate.3", "3 Stars", menu: .init(.photo, group: 1), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit3)), Shortcut(.position(.keypad3))]),
        Command("cull.rate.4", "4 Stars", menu: .init(.photo, group: 1), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit4)), Shortcut(.position(.keypad4))]),
        Command("cull.rate.5", "5 Stars", menu: .init(.photo, group: 1), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit5)), Shortcut(.position(.keypad5))]),
        Command("cull.rate.down", "Decrease Rating", menu: .init(.photo, group: 1), modes: cull, requires: .photos,
                shiftAdvances: true, keys: [Shortcut(.character("["))]),
        Command("cull.rate.up", "Increase Rating", menu: .init(.photo, group: 1), modes: cull, requires: .photos,
                shiftAdvances: true, keys: [Shortcut(.character("]"))]),
        Command("cull.reject", "Reject", menu: .init(.photo, group: 2), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.x))]),
        Command("cull.label.red", "Red Label", menu: .init(.photo, group: 3), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit6)), Shortcut(.position(.keypad6))]),
        Command("cull.label.yellow", "Yellow Label", menu: .init(.photo, group: 3), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit7)), Shortcut(.position(.keypad7))]),
        Command("cull.label.green", "Green Label", menu: .init(.photo, group: 3), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit8)), Shortcut(.position(.keypad8))]),
        Command("cull.label.blue", "Blue Label", menu: .init(.photo, group: 3), modes: cull, requires: .photos, shiftAdvances: true,
                keys: [Shortcut(.position(.digit9)), Shortcut(.position(.keypad9))]),
        Command("cull.label.purple", "Purple Label", menu: .init(.photo, group: 3), modes: cull, requires: .photos),
    ])

    /// Cull keys act on the active photo in Loupe and Compare. Grid joins in M-12 (G-5).
    private static let cull: Set<ViewMode> = [.loupe, .compare]
}
