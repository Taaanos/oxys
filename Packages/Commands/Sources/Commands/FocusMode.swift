/// A part of the window that focus mode hides. The RAW badge, the decision, the overlay readouts, banners and the
/// HUD are not panels: focus mode never hides them.
public enum Panel: CaseIterable, Sendable {
    case toolbar, inspector, filterBar, filmStrip, info, histogram
}

/// Focus mode (V-24): a flag that sits on top of each panel's saved on/off state and never changes it. A panel is
/// on screen when it is saved on and either focus mode is off or the user asked for that panel since focus mode began.
public struct FocusMode: Equatable, Sendable {
    public private(set) var isOn = false
    /// Panels the user called up during this focus session. Cleared when focus mode ends or begins.
    public private(set) var revealed: Set<Panel> = []

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
        isOn.toggle()
        revealed = []
    }

    public func isVisible(_ panel: Panel, saved: Bool) -> Bool {
        saved && (!isOn || revealed.contains(panel))
    }

    /// A command that shows a panel without toggling it (`⌘F` opens the filter bar): in focus mode that panel shows too.
    public mutating func reveal(_ panel: Panel) {
        if isOn { revealed.insert(panel) }
    }

    /// A panel's own key. In focus mode a hidden panel is shown on its own and the rest stay hidden; a panel already
    /// shown toggles as usual, and one turned off leaves the revealed set.
    public mutating func press(_ panel: Panel, saved: Bool) -> Outcome {
        guard isOn else { return .toggle }
        if revealed.contains(panel) {
            revealed.remove(panel)
            return .toggle
        }
        revealed.insert(panel)
        return saved ? .reveal : .turnOnAndReveal
    }
}
