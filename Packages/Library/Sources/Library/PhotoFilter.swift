import Foundation

/// How rejects are treated by the filter (M-20).
public enum RejectFilter: String, Sendable, CaseIterable, Codable {
    case showAll, hideRejected, onlyRejected

    public var title: String {
        switch self {
        case .showAll: "Show rejected"
        case .hideRejected: "Hide rejected"
        case .onlyRejected: "Only rejected"
        }
    }
}

public enum SortKey: String, Sendable, CaseIterable, Codable {
    case captureTime, filename

    public var title: String {
        switch self {
        case .captureTime: "Capture time"
        case .filename: "Filename"
        }
    }
}

/// What the filter and sort bar holds (M-20). `isOn` is ⌘L: turning it off keeps the settings.
public struct PhotoFilter: Sendable, Equatable, Codable {
    public var isOn = true
    /// Which star ratings pass (0 is "no stars", 1 to 5 the stars); empty means any. Rejects never pass a non-empty set.
    public var stars: Set<Int> = []
    /// Where a `⇧` range starts: the last star clicked.
    public private(set) var starAnchor: Int?
    /// Any of these labels; empty means any photo (unless `noLabel` is on).
    public var labels: Set<ColorLabel> = []
    /// Also pass photos without a label. Alone it shows only the unlabeled photos.
    public var noLabel = false
    public var rejects: RejectFilter = .showAll
    /// Filename search (⌘F); a case- and diacritic-insensitive substring. ⌘L turns it off with the rest.
    public var search = ""
    public var sortKey: SortKey = .captureTime
    public var ascending = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isOn, stars, starAnchor, labels, noLabel, rejects, search, sortKey, ascending
    }

    /// Sessions saved before `noLabel` existed have no key for it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decode(Bool.self, forKey: .isOn)
        stars = try c.decode(Set<Int>.self, forKey: .stars)
        starAnchor = try c.decodeIfPresent(Int.self, forKey: .starAnchor)
        labels = try c.decode(Set<ColorLabel>.self, forKey: .labels)
        noLabel = try c.decodeIfPresent(Bool.self, forKey: .noLabel) ?? false
        rejects = try c.decode(RejectFilter.self, forKey: .rejects)
        search = try c.decode(String.self, forKey: .search)
        sortKey = try c.decode(SortKey.self, forKey: .sortKey)
        ascending = try c.decode(Bool.self, forKey: .ascending)
    }

    /// True when some filter setting would hide photos.
    public var hasCriteria: Bool {
        !stars.isEmpty || !labels.isEmpty || noLabel || rejects != .showAll || !trimmedSearch.isEmpty
    }

    /// True when the list is being narrowed right now.
    public var isNarrowing: Bool { isOn && hasCriteria }

    /// A click on star `n` in the bar: exactly that many stars. `⌘` adds or removes it (1 star and 3 stars), `⇧` makes
    /// a range from the last star clicked, `⌥` is `n` or more. A click on the only lit star clears the row.
    public mutating func clickStar(_ n: Int, extend: Bool = false, toggle: Bool = false, orMore: Bool = false) {
        if n == 0, !toggle, !extend {
            stars = stars == [0] ? [] : [0]
        } else if toggle {
            if !stars.insert(n).inserted { stars.remove(n) }
        } else if extend, let anchor = starAnchor {
            stars = Set(min(anchor, n)...max(anchor, n))
            return
        } else if orMore, n > 0 {
            stars = Set(n...5)
        } else if stars == [n] {
            stars = []
        } else {
            stars = [n]
        }
        starAnchor = stars.isEmpty ? nil : n
    }

    /// `⌥⌘N`: `n` stars or more; 0 clears.
    public mutating func setMinimumStars(_ n: Int) {
        stars = n > 0 ? Set(n...5) : []
        starAnchor = n > 0 ? n : nil
    }

    private var starsSummary: String { Self.summary(of: stars) }

    private static func summary(of stars: Set<Int>) -> String {
        let sorted = stars.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        if sorted == [0] { return "no stars" }
        let contiguous = sorted.count == last - first + 1
        if first == 0 { return "no stars and " + summary(of: Set(sorted.dropFirst())) }
        if sorted.count == 1 { return first == 1 ? "1 star" : "\(first) stars" }
        if contiguous { return last == 5 ? "\(first) stars or more" : "\(first) to \(last) stars" }
        return sorted.dropLast().map(String.init).joined(separator: ", ") + " and \(last) stars"
    }

    public var isDefaultSort: Bool { sortKey == .captureTime && ascending }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }

    public func matches(_ photo: Photo) -> Bool {
        guard isNarrowing else { return true }
        let d = photo.decision
        if !stars.isEmpty, d.isReject || !stars.contains(d.stars) { return false }
        if !labels.isEmpty || noLabel {
            let passes = d.label.map(labels.contains) ?? noLabel
            if !passes { return false }
        }
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
        if !stars.isEmpty { parts.append(starsSummary) }
        if !labels.isEmpty || noLabel {
            let names = ColorLabel.allCases.filter(labels.contains).map { $0.name.lowercased() } + (noLabel ? ["no label"] : [])
            parts.append(names.joined(separator: " or "))
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
