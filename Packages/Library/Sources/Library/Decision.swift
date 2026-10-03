import Foundation

/// A color label. Purple is menu-only (no default key).
public enum ColorLabel: String, Sendable, CaseIterable, Codable {
    case red, yellow, green, blue, purple

    public var name: String { rawValue.capitalized }

    /// One letter, so a label never relies on color alone.
    public var letter: Character {
        switch self {
        case .red: "R"
        case .yellow: "Y"
        case .green: "G"
        case .blue: "B"
        case .purple: "P"
        }
    }
}

/// What the photographer decided about one photo: a rating (-1 is reject, 0 to 5 are stars) and a label.
public struct Decision: Sendable, Hashable {
    public static let none = Decision()

    public private(set) var rating: Int
    public var label: ColorLabel?

    public init(rating: Int = 0, label: ColorLabel? = nil) {
        self.rating = min(max(rating, -1), 5)
        self.label = label
    }

    public var isReject: Bool { rating < 0 }
    public var stars: Int { max(rating, 0) }
    public var isUndecided: Bool { self == .none }

    /// The state as one phrase for VoiceOver and the badge: "3 stars, red label", "Rejected", "No rating".
    public var summary: String {
        var parts: [String] = []
        switch rating {
        case -1: parts.append("Rejected")
        case 0: if label == nil { parts.append("No rating") }
        case 1: parts.append("1 star")
        default: parts.append("\(rating) stars")
        }
        if let label { parts.append("\(label.name.lowercased()) label") }
        return parts.joined(separator: ", ")
    }
}

/// One cull key's effect. Pure, so the open questions of M-06 are decided and tested in one place.
public enum CullAction: Sendable, Hashable {
    /// `1`–`5` set stars, `0` clears them. Setting the current count again changes nothing (Q3). On a reject it un-rejects.
    case setRating(Int)
    /// `[` (-1) and `]` (+1), within 0 to 5. `]` on a reject gives 1 star, `[` on a reject does nothing (Q4).
    case stepRating(Int)
    /// A label key sets the label, or clears it when it is already the label (Q2).
    case toggleLabel(ColorLabel)
    /// `X` rejects; on a reject it goes back to 0, not to the old stars (Q1).
    case toggleReject

    public func applied(to decision: Decision) -> Decision {
        var d = decision
        switch self {
        case .setRating(let n):
            d = Decision(rating: min(max(n, 0), 5), label: decision.label)
        case .stepRating(let delta):
            if decision.isReject {
                if delta > 0 { d = Decision(rating: 1, label: decision.label) }
            } else {
                d = Decision(rating: min(max(decision.rating + delta, 0), 5), label: decision.label)
            }
        case .toggleLabel(let label):
            d.label = decision.label == label ? nil : label
        case .toggleReject:
            d = Decision(rating: decision.isReject ? 0 : -1, label: decision.label)
        }
        return d
    }
}
