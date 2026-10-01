/// Which neighbors of the current frame to load ahead of time (M-04 open question 3): a few on each side,
/// weighted toward the direction of travel, and wider when reads are slow.
public struct PrefetchPlan: Sendable, Equatable {
    public enum Direction: Sendable { case forward, backward }

    public var ahead = 4
    public var behind = 2
    /// Factor applied to both sides when reads are slow (SD cards, network shares).
    public var slowWidening = 2

    public init() {}

    /// Indices to prefetch, most useful first: the nearest ahead and the nearest behind interleaved, so the
    /// next frame in the direction of travel is always first.
    public func indices(current: Int, count: Int, direction: Direction, slow: Bool) -> [Int] {
        guard count > 0, (0..<count).contains(current) else { return [] }
        let factor = slow ? slowWidening : 1
        let step = direction == .forward ? 1 : -1
        let forward = (1...max(ahead * factor, 1)).map { current + step * $0 }
        let backward = (1...max(behind * factor, 1)).map { current - step * $0 }
        var result: [Int] = []
        var f = forward.makeIterator(), b = backward.makeIterator()
        var nextB = b.next()
        var nextF = f.next()
        var emitted = 0
        // Two ahead for each one behind, so travel direction dominates.
        while nextF != nil || nextB != nil {
            if let i = nextF, emitted % 3 != 2 || nextB == nil { result.append(i); nextF = f.next() }
            else if let i = nextB { result.append(i); nextB = b.next() }
            emitted += 1
        }
        return result.filter { (0..<count).contains($0) }
    }
}
