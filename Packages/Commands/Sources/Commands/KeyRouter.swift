/// One key event, reduced to what routing needs. The app adapter builds it from an `NSEvent`.
public struct KeyInput: Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var isDown: Bool
    public var isRepeat: Bool
    /// Seconds on any monotonic clock (`NSEvent.timestamp`); only differences are used.
    public var timestamp: Double
    /// What the key types on the ASCII-capable layout with this event's `⇧`/`⌥`, if resolved.
    public var character: Character?

    public init(keyCode: UInt16, modifiers: KeyModifiers = [], isDown: Bool = true, isRepeat: Bool = false,
                timestamp: Double, character: Character? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.timestamp = timestamp
        self.character = character
    }
}

/// Who has keyboard focus. Bare keys only act when the canvas does.
public enum KeyFocus: Sendable { case canvas, textInput }

public enum RoutedAction: Sendable, Equatable {
    /// Run the command. For a `toggleOrHold` key this is the key-down toggle.
    case perform(CommandID)
    /// The `⇧` twin of a cull key: run the command, then move to the next photo.
    case performAdvancing(CommandID)
    /// A `toggleOrHold` key was held past the threshold and let go: undo the toggle it made.
    case releaseHold(CommandID)
    /// `Esc` in a text field: end editing and make the canvas first responder (G-13).
    case returnFocusToCanvas
}

public struct RoutingResult: Sendable, Equatable {
    /// True when the event must not reach the menu bar or the responder chain.
    public var consumed: Bool
    public var actions: [RoutedAction]
    public static let passThrough = RoutingResult(consumed: false, actions: [])
}

/// Maps key events to commands. A value type with no AppKit in it: feed events in, read actions out.
///
/// Tap vs hold uses the events' own timestamps (no timers): on key-up, a `toggleOrHold` key held for at least
/// `holdThreshold` seconds yields `.releaseHold`; a shorter press is a tap and leaves the toggle in place.
public struct KeyRouter: Sendable {
    public var keymap: Keymap
    public var holdThreshold: Double

    private struct Held {
        var command: CommandID
        var behavior: KeyBehavior
        var since: Double
        var advances = false
    }
    /// Keys whose key-down we consumed, by key code, so the matching key-up is consumed too (and so a
    /// modifier change mid-press cannot strand a hold).
    private var held: [UInt16: Held] = [:]

    public init(keymap: Keymap, holdThreshold: Double = 0.25) {
        self.keymap = keymap
        self.holdThreshold = holdThreshold
    }

    public mutating func handle(_ input: KeyInput, mode: ViewMode, focus: KeyFocus) -> RoutingResult {
        if !input.isDown { return keyUp(input) }

        if focus == .textInput {
            // The field owns every key. The one exception is Esc, which hands focus back.
            if input.keyCode == PhysicalKey.escape.rawValue, input.modifiers.isDisjoint(with: [.command, .control, .option]) {
                if !input.isRepeat { held[input.keyCode] = Held(command: "", behavior: .once, since: input.timestamp) }
                return RoutingResult(consumed: true, actions: input.isRepeat ? [] : [.returnFocusToCanvas])
            }
            return .passThrough
        }

        if input.isRepeat, let h = held[input.keyCode] {
            // A press we already own: repeat only if the binding asks for it.
            return RoutingResult(consumed: true, actions: h.behavior == .repeating ? [h.advances ? .performAdvancing(h.command) : .perform(h.command)] : [])
        }

        guard let binding = keymap.match(keyCode: input.keyCode, modifiers: input.modifiers,
                                         character: input.character, mode: mode) else {
            return .passThrough
        }
        held[input.keyCode] = Held(command: binding.command, behavior: binding.behavior, since: input.timestamp,
                                   advances: binding.advances)
        return RoutingResult(consumed: true, actions: [binding.advances ? .performAdvancing(binding.command) : .perform(binding.command)])
    }

    private mutating func keyUp(_ input: KeyInput) -> RoutingResult {
        guard let h = held.removeValue(forKey: input.keyCode) else { return .passThrough }
        if h.behavior == .toggleOrHold, input.timestamp - h.since >= holdThreshold {
            return RoutingResult(consumed: true, actions: [.releaseHold(h.command)])
        }
        return RoutingResult(consumed: true, actions: [])
    }

    /// The window lost key status (or the app resigned) with keys down; no key-up will arrive.
    /// Held toggles past the threshold revert, as if released now.
    public mutating func cancelAll(at timestamp: Double) -> [RoutedAction] {
        defer { held.removeAll() }
        return held.values.compactMap {
            $0.behavior == .toggleOrHold && timestamp - $0.since >= holdThreshold ? .releaseHold($0.command) : nil
        }
    }
}
