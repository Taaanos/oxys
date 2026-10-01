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

        // Grid (M-12) and the mode diagram (M-13). Up and down move by a row. Return, Space and E open the
        // photo in Loupe; G and Esc go back to Grid. Compare (V-08) will join `modes` as it gets its keys.
        Command("nav.up", "Up a Row", menu: .init(.photo, group: 0), modes: grid, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.upArrow))]),
        Command("nav.down", "Down a Row", menu: .init(.photo, group: 0), modes: grid, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.downArrow))]),
        Command("view.loupe", "Open in Loupe", menu: .init(.view, group: 0), modes: [.grid, .compare], requires: .photos,
                keys: [Shortcut(.position(.e)), Shortcut(.position(.return)), Shortcut(.position(.space))]),
        Command("view.grid", "Show Grid", menu: .init(.view, group: 0), modes: [.loupe, .compare], requires: .photos,
                keys: [Shortcut(.position(.g)), Shortcut(.position(.escape))]),
        Command("grid.smaller", "Smaller Thumbnails", menu: .init(.view, group: 1), modes: grid, requires: .photos, repeats: true,
                keys: [Shortcut(.character("-")), Shortcut(.position(.minus), [.command])]),
        Command("grid.larger", "Larger Thumbnails", menu: .init(.view, group: 1), modes: grid, requires: .photos, repeats: true,
                keys: [Shortcut(.character("=")), Shortcut(.position(.equal), [.command]),
                       Shortcut(.position(.equal), [.command, .shift])]),

        // Zoom (M-14). `Z` toggles Fit and 1:1, and shows 1:1 only while held; `⌘1` and `⌘0` are explicit.
        Command("zoom.toggle", "Toggle Fit / 1:1", menu: .init(.view, group: 1), modes: loupe, requires: .photos,
                kind: .toggleOrHold, keys: [Shortcut(.position(.z))]),
        Command("zoom.actual", "Actual Size (1:1)", menu: .init(.view, group: 1), modes: loupe, requires: .photos,
                keys: [Shortcut(.position(.digit1), [.command])]),
        Command("zoom.fit", "Zoom to Fit", menu: .init(.view, group: 1), modes: loupe, requires: .photos,
                keys: [Shortcut(.position(.digit0), [.command])]),
        // Steps and panning (M-15). `=` and `−` step Fit, 25, 50, 100, 200, 400% in Loupe, and `⌘+` and `⌘−` do too
        // (Grid gives the same keys to its thumbnails). `⌥`-arrows pan a quarter of the view, `⌥⇧` a whole view.
        // `⌥Z` turns sticky zoom (zoom and spot carry over to the next photo) off and on.
        Command("zoom.in", "Zoom In", menu: .init(.view, group: 1), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.character("=")), Shortcut(.position(.equal), [.command]),
                       Shortcut(.position(.equal), [.command, .shift])]),
        Command("zoom.out", "Zoom Out", menu: .init(.view, group: 1), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.character("-")), Shortcut(.position(.minus), [.command])]),
        Command("zoom.sticky", "Keep Zoom Between Photos", menu: .init(.view, group: 1), modes: loupe, requires: .photos,
                kind: .toggle, keys: [Shortcut(.position(.z), [.option])]),
        Command("pan.left", "Pan Left", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.leftArrow), [.option])]),
        Command("pan.right", "Pan Right", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.rightArrow), [.option])]),
        Command("pan.up", "Pan Up", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.upArrow), [.option])]),
        Command("pan.down", "Pan Down", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.downArrow), [.option])]),
        Command("pan.pageLeft", "Pan Left a View", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.leftArrow), [.option, .shift])]),
        Command("pan.pageRight", "Pan Right a View", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.rightArrow), [.option, .shift])]),
        Command("pan.pageUp", "Pan Up a View", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.upArrow), [.option, .shift])]),
        Command("pan.pageDown", "Pan Down a View", menu: .init(.view, group: 3), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.downArrow), [.option, .shift])]),

        // EXIF panel (M-16). `I` shows or hides it until M-18's cycle takes the key over. `↑` and `↓` move between
        // its values, `⌘C` copies the focused one (all of them when none is), and Show in Maps opens the GPS spot.
        Command("info.exif", "Show EXIF", menu: .init(.view, group: 4), modes: loupe, requires: .photos,
                kind: .toggle, keys: [Shortcut(.position(.i))]),
        Command("info.fieldNext", "Next EXIF Value", menu: .init(.view, group: 4), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.downArrow))]),
        Command("info.fieldPrevious", "Previous EXIF Value", menu: .init(.view, group: 4), modes: loupe, requires: .photos, repeats: true,
                keys: [Shortcut(.position(.upArrow))]),
        Command("info.copy", "Copy EXIF Value", menu: .init(.view, group: 4), modes: loupe, requires: .photos,
                keys: [Shortcut(.position(.c), [.command])]),
        Command("info.maps", "Show in Maps", menu: .init(.view, group: 4), modes: loupe, requires: .photos),

        // `⇥` hides the toolbar and panels; the pointer at the top edge, or `⇥` again, brings them back (M-13).
        Command("view.chrome", "Hide Toolbar", menu: .init(.view, group: 2),
                keys: [Shortcut(.position(.tab))]),

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

    private static let grid: Set<ViewMode> = [.grid]
    private static let loupe: Set<ViewMode> = [.loupe]

    /// Cull keys act on the active photo in every mode. In Grid they will act on the whole selection (G-5, M-19).
    private static let cull: Set<ViewMode> = [.grid, .loupe, .compare]
}
