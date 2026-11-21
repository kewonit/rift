import Foundation
@testable import RiftCore
import Testing

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func rule(
    _ action: FilterAction,
    _ destination: DestinationCondition,
    priority: RulePriority = .normal,
    port: PortRange? = nil
) throws -> Rule {
    let app = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "com.example.app")
    )
    return try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(action), priority: priority,
        process: priority == .elevatedUser ? .exact(app) : .anyProcess, destination: destination, transportProtocol: .tcp, port: port,
        direction: .outgoing, owner: .authorizedUser, createdAt: now, modifiedAt: now
    )
}

@Test func precedenceOrderPutsNarrowerDestinationsFirst() throws {
    let ip = try rule(.allow, .normalizedIPSet([IPInterval(exact: IPAddress("203.0.113.1"))]))
    let host = try rule(.allow, .normalizedExactHostnameSet([DomainName("example.com")]))
    let any = try rule(.deny, .anyEndpoint)
    let sorted = [any, host, ip].sorted(by: RuleOrdering.precedes)
    #expect(sorted.map(\.id) == [ip.id, host.id, any.id])
}

@Test func precedenceOrderRanksPriorityAboveEverythingElse() throws {
    let narrow = try rule(.deny, .normalizedExactHostnameSet([DomainName("example.com")]),
                          port: PortRange(443, 443))
    let elevated = try rule(.allow, .normalizedExactHostnameSet([DomainName("example.com")]),
                            priority: .elevatedUser)
    #expect(RuleOrdering.precedes(elevated, narrow))
    #expect(!RuleOrdering.precedes(narrow, elevated))
}
