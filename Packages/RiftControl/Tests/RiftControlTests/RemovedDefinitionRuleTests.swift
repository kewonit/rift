import Foundation
import RiftControl
import RiftCore
import Testing

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func assignedRule(groupID: UUID? = nil, profileID: UUID? = nil) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(.allow), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, profileID: profileID,
        localGroupID: groupID, createdAt: now, modifiedAt: now
    )
}

@Test func rulesKeptFromATurnedOffGroupStayOff() throws {
    let rule = try assignedRule(groupID: UUID())
    let kept = try RuleMutation.removingGroup(rule, groupWasOn: false, now: now)
    #expect(kept.localGroupID == nil)
    #expect(!kept.isEnabled)
    #expect(try RuleMutation.removingGroup(rule, groupWasOn: true, now: now).isEnabled)
}

@Test func rulesKeptFromAnInactiveProfileStayOff() throws {
    let rule = try assignedRule(profileID: UUID())
    let kept = try RuleMutation.removingProfile(rule, profileWasActive: false, now: now)
    #expect(kept.profileID == nil)
    #expect(!kept.isEnabled)
    #expect(try RuleMutation.removingProfile(rule, profileWasActive: true, now: now).isEnabled)
}
