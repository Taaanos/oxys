/// What a key press means to the recorder in Settings → Keys (V-14).
public enum KeyCapture: Sendable, Equatable {
    /// The key to bind.
    case shortcut(Shortcut)
    /// Bare `Esc`: stop recording. It cannot be recorded, so it stays on the commands that have it (V-14/Q1).
    case cancel
    /// A key the app has no name for.
    case unsupported
}

extension Shortcut {
    /// Reduces a key-down to the shortcut the keymap file stores. Letters, digits, arrows and the rest bind by
    /// position, so they work under any layout. Punctuation with no `⌘ ⌃ ⌥` binds by the character it types
    /// (`[`, `?`, `=`), as the defaults do (F-05/Q1). Punctuation with one of those keeps its position, as
    /// `⌘=` does in the table.
    public static func capture(_ input: KeyInput) -> KeyCapture {
        guard input.isDown, let key = PhysicalKey(rawValue: input.keyCode) else { return .unsupported }
        if key == .escape, input.modifiers.isEmpty { return .cancel }
        if USLayout.punctuation[key] != nil, input.modifiers.isDisjoint(with: [.command, .control, .option]),
           let character = input.character {
            return .shortcut(Shortcut(.character(character)))
        }
        return .shortcut(Shortcut(.position(key), input.modifiers))
    }
}

/// The punctuation keys of a US keyboard. A keymap compares a `.character` binding and a `.position` binding of
/// the same key as one key, because one press can match both (a position hit wins at run time).
enum USLayout {
    static let punctuation: [PhysicalKey: (base: Character, shifted: Character)] = [
        .equal: ("=", "+"), .minus: ("-", "_"), .leftBracket: ("[", "{"), .rightBracket: ("]", "}"),
        .backslash: ("\\", "|"), .slash: ("/", "?"), .comma: (",", "<"), .period: (".", ">"),
        .quote: ("'", "\""), .semicolon: (";", ":"), .grave: ("`", "~"),
    ]

    /// One press of one key: what a shortcut needs, written so equal presses compare equal.
    struct Press: Hashable {
        var key: PhysicalKey?
        var character: Character?
        var modifiers: KeyModifiers
    }

    static func press(of shortcut: Shortcut) -> Press {
        switch shortcut.key {
        case .position(let key):
            return Press(key: key, modifiers: shortcut.modifiers)
        case .character(let c):
            for (key, pair) in punctuation {
                if pair.base == c { return Press(key: key, modifiers: shortcut.modifiers) }
                if pair.shifted == c { return Press(key: key, modifiers: shortcut.modifiers.union(.shift)) }
            }
            return Press(character: c, modifiers: shortcut.modifiers)
        }
    }
}

/// Keys the user cannot give to a command, with the reason to show.
public enum ReservedShortcuts {
    private static let system: [Shortcut: String] = [
        Shortcut(.position(.q), [.command]): "Quit Oxys uses this key.",
        Shortcut(.position(.w), [.command]): "Close Window uses this key.",
        Shortcut(.position(.h), [.command]): "Hide Oxys uses this key.",
        Shortcut(.position(.h), [.command, .option]): "Hide Others uses this key.",
        Shortcut(.position(.m), [.command]): "Minimize uses this key.",
        Shortcut(.position(.comma), [.command]): "Settings uses this key.",
        Shortcut(.position(.slash), [.command, .shift]): "Help search uses this key.",
        Shortcut(.position(.grave), [.command]): "Switch Windows uses this key.",
    ]

    /// Nil when `shortcut` is free to use. `modes` are the modes of the command that would get it (empty = all).
    public static func reason(for shortcut: Shortcut, modes: Set<ViewMode>) -> String? {
        if let text = system[normalized(shortcut)] { return text }
        // Held Space pans the photo in Loupe. The image view handles it, so a command on Space would take it away.
        if normalized(shortcut) == Shortcut(.position(.space)), modes.isEmpty || modes.contains(.loupe) {
            return "Holding Space pans the photo in Loupe."
        }
        return nil
    }

    private static func normalized(_ shortcut: Shortcut) -> Shortcut {
        let press = USLayout.press(of: shortcut)
        guard let key = press.key else { return shortcut }
        return Shortcut(.position(key), press.modifiers)
    }
}
