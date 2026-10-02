import Foundation

/// How rejects are treated by the filter (M-20).
public enum RejectFilter: String, Sendable, CaseIterable {
    case showAll, hideRejected, onlyRejected

    public var title: String {
        switch self {
        case .showAll: "Show rejected"
        case .hideRejected: "Hide rejected"
        case .onlyRejected: "Only rejected"
        }
    }
}

public enum SortKey: String, Sendable, CaseIterable {
    case captureTime, filename

    public var title: String {
        switch self {
        case .captureTime: "Capture time"
        case .filename: "Filename"
        }
    }
}

/// What the filter and sort bar holds (M-20). `isOn` is ⌘L: turning it off keeps the settings.
public struct PhotoFilter: Sendable, Equatable {
    public var isOn = true
    /// 0 means no minimum. Rejects never pass a minimum above 0.
    public var minStars = 0
    /// 5 means no maximum. A maximum below 5 (like a minimum above 0) leaves rejects out.
    public var maxStars = 5
    /// Any of these labels; empty means any photo.
    public var labels: Set<ColorLabel> = []
    public var rejects: RejectFilter = .showAll
    /// Filename search (⌘F); a case- and diacritic-insensitive substring. ⌘L turns it off with the rest.
    public var search = ""
    public var sortKey: SortKey = .captureTime
    public var ascending = true

    public init() {}

    /// True when some filter setting would hide photos.
    public var hasCriteria: Bool {
        minStars > 0 || maxStars < 5 || !labels.isEmpty || rejects != .showAll || !trimmedSearch.isEmpty
    }

    /// True when the list is being narrowed right now.
    public var isNarrowing: Bool { isOn && hasCriteria }

    /// A click on star `n` in the bar: that many or more. With `extend` (⇧) and a minimum already set, the range
    /// runs between the minimum and `n`. A click on the only lit star clears the row.
    public mutating func clickStar(_ n: Int, extend: Bool) {
        if extend, minStars > 0 {
            let anchor = minStars
            minStars = min(anchor, n)
            maxStars = max(anchor, n)
        } else if minStars == n, maxStars == 5 {
            minStars = 0
        } else {
            minStars = n
            maxStars = 5
        }
    }

    public var isDefaultSort: Bool { sortKey == .captureTime && ascending }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }

    public func matches(_ photo: Photo) -> Bool {
        guard isNarrowing else { return true }
        let d = photo.decision
        if minStars > 0 || maxStars < 5, d.isReject || d.stars < minStars || d.stars > maxStars { return false }
        if !labels.isEmpty, !(d.label.map(labels.contains) ?? false) { return false }
        switch rejects {
        case .showAll: break
        case .hideRejected: if d.isReject { return false }
        case .onlyRejected: if !d.isReject { return false }
        }
        let query = trimmedSearch
        if !query.isEmpty, photo.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }

    /// `photos` is in capture-time order. Returns the photos to show, in display order. `keeping` stays in the
    /// list even when it no longer matches, so a decision never makes the current photo vanish (G-6).
    public func apply(to photos: [Photo], keeping: URL? = nil) -> [Photo] {
        var result = photos
        if isNarrowing { result = photos.filter { matches($0) || $0.url == keeping } }
        switch (sortKey, ascending) {
        case (.captureTime, true): break
        case (.captureTime, false): result.reverse()
        case (.filename, let up):
            result.sort {
                let order = $0.name.localizedStandardCompare($1.name)
                return up ? order == .orderedAscending : order == .orderedDescending
            }
        }
        return result
    }

    /// "≥3 stars, red or yellow, no rejects, “IMG”", for VoiceOver and the bar.
    public var summary: String {
        var parts: [String] = []
        if minStars > 0 || maxStars < 5 {
            if minStars == maxStars { parts.append(minStars == 1 ? "1 star" : "\(minStars) stars") }
            else if maxStars == 5 { parts.append("\(minStars) stars or more") }
            else if minStars == 0 { parts.append("\(maxStars) stars or fewer") }
            else { parts.append("\(minStars) to \(maxStars) stars") }
        }
        if !labels.isEmpty {
            parts.append(ColorLabel.allCases.filter(labels.contains).map { $0.name.lowercased() }.joined(separator: " or "))
        }
        switch rejects {
        case .showAll: break
        case .hideRejected: parts.append("no rejects")
        case .onlyRejected: parts.append("only rejects")
        }
        if !trimmedSearch.isEmpty { parts.append("name contains “\(trimmedSearch)”") }
        return parts.isEmpty ? "no filter" : parts.joined(separator: ", ")
    }
}
