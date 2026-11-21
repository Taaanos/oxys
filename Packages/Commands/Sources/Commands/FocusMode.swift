/// A part of the window that focus mode hides. The RAW badge, the decision, the overlay readouts, banners and the
/// HUD are not panels: focus mode never hides them.
public enum Panel: CaseIterable, Sendable {
    case toolbar, inspector, filterBar, filmStrip, info, histogram
}

/// Focus mode (V-24): a flag that sits on top of each panel's saved on/off state and never changes it. A panel is
/// on screen when it is saved on and either focus mode is off or the user asked for that panel since focus mode began.
public struct FocusMode: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case off
        case on(revealed: Set<Panel>)
    }

    private var state: State = .off

    public var isOn: Bool {
        if case .on = state { true } else { false }
    }

    /// Panels the user called up during this focus session. Always empty when focus mode is off.
    public var revealed: Set<Panel> {
        if case .on(let set) = state { set } else { [] }
    }

    public init() {}

    /// What the caller does with the panel's saved state after `press`.
    public enum Outcome: Equatable, Sendable {
        /// Flip the saved state, as with focus mode off.
        case toggle
        /// The panel is saved on and was hidden by focus mode: nothing to change, it shows now.
        case reveal
        /// The panel is saved off: turn it on (to its first level, if it has levels). It shows now.
        case turnOnAndReveal
    }

    /// `⇥`: enter focus mode with nothing revealed, or leave it.
    public mutating func toggle() {
        switch state {
        case .off: state = .on(revealed: [])
        case .on: state = .off
        }
    }

    public func isVisible(_ panel: Panel, saved: Bool) -> Bool {
        guard saved else { return false }
        switch state {
        case .off: return true
        case .on(let revealed): return revealed.contains(panel)
        }
    }

    /// A command that shows a panel without toggling it (`⌘F` opens the filter bar): in focus mode that panel shows too.
    public mutating func reveal(_ panel: Panel) {
        guard case .on(var revealed) = state else { return }
        revealed.insert(panel)
        state = .on(revealed: revealed)
    }

    /// A panel's own key. In focus mode a hidden panel is shown on its own and the rest stay hidden; a panel already
    /// shown toggles as usual, and one turned off leaves the revealed set.
    public mutating func press(_ panel: Panel, saved: Bool) -> Outcome {
        guard case .on(var revealed) = state else { return .toggle }
        if revealed.remove(panel) != nil {
            state = .on(revealed: revealed)
            return .toggle
        }
        revealed.insert(panel)
        state = .on(revealed: revealed)
        return saved ? .reveal : .turnOnAndReveal
    }
}
