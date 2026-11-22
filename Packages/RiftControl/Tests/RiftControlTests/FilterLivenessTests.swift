import Foundation
import RiftControl
import Testing

private let start = Date(timeIntervalSince1970: 1_000_000)

@Test func aQuietFilterIsSilentOnlyAfterTheThreshold() {
    let fourMinutes = start.addingTimeInterval(4 * 60)
    let sixMinutes = start.addingTimeInterval(6 * 60)
    #expect(!FilterLiveness.isSilent(now: fourMinutes, lastFlowAt: nil, listeningSince: start, networkUpSince: start))
    #expect(FilterLiveness.isSilent(now: sixMinutes, lastFlowAt: nil, listeningSince: start, networkUpSince: start))
    #expect(!FilterLiveness.isSilent(
        now: sixMinutes, lastFlowAt: start.addingTimeInterval(3 * 60), listeningSince: start, networkUpSince: start
    ))
}

@Test func noNetworkOrNotListeningIsNeverSilent() {
    let later = start.addingTimeInterval(60 * 60)
    #expect(!FilterLiveness.isSilent(now: later, lastFlowAt: nil, listeningSince: start, networkUpSince: nil))
    #expect(!FilterLiveness.isSilent(now: later, lastFlowAt: nil, listeningSince: nil, networkUpSince: start))
    // A network that just came back gets the full threshold.
    #expect(!FilterLiveness.isSilent(
        now: later, lastFlowAt: nil, listeningSince: start, networkUpSince: later.addingTimeInterval(-60)
    ))
}

@Test func aSilentFilterShowsInTheStatusButNotWhenFilteringIsOff() {
    let ready = ProtectionInputs(
        lifecycle: .enabled, controller: .connected(.ready), filterServiceConfirmed: true,
        hasActivePolicy: true, desiredKnown: true, rulesMatchDesired: true, mode: .alert, filterSilent: true
    )
    let status = ProtectionStatus.resolve(ready)
    #expect(status.state == .filterSilent)
    #expect(status.tone == .attention)
    #expect(status.showsBanner)
    var off = ready
    off.mode = .filterOff
    #expect(ProtectionStatus.resolve(off).state == .active(.filterOff))
}
