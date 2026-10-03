/// The menus of the menu bar, in the standard order.
public enum AppMenu: Int, CaseIterable, Sendable, Comparable {
    case app, file, edit, view, photo, filter, window, help

    public static func < (a: AppMenu, b: AppMenu) -> Bool { a.rawValue < b.rawValue }
}

/// Where a command sits in the menu bar. Groups in one menu are separated by a divider.
public struct MenuPlacement: Sendable, Hashable {
    public var menu: AppMenu
    public var group: Int

    public init(_ menu: AppMenu, group: Int = 0) {
        self.menu = menu
        self.group = group
    }
}

public enum CommandKind: Sendable {
    /// Runs and is done.
    case action
    /// Flips a state; the menu item shows a checkmark.
    case toggle
    /// A toggle that is momentary when its key is held (`Z` for 1:1); the handler gets `.releaseHold`.
    case toggleOrHold
}

/// What a command needs before it can run. Items whose needs are not met are disabled, never hidden.
public struct Requirements: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// A folder with photos is showing.
    public static let photos = Requirements(rawValue: 1)
}

/// The state enablement is decided from.
public struct CommandContext: Sendable, Equatable {
    public var mode: ViewMode
    public var hasPhotos: Bool

    public init(mode: ViewMode, hasPhotos: Bool) {
        self.mode = mode
        self.hasPhotos = hasPhotos
    }
}

/// A key and modifiers: one way to trigger a command.
public struct Shortcut: Sendable, Hashable {
    public var key: KeySpec
    public var modifiers: KeyModifiers

    public init(_ key: KeySpec, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// One entry of the command table. The menu item, the cheat sheet, the key binding and Help search all
/// come from this value; the handler is registered by the app.
public struct Command: Sendable, Identifiable {
    public let id: CommandID
    public var title: String
    /// Nil for a command that is not in the menu bar (rare; every command should be).
    public var menu: MenuPlacement?
    /// Empty means every mode. Applies to the command's keys too.
    public var modes: Set<ViewMode>
    public var requires: Requirements
    public var kind: CommandKind
    /// Navigation and zoom steps: the key repeats while held. Everything else ignores auto-repeat (G-12).
    public var repeats: Bool
    /// The bundled Default preset's keys for this command. The first one is shown in the menu.
    public var defaultKeys: [Shortcut]
    /// Every key of this command also has a `⇧` twin that runs it and then moves to the next photo (M-06).
    public var shiftAdvances: Bool
    /// An SF Symbol name for the menu item, the same one the screen shows for this command (D-10). Nil shows none.
    public var symbol: String?

    public init(_ id: CommandID, _ title: String, menu: MenuPlacement?, modes: Set<ViewMode> = [],
                requires: Requirements = [], kind: CommandKind = .action, repeats: Bool = false,
                shiftAdvances: Bool = false, symbol: String? = nil, keys: [Shortcut] = []) {
        self.id = id
        self.title = title
        self.menu = menu
        self.modes = modes
        self.requires = requires
        self.kind = kind
        self.repeats = repeats
        self.defaultKeys = keys
        self.shiftAdvances = shiftAdvances
        self.symbol = symbol
    }

    public var behavior: KeyBehavior {
        if kind == .toggleOrHold { return .toggleOrHold }
        return repeats ? .repeating : .once
    }

    public func isEnabled(in context: CommandContext) -> Bool {
        (modes.isEmpty || modes.contains(context.mode)) && (!requires.contains(.photos) || context.hasPhotos)
    }

    /// The binding for a shortcut, plus its `⇧` twin when the command has one. A character key cannot carry
    /// `⇧`, so its twin is the character `⇧` types on a US layout (`[` becomes `{`); keys without a known
    /// shifted character get no twin.
    func bindings(for shortcut: Shortcut) -> [KeyBinding] {
        var result = [KeyBinding(shortcut.key, shortcut.modifiers, modes: modes, command: id, behavior: behavior)]
        guard shiftAdvances, !shortcut.modifiers.contains(.shift) else { return result }
        let twin: KeySpec? = switch shortcut.key {
        case .position: shortcut.key
        case .character(let c): Self.shifted[c].map(KeySpec.character)
        }
        if let twin {
            let modifiers: KeyModifiers = if case .position = twin { shortcut.modifiers.union(.shift) } else { shortcut.modifiers }
            result.append(KeyBinding(twin, modifiers, modes: modes, command: id, behavior: behavior, advances: true))
        }
        return result
    }

    private static let shifted: [Character: Character] = ["[": "{", "]": "}"]
}
