import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private let now = Date(timeIntervalSince1970: 1_000)

private func connection(
    app: String = "com.example.browser",
    host: String = "api.example.test",
    address: String = "203.0.113.10",
    port: UInt16 = 443,
    classes: Set<EndpointClass> = []
) throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: app)
    )
    let name = try DomainName(host)
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: now, sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress(address), port: port, hostname: name, hostnameCoverage: .observed,
            classes: classes, interfaceSnapshotGeneration: 0
        ),
        observedHostname: name,
        metadataConfidence: [.appIdentity, .endpoint, .observedHostname, .owner]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: now, flow: flow,
            action: .allow, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
}

private func tree(_ rows: [MonitorEventRow], names: [ProcessIdentity: String] = [:]) -> [MonitorHierarchyNode] {
    MonitorHierarchyBuilder.build(
        MonitorQuery.filter(rows, search: "", lens: .application),
        lens: .application, coverages: [:], displayNames: names
    )
}

@Test func aPickedGroupStaysSelectedEvenWhenAnEventIsRemembered() throws {
    let rows = [try connection(host: "a.example.test"), try connection(host: "b.example.test")]
    let nodes = tree(rows)
    let group = try #require(nodes.first)
    let resolved = MonitorSelectionResolver.resolve(selectionID: group.id, eventID: rows[0].id, in: nodes)
    #expect(resolved == group.id)
}

@Test func aConnectionStandsInOnceItsRowIsGone() throws {
    let rows = [try connection()]
    let nodes = tree(rows)
    let leaf = MonitorHierarchyBuilder.node(forEventID: rows[0].id, in: nodes)
    let resolved = MonitorSelectionResolver.resolve(selectionID: "missing", eventID: rows[0].id, in: nodes)
    #expect(resolved == leaf?.id)
    #expect(MonitorSelectionResolver.resolve(selectionID: "missing", eventID: "gone", in: nodes) == nil)
}

@Test func theGroupsAroundAConnectionCanBeFound() throws {
    let rows = [try connection()]
    let nodes = tree(rows)
    let ancestors = MonitorSelectionResolver.ancestors(ofEventID: rows[0].id, in: nodes)
    #expect(ancestors.first == nodes.first?.id)
    #expect(!ancestors.isEmpty)
    #expect(MonitorSelectionResolver.ancestors(ofEventID: "gone", in: nodes).isEmpty)
}

@Test func anAppOpensStraightToItsDestinations() throws {
    let nodes = tree([try connection()])
    #expect(nodes.first?.kind == .application)
    #expect(nodes.first?.children?.first?.kind == .hostname)
}

@Test func localConnectionsSayWhereTheyAre() throws {
    let nodes = tree([try connection(classes: [.localNetwork])])
    #expect(nodes.first?.children?.first?.subtitle == DisplaySanitizer.plainText("Local network"))
}

@Test func theListUsesAppNamesWhenTheyreKnown() throws {
    let row = try connection()
    let identity = try #require(row.event.flow.sourceAppIdentity)
    let nodes = tree([row], names: [identity: "Browser"])
    #expect(nodes.first?.title == DisplaySanitizer.plainText("Browser"))
}

@Test func searchFindsTheNameOnScreen() throws {
    let row = try connection()
    let identity = try #require(row.event.flow.sourceAppIdentity)
    let context = MonitorSearchContext(displayNames: [identity: "Browser"])
    var state = MonitorQueryState(time: .all)
    state.search = "browser name"
    #expect(state.apply(to: [row], now: now, context: .none).isEmpty)
    state.search = "Browser"
    #expect(state.apply(to: [row], now: now, context: context).count == 1)
}

@Test func searchFindsTheCountryOnScreen() throws {
    let row = try connection()
    let context = MonitorSearchContext(countryCode: { _ in "JP" }, countryName: { _ in "Japan" })
    var state = MonitorQueryState(time: .all)
    state.search = "japan"
    #expect(state.apply(to: [row], now: now, context: context).count == 1)
    #expect(state.apply(to: [row], now: now, context: .none).isEmpty)
}

@Test func aCountryFilterKeepsOnlyThatCountry() throws {
    let japan = try connection(address: "203.0.113.10")
    let germany = try connection(address: "203.0.113.20")
    let context = MonitorSearchContext(countryCode: { address in
        address.description == "203.0.113.10" ? "JP" : "DE"
    })
    var state = MonitorQueryState(time: .all)
    state.country = "JP"
    let rows = state.apply(to: [japan, germany], now: now, context: context)
    #expect(rows.map(\.id) == [japan.id])
}

@Test func clearingFiltersAlsoClearsTheCountry() {
    var state = MonitorQueryState(time: .all)
    state.country = "JP"
    state.clearExcludingFilters()
    #expect(state.country == nil)
}

@Test func calendarRangesNeverClaimToBeRolling() {
    #expect(MonitorTimeFilter.day.liveLabel == "Today")
    #expect(MonitorTimeFilter.hour.liveLabel == "This hour")
    #expect(MonitorTimeFilter.tenMinutes.liveLabel == "Last 10 minutes")
    #expect(MonitorTimeFilter.all.liveLabel == "All saved activity")
}

@Test func theQueryKnowsWhenItIsShowingThePast() {
    var state = MonitorQueryState(time: .hour)
    #expect(!state.isViewingPast)
    state.timeAnchor = now
    #expect(state.isViewingPast)
    state.timeAnchor = nil
    state.selectedTimeRange = now...now.addingTimeInterval(60)
    #expect(state.isViewingPast)
}

@Test func theDecisionChartFollowsFiltersButNotADraggedSelection() throws {
    let blocked = try connection(host: "a.example.test")
    let other = try connection(host: "b.example.test")
    var state = MonitorQueryState(time: .all)
    state.search = "a.example.test"
    let filtered = state.apply(to: [blocked, other], now: now).map(\.source)
    #expect(MonitorDecisionBuckets.rows(
        displayed: filtered, all: [blocked, other], query: state, now: now
    ).map(\.id) == [blocked.id])
    state.selectedTimeRange = now.addingTimeInterval(-10)...now.addingTimeInterval(-5)
    let dragged = state.apply(to: [blocked, other], now: now).map(\.source)
    #expect(dragged.isEmpty)
    #expect(MonitorDecisionBuckets.rows(
        displayed: dragged, all: [blocked, other], query: state, now: now
    ).map(\.id) == [blocked.id])
}
