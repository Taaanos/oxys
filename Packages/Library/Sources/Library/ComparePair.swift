import Foundation

/// The two photos of Compare (V-08) and which of them is active. Pure value logic over the visible list, so the
/// rules (who steps where, what `↑` does) are tested without a window.
///
/// The left side is the *select* (the keeper), the right side the *candidate*. Each side remembers the index it
/// had in the last list it saw, so a photo the filter hides (a reject, with rejects hidden) leaves a side on its
/// nearest neighbor instead of on nothing.
public struct ComparePair: Equatable, Sendable {
    public enum Side: Sendable, Equatable {
        case select, candidate
        public var other: Side { self == .select ? .candidate : .select }
        public var title: String { self == .select ? "Select" : "Candidate" }
    }

    public private(set) var select: URL
    public private(set) var candidate: URL
    public private(set) var active: Side
    private var selectHint: Int
    private var candidateHint: Int

    public func url(of side: Side) -> URL { side == .select ? select : candidate }
    public var activeURL: URL { url(of: active) }

    /// The pair that `C` opens, or nil when the list has fewer than two photos.
    /// - Two photos selected: those two, in screen order.
    /// - Otherwise: `current` and the next photo (the previous one when `current` is the last).
    public static func start(selected: [URL], current: URL?, in urls: [URL]) -> ComparePair? {
        guard urls.count >= 2 else { return nil }
        let inList = selected.filter { urls.contains($0) }
        if inList.count == 2, let a = urls.firstIndex(of: inList[0]), let b = urls.firstIndex(of: inList[1]) {
            let (first, second) = a < b ? (a, b) : (b, a)
            // The active photo, when it is one of the two, is the active side.
            let activeSide: Side = current == urls[second] ? .candidate : .select
            return ComparePair(select: urls[first], candidate: urls[second], active: activeSide, selectHint: first, candidateHint: second)
        }
        let at = current.flatMap { urls.firstIndex(of: $0) } ?? 0
        let other = at + 1 < urls.count ? at + 1 : at - 1
        return ComparePair(select: urls[at], candidate: urls[other], active: .select, selectHint: at, candidateHint: other)
    }

    /// Fixes a side whose photo is no longer in `urls`: it takes the photo now at its old place, so it is never
    /// the same as the other side. Nil when the list cannot hold two photos any more.
    public func reconciled(in urls: [URL]) -> ComparePair? {
        guard urls.count >= 2 else { return nil }
        var pair = self
        if !urls.contains(select) {
            pair.selectHint = min(selectHint, urls.count - 1)
            pair.select = urls[pair.selectHint]
        }
        if !urls.contains(candidate) {
            pair.candidateHint = min(candidateHint, urls.count - 1)
            pair.candidate = urls[pair.candidateHint]
        }
        if pair.select == pair.candidate {
            // Both fell on one photo: the candidate takes its neighbor.
            let at = urls.firstIndex(of: pair.candidate) ?? 0
            pair.candidateHint = at + 1 < urls.count ? at + 1 : at - 1
            pair.candidate = urls[pair.candidateHint]
        }
        pair.selectHint = urls.firstIndex(of: pair.select) ?? pair.selectHint
        pair.candidateHint = urls.firstIndex(of: pair.candidate) ?? pair.candidateHint
        return pair
    }

    /// A click on a pane.
    public mutating func activate(_ side: Side) { active = side }

    /// `⇥`.
    public mutating func switchSide() { active = active.other }

    /// `↓`: the two photos change places. The ring stays on the same side, so it now rings the other photo.
    public mutating func swap() {
        Swift.swap(&select, &candidate)
        Swift.swap(&selectHint, &candidateHint)
    }

    /// `←` `→` `Home` `End`: the active side moves. It skips the photo on the other side (V-08/Q3) and stops at
    /// either end. Returns whether it moved.
    @discardableResult
    public mutating func step(_ step: FolderModel.Step, in urls: [URL]) -> Bool {
        guard let from = urls.firstIndex(of: activeURL), let target = Self.target(step, from: from, avoiding: url(of: active.other), in: urls),
              target != from else { return false }
        set(active, to: target, in: urls)
        return true
    }

    /// The photo the active side would show after `step`, or nil at the end of the list. Used before a reject, so
    /// the destination is chosen from the list as it is now.
    public func destination(_ step: FolderModel.Step, in urls: [URL]) -> URL? {
        guard let from = urls.firstIndex(of: activeURL),
              let target = Self.target(step, from: from, avoiding: url(of: active.other), in: urls), target != from else { return nil }
        return urls[target]
    }

    /// `↑`: the candidate becomes the select and the next photo after it becomes the candidate (V-08/Q1). The active
    /// side stays. Returns whether there was a next photo.
    @discardableResult
    public mutating func advance(in urls: [URL]) -> Bool {
        guard let at = urls.firstIndex(of: candidate), at + 1 < urls.count else { return false }
        select = candidate
        selectHint = at
        candidate = urls[at + 1]
        candidateHint = at + 1
        return true
    }

    /// Puts `url` on the active side. Ignored when it is on the other side or not in the list.
    @discardableResult
    public mutating func show(_ url: URL, in urls: [URL]) -> Bool {
        guard url != self.url(of: active.other), let at = urls.firstIndex(of: url), url != activeURL else { return false }
        set(active, to: at, in: urls)
        return true
    }

    private mutating func set(_ side: Side, to index: Int, in urls: [URL]) {
        switch side {
        case .select: select = urls[index]; selectHint = index
        case .candidate: candidate = urls[index]; candidateHint = index
        }
    }

    private static func target(_ step: FolderModel.Step, from: Int, avoiding blocked: URL, in urls: [URL]) -> Int? {
        let blockedIndex = urls.firstIndex(of: blocked)
        func free(_ i: Int) -> Bool { i != blockedIndex }
        switch step {
        case .next:
            var i = from + 1
            if i == blockedIndex { i += 1 }
            return i < urls.count ? i : nil
        case .previous:
            var i = from - 1
            if i == blockedIndex { i -= 1 }
            return i >= 0 ? i : nil
        case .first:
            return urls.indices.first(where: free)
        case .last:
            return urls.indices.last(where: free)
        }
    }
}
