import Foundation

/// A rule for "select by rating, label or reject" (⌥⌘A). Both parts must match; `nil` means any.
public struct SelectionCriteria: Sendable, Hashable {
    public enum Rating: Sendable, Hashable {
        case atLeast(Int)
        case unrated
        case rejected
    }

    public enum Label: Sendable, Hashable {
        case unlabeled
        case color(ColorLabel)
    }

    public var rating: Rating?
    public var label: Label?

    public init(rating: Rating? = nil, label: Label? = nil) {
        self.rating = rating
        self.label = label
    }

    public var isEmpty: Bool { rating == nil && label == nil }

    public func matches(_ decision: Decision) -> Bool {
        switch rating {
        case nil: break
        case .atLeast(let n): if decision.stars < n || decision.isReject { return false }
        case .unrated: if decision.rating != 0 { return false }
        case .rejected: if !decision.isReject { return false }
        }
        switch label {
        case nil: break
        case .unlabeled: if decision.label != nil { return false }
        case .color(let color): if decision.label != color { return false }
        }
        return true
    }

    /// "3 stars or more, red label", for the status line and VoiceOver.
    public var summary: String {
        var parts: [String] = []
        switch rating {
        case nil: break
        case .atLeast(let n): parts.append(n == 1 ? "1 star or more" : "\(n) stars or more")
        case .unrated: parts.append("unrated")
        case .rejected: parts.append("rejected")
        }
        switch label {
        case nil: break
        case .unlabeled: parts.append("no label")
        case .color(let color): parts.append("\(color.name.lowercased()) label")
        }
        return parts.isEmpty ? "all photos" : parts.joined(separator: ", ")
    }
}

/// Which photos are selected, apart from the active one (M-19). Photos are named by URL so a re-sort cannot
/// change what is selected. The order of `photos` passed to each operation is the order on screen.
public struct Selection: Sendable, Equatable {
    public private(set) var urls: Set<URL> = []
    /// Where a `⇧` range starts: the last photo that was clicked or toggled on.
    public private(set) var anchor: URL?

    public init() {}

    public var count: Int { urls.count }
    public var isEmpty: Bool { urls.isEmpty }
    public func contains(_ url: URL) -> Bool { urls.contains(url) }

    public mutating func removeAll() {
        urls = []
        anchor = nil
    }

    public mutating func selectAll(_ photos: [Photo]) { urls = Set(photos.map(\.url)) }

    public mutating func deselect(_ url: URL) { urls.remove(url) }

    public mutating func invert(_ photos: [Photo]) {
        urls = Set(photos.map(\.url)).subtracting(urls)
    }

    public mutating func select(matching criteria: SelectionCriteria, in photos: [Photo]) {
        urls = Set(photos.filter { criteria.matches($0.decision) }.map(\.url))
    }

    /// `⌘`-click: flips one photo and makes it the anchor.
    public mutating func toggle(_ url: URL) {
        if !urls.insert(url).inserted { urls.remove(url) }
        anchor = url
    }

    /// Plain click: only this photo is selected.
    public mutating func select(only url: URL) {
        urls = [url]
        anchor = url
    }

    /// `⇧`-click, or `⇧`-arrow: everything from the anchor to `url` is selected (and what was selected stays
    /// when `additive`). Without an anchor the range starts at `from`, the active photo.
    public mutating func extend(to url: URL, from active: URL?, in photos: [Photo], additive: Bool = false) {
        guard let end = photos.firstIndex(where: { $0.url == url }) else { return }
        let start = (anchor ?? active).flatMap { a in photos.firstIndex { $0.url == a } } ?? end
        if anchor == nil { anchor = photos[start].url }
        let range = photos[min(start, end)...max(start, end)].map(\.url)
        urls = additive ? urls.union(range) : Set(range)
    }

    /// Drops what is no longer in the list (a folder reopened, a file deleted, a filter that hides it).
    public mutating func retain(_ photos: [Photo]) {
        guard !urls.isEmpty || anchor != nil else { return }
        let present = Set(photos.map(\.url))
        urls.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }
}
