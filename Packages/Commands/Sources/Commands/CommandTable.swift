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
        commands.flatMap { command in command.defaultKeys.map(command.binding(for:)) }
    }

    public static let standard = CommandTable([
        Command("file.open", "Open Folder…", menu: .init(.file),
                keys: [Shortcut(.position(.o), [.command])]),

        Command("nav.next", "Next Photo", menu: .init(.photo, group: 0), requires: .photos, repeats: true,
                keys: [Shortcut(.position(.rightArrow))]),
        Command("nav.previous", "Previous Photo", menu: .init(.photo, group: 0), requires: .photos, repeats: true,
                keys: [Shortcut(.position(.leftArrow))]),
        Command("nav.first", "First Photo", menu: .init(.photo, group: 0), requires: .photos,
                keys: [Shortcut(.position(.home))]),
        Command("nav.last", "Last Photo", menu: .init(.photo, group: 0), requires: .photos,
                keys: [Shortcut(.position(.end))]),
    ])
}
