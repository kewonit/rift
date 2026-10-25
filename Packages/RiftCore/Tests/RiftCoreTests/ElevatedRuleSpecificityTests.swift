import Foundation
import Testing
@testable import RiftCore

@Test func elevatedAllowAcceptsVerifiedExactProcessAndHostnameSet() throws {
    let destination = try DestinationCondition.normalizedExactHostnameSet([
        DomainName("api.example.com"),
        DomainName("updates.example.com"),
    ])
    let rule = try RuleTestSupport.rule(
        id: 4_020,
        action: .filter(.allow),
        priority: .elevatedUser,
        process: .exact(RuleTestSupport.appIdentity),
        destination: destination
    )
    #expect(rule.priority == .elevatedUser)
}

@Test func elevatedAllowAcceptsVerifiedAppHelperAndIPSet() throws {
    let destination = try DestinationCondition.normalizedIPSet([
        IPInterval(exact: IPAddress("203.0.113.9")),
    ])
    let rule = try RuleTestSupport.rule(
        id: 4_021,
        action: .filter(.allow),
        priority: .elevatedUser,
        process: .appViaHelper(
            app: RuleTestSupport.appIdentity,
            helper: RuleTestSupport.helperIdentity
        ),
        destination: destination
    )
    #expect(rule.process == .appViaHelper(
        app: RuleTestSupport.appIdentity,
        helper: RuleTestSupport.helperIdentity
    ))
}

@Test func elevatedAllowRejectsAnyProcess() throws {
    let destination = try DestinationCondition.normalizedExactHostnameSet([
        DomainName("api.example.com"),
    ])
    #expect(throws: RuleValidationError.elevatedPriorityRequiresExactProcess) {
        try RuleTestSupport.rule(
            id: 4_022,
            action: .filter(.allow),
            priority: .elevatedUser,
            process: .anyProcess,
            destination: destination
        )
    }
}

@Test func elevatedAllowRejectsEveryBroadDestinationKind() throws {
    let broadDestinations: [DestinationCondition] = [
        .anyEndpoint,
        .endpointClass(.localNetwork),
        try .normalizedDomainSet([DomainName("example.com")]),
    ]
    for (index, destination) in broadDestinations.enumerated() {
        #expect(throws: RuleValidationError.elevatedPriorityRequiresExactDestination) {
            try RuleTestSupport.rule(
                id: UInt64(4_023 + index),
                action: .filter(.allow),
                priority: .elevatedUser,
                process: .exact(RuleTestSupport.appIdentity),
                destination: destination
            )
        }
    }
}

@Test func storedLegacyBroadElevatedRuleCannotBeResaved() throws {
    let ordinary = try RuleTestSupport.rule(
        id: 4_030,
        action: .filter(.allow),
        process: .anyProcess,
        destination: .anyEndpoint
    )
    let encoded = try JSONEncoder().encode(ordinary)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["priority"] = RulePriority.elevatedUser.rawValue
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let legacy = try JSONDecoder().decode(Rule.self, from: legacyData)

    #expect(throws: RuleValidationError.elevatedPriorityRequiresExactProcess) {
        try legacy.validateStoredRepresentation()
    }
}
