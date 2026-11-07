import RiftControl
import Testing

@Test func keyedDiffSeparatesInsertedRemovedChangedAndUnchanged() {
    let diff = KeyedDiff(
        old: ["JP": 1, "DE": 2, "US": 3],
        new: ["JP": 1, "DE": 5, "GB": 4]
    )
    #expect(Set(diff.inserted) == ["GB"])
    #expect(Set(diff.removed) == ["US"])
    #expect(Set(diff.changed) == ["DE"])
    #expect(Set(diff.unchanged) == ["JP"])
    #expect(!diff.isEmpty)
}

@Test func keyedDiffIsEmptyWhenNothingChanged() {
    let values = ["JP": [1, 2], "DE": [3]]
    let diff = KeyedDiff(old: values, new: values)
    #expect(diff.isEmpty)
    #expect(Set(diff.unchanged) == ["JP", "DE"])
}

@Test func keyedDiffHandlesEmptyCollections() {
    let fromEmpty = KeyedDiff<String, Int>(old: [:], new: ["FR": 1])
    #expect(fromEmpty.inserted == ["FR"])
    let toEmpty = KeyedDiff<String, Int>(old: ["FR": 1], new: [:])
    #expect(toEmpty.removed == ["FR"])
    #expect(KeyedDiff<String, Int>(old: [:], new: [:]).isEmpty)
}
