/// A cache bounded by the total cost (bytes) of what it holds, evicting the least recently used first.
/// A value type: wrap it in an actor or a lock. Lookups and inserts are O(1); an eviction scans the entries,
/// which is fine for the few hundred frames a 2 GB budget holds.
public struct ByteBudgetCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var tick: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    public private(set) var totalCost = 0
    public var budget: Int { didSet { evict(toFit: budget) } }

    public init(budget: Int) { self.budget = budget }

    public var count: Int { entries.count }

    /// The value for `key`, marked as most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.tick = clock
        entries[key] = entry
        return entry.value
    }

    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// Stores `value`. An entry costlier than the whole budget is not kept.
    public mutating func insert(_ value: Value, cost: Int, for key: Key) {
        remove(key)
        guard cost <= budget else { return }
        clock += 1
        entries[key] = Entry(value: value, cost: cost, tick: clock)
        totalCost += cost
        evict(toFit: budget)
    }

    public mutating func remove(_ key: Key) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    /// Keeps only the entries in `keys`.
    public mutating func retain(_ keys: Set<Key>) {
        for key in Array(entries.keys) where !keys.contains(key) { remove(key) }
    }

    private mutating func evict(toFit limit: Int) {
        while totalCost > limit, let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key {
            remove(oldest)
        }
    }
}
