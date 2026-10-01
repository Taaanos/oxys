import Foundation

/// One photo's change within an undo step: what it was, what it became, and the sidecar label we did not
/// understand (Lightroom's "Select"), which a label change drops and an undo must bring back.
public struct DecisionChange: Sendable, Hashable {
    public var url: URL
    public var before: Decision
    public var after: Decision
    public var unknownLabelBefore: String?
    public var unknownLabelAfter: String?

    public init(url: URL, before: Decision, after: Decision, unknownLabelBefore: String? = nil, unknownLabelAfter: String? = nil) {
        self.url = url
        self.before = before
        self.after = after
        self.unknownLabelBefore = unknownLabelBefore
        self.unknownLabelAfter = unknownLabelAfter
    }
}

/// One undoable action. A key press on a group of photos is one step (G-5).
public struct UndoStep: Sendable, Hashable {
    /// "Set Rating", "Reject": the Edit menu shows it after "Undo" or "Redo".
    public var name: String
    public var changes: [DecisionChange]

    public init(name: String, changes: [DecisionChange]) {
        self.name = name
        self.changes = changes
    }
}

/// The undo and redo history of the open folder (M-09/Q3). Pure value logic; `FolderModel` applies the steps.
public struct UndoStack: Sendable {
    public private(set) var undoSteps: [UndoStep] = []
    public private(set) var redoSteps: [UndoStep] = []

    /// Old steps fall off the bottom; a day of culling is a few thousand keys at most.
    public static let limit = 10_000

    public init() {}

    public var undoName: String? { undoSteps.last?.name }
    public var redoName: String? { redoSteps.last?.name }

    /// A new action ends the redo history.
    public mutating func record(_ step: UndoStep) {
        guard !step.changes.isEmpty else { return }
        undoSteps.append(step)
        if undoSteps.count > Self.limit { undoSteps.removeFirst(undoSteps.count - Self.limit) }
        redoSteps.removeAll()
    }

    /// Takes the step to undo; it becomes the next redo.
    public mutating func popUndo() -> UndoStep? {
        guard let step = undoSteps.popLast() else { return nil }
        redoSteps.append(step)
        return step
    }

    /// Takes the step to redo; it becomes the next undo.
    public mutating func popRedo() -> UndoStep? {
        guard let step = redoSteps.popLast() else { return nil }
        undoSteps.append(step)
        return step
    }

    public mutating func removeAll() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }
}

extension CullAction {
    /// The Edit menu name of this action when it changed `before` into `after`.
    public func undoName(from before: Decision, to after: Decision) -> String {
        switch self {
        case .setRating(0): "Clear Rating"
        case .setRating, .stepRating: "Set Rating"
        case .toggleLabel: after.label == nil ? "Clear Label" : "Set Label"
        case .toggleReject: after.isReject ? "Reject" : "Unreject"
        }
    }
}
