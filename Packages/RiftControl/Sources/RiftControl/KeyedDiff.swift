/// The difference between two keyed collections: which keys to insert, which
/// to remove, and which are unchanged. The Live Map uses it to update only the
/// routes whose geometry changed instead of rebuilding every overlay.
public struct KeyedDiff<Key: Hashable, Value: Equatable> {
    public let inserted: [Key]
    public let removed: [Key]
    /// Keys present in both collections whose value changed.
    public let changed: [Key]
    public let unchanged: [Key]

    public init(old: [Key: Value], new: [Key: Value]) {
        var inserted: [Key] = []
        var changed: [Key] = []
        var unchanged: [Key] = []
        for (key, value) in new {
            switch old[key] {
            case nil: inserted.append(key)
            case let previous? where previous == value: unchanged.append(key)
            case _?: changed.append(key)
            }
        }
        self.inserted = inserted
        self.removed = old.keys.filter { new[$0] == nil }
        self.changed = changed
        self.unchanged = unchanged
    }

    public var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && changed.isEmpty }
}
