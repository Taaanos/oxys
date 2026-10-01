/// What the user is looking at. A binding may apply to some modes only.
public enum ViewMode: String, Sendable, Hashable, CaseIterable {
    case grid, loupe, compare
}

/// A command's identity. Keymap files refer to commands by this string, so remapping needs no code change.
public struct CommandID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// How a binding is matched (F-05/Q1).
public enum KeySpec: Hashable, Sendable {
    /// By key position: letters, digits, arrows, `Space`, `Esc`. Works under any input source and any layout.
    /// All four modifiers must match exactly.
    case position(PhysicalKey)
    /// By the character the user's Latin layout produces: punctuation that moves between ISO, JIS and
    /// non-US layouts (`[`, `]`, `\`, `=`, `-`, `?`). Only `⌘` and `⌃` are compared with the binding's
    /// modifiers; `⇧` and `⌥` are part of producing the character, so a binding names none of them.
    case character(Character)
}

/// What a key does when held.
public enum KeyBehavior: Sendable, Hashable {
    /// Fires once per physical press. Auto-repeat is swallowed (G-12): cull keys and overlay toggles.
    case once
    /// Fires on every auto-repeat: navigation, zoom steps, nudging.
    case repeating
    /// Tap toggles, hold is momentary: fires on key-down, and again as a release if the key was held
    /// past the threshold. Auto-repeat is swallowed.
    case toggleOrHold
}

public struct KeyBinding: Sendable, Hashable {
    public var key: KeySpec
    public var modifiers: KeyModifiers
    /// Empty means every mode.
    public var modes: Set<ViewMode>
    public var command: CommandID
    public var behavior: KeyBehavior

    public init(_ key: KeySpec, _ modifiers: KeyModifiers = [], modes: Set<ViewMode> = [],
                command: CommandID, behavior: KeyBehavior = .once) {
        self.key = key
        self.modifiers = modifiers
        self.modes = modes
        self.command = command
        self.behavior = behavior
    }
}

/// The set of bindings. Lookup is a dictionary hit per event.
public struct Keymap: Sendable {
    public private(set) var bindings: [KeyBinding]
    private var byPosition: [PhysicalKey: [KeyBinding]] = [:]
    private var byCharacter: [Character: [KeyBinding]] = [:]

    public init(_ bindings: [KeyBinding]) {
        self.bindings = bindings
        for b in bindings {
            switch b.key {
            case .position(let k): byPosition[k, default: []].append(b)
            case .character(let c): byCharacter[c, default: []].append(b)
            }
        }
    }

    /// `character` is what the key produces on the ASCII-capable layout with the event's `⇧`/`⌥` state.
    /// A positional match wins over a character match.
    func match(keyCode: UInt16, modifiers: KeyModifiers, character: Character?, mode: ViewMode) -> KeyBinding? {
        if let key = PhysicalKey(rawValue: keyCode),
           let hit = byPosition[key]?.first(where: { $0.modifiers == modifiers && $0.applies(in: mode) }) {
            return hit
        }
        if let character, let candidates = byCharacter[character] {
            let held = modifiers.intersection([.command, .control])
            return candidates.first { $0.modifiers == held && $0.applies(in: mode) }
        }
        return nil
    }
}

extension KeyBinding {
    func applies(in mode: ViewMode) -> Bool { modes.isEmpty || modes.contains(mode) }
}
