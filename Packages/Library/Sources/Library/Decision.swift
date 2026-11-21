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

/// Valid star ratings (1 to 5).
public enum StarCount: Int, Sendable, Hashable, Comparable, CaseIterable {
    case one = 1, two, three, four, five

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A photo's rating state: rejected, unrated, or 1–5 stars. Out-of-range ratings are unrepresentable.
public enum Rating: Sendable, Hashable {
    case rejected
    case unrated
    case rated(StarCount)

    public var rawValue: Int {
        switch self {
        case .rejected: -1
        case .unrated: 0
        case .rated(let stars): stars.rawValue
        }
    }

    public init(clamping value: Int) {
        if value < 0 {
            self = .rejected
        } else if let stars = StarCount(rawValue: min(value, 5)) {
            self = .rated(stars)
        } else {
            self = .unrated
        }
    }
}

/// What the photographer decided about one photo: a rating (rejected, unrated, or 1–5 stars) and a label.
public struct Decision: Sendable, Hashable {
    public static let none = Decision()

    public private(set) var ratingKind: Rating
    public var label: ColorLabel?

    public var rating: Int { ratingKind.rawValue }

    public init(rating: Rating, label: ColorLabel? = nil) {
        self.ratingKind = rating
        self.label = label
    }

    public init(rating: Int = 0, label: ColorLabel? = nil) {
        self.ratingKind = Rating(clamping: rating)
        self.label = label
    }

    public var isReject: Bool { ratingKind == .rejected }
    public var stars: Int {
        switch ratingKind {
        case .rated(let stars): stars.rawValue
        case .rejected, .unrated: 0
        }
    }
    public var isUndecided: Bool { self == .none }

    /// The state as one phrase for VoiceOver and the badge: "3 stars, red label", "Rejected", "No rating".
    public var summary: String {
        var parts: [String] = []
        switch ratingKind {
        case .rejected: parts.append("Rejected")
        case .unrated: if label == nil { parts.append("No rating") }
        case .rated(.one): parts.append("1 star")
        case .rated(let stars): parts.append("\(stars.rawValue) stars")
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
            d = Decision(rating: Rating(clamping: max(n, 0)), label: decision.label)
        case .stepRating(let delta):
            switch decision.ratingKind {
            case .rejected:
                if delta > 0 { d = Decision(rating: .rated(.one), label: decision.label) }
            case .unrated, .rated:
                d = Decision(rating: Rating(clamping: max(decision.stars + delta, 0)), label: decision.label)
            }
        case .toggleLabel(let label):
            d.label = decision.label == label ? nil : label
        case .toggleReject:
            d = Decision(rating: decision.isReject ? .unrated : .rejected, label: decision.label)
        }
        return d
    }
}
