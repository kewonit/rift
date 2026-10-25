import RiftCore
import Foundation
import Testing
@testable import RiftFilterRuntime

@Test func expiryTombstonesSurviveRestartAndPruneOnlyUnreferencedKeys() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ExpiryTombstoneStore(rootURL: root)
    let key = ExpiredRuleKey(
        lineageID: UUID(),
        ruleID: UUID(),
        revision: 2,
        expiresAt: Date(timeIntervalSince1970: 100)
    )
    _ = try await first.record([key])
    let restarted = try ExpiryTombstoneStore(rootURL: root)
    #expect(try await restarted.load() == [key])
    #expect(try await restarted.prune(retaining: []) == [])
    _ = try await restarted.record([key])
    try await restarted.erase()
    #expect(try await restarted.load().isEmpty)
}

@Test func pendingCohortPausesEachFlowOnceAndResolvesOnce() async throws {
    let coordinator = PendingFlowCoordinator()
    let key = PendingFlowKey(
        lineageID: UUID(), generation: 1, owner: .user(uid: 501),
        appIdentity: nil, direction: .outgoing, endpoint: nil, transportProtocol: .udp
    )
    let firstID = UUID()
    let secondID = UUID()
    let deadline = Date(timeIntervalSince1970: 10)
    let first = try await coordinator.register(
        flowID: firstID, key: key, initialState: .resolvingIdentity, deadline: deadline
    )
    let second = try await coordinator.register(
        flowID: secondID, key: key, initialState: .resolvingIdentity, deadline: deadline
    )
    #expect(first.isNewCohort)
    #expect(!second.isNewCohort)
    #expect(first.cohortID == second.cohortID)
    _ = try await coordinator.transitionToAwaitingUser(cohortID: first.cohortID)
    #expect(Set(try await coordinator.resolve(cohortID: first.cohortID)) == [firstID, secondID])
    await #expect(throws: PendingFlowCoordinatorError.missingCohort) {
        _ = try await coordinator.resolve(cohortID: first.cohortID)
    }
}
