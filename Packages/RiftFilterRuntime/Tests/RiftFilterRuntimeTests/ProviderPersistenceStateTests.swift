import RiftCore
import Darwin
import Foundation
import Testing
@testable import RiftFilterRuntime

@Test func providerStartKeepsMissingReadOnlyAndInvalidRootsDegraded() throws {
    let missing = RuntimePersistenceBootstrap(rootURL: nil)
    expectDegradedProviderStart(missing)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let invalidRoot = directory.appendingPathComponent("not-a-directory")
    try Data("invalid root".utf8).write(to: invalidRoot)
    expectDegradedProviderStart(RuntimePersistenceBootstrap(rootURL: invalidRoot))

    let readOnlyParent = directory.appendingPathComponent("read-only", isDirectory: true)
    try FileManager.default.createDirectory(at: readOnlyParent, withIntermediateDirectories: true)
    guard chmod(readOnlyParent.path, mode_t(0o500)) == 0 else {
        Issue.record("Could not make the isolated fixture directory read-only")
        return
    }
    defer { _ = chmod(readOnlyParent.path, mode_t(0o700)) }
    let readOnlyRoot = readOnlyParent.appendingPathComponent("state", isDirectory: true)
    expectDegradedProviderStart(RuntimePersistenceBootstrap(rootURL: readOnlyRoot))
}

@Test func corruptTombstonesStayUnavailableAcrossStartAndExpiry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let tombstones = try ExpiryTombstoneStore(rootURL: root)
    try Data("not tombstone json".utf8).write(
        to: root.appendingPathComponent("expiry-tombstones.json")
    )

    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    do {
        _ = state.tombstonesLoaded(try await tombstones.load())
        Issue.record("Corrupt tombstones unexpectedly loaded")
    } catch {
        _ = state.tombstonePersistenceFailed()
    }
    #expect(state.completeProviderStart(settingsSucceeded: true, hasActivePolicy: true)
        == .degradedPersistence)
    #expect(state.expiryMetadata == .unavailable)

    do {
        _ = state.tombstonesPersisted(try await tombstones.record([expiryKey()]))
        Issue.record("Corrupt tombstones were unexpectedly overwritten")
    } catch {
        _ = state.tombstonePersistenceFailed()
    }
    #expect(state.readiness == .degradedPersistence)
    #expect(state.expiryMetadata == .unavailable)
}

@Test func failedTombstoneWriteCannotMakeExpiryMetadataAvailable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        _ = chmod(root.path, mode_t(0o700))
        try? FileManager.default.removeItem(at: root)
    }
    let tombstones = try ExpiryTombstoneStore(rootURL: root)
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    _ = state.tombstonesLoaded(try await tombstones.load())
    #expect(state.completeProviderStart(settingsSucceeded: true, hasActivePolicy: true) == .ready)

    guard chmod(root.path, mode_t(0o500)) == 0 else {
        Issue.record("Could not make the isolated tombstone directory read-only")
        return
    }
    let key = expiryKey()
    do {
        _ = state.tombstonesPersisted(try await tombstones.record([key]))
        Issue.record("A tombstone write unexpectedly succeeded in the read-only fixture")
    } catch {
        _ = state.tombstonePersistenceFailed()
    }
    #expect(state.readiness == .degradedPersistence)
    #expect(state.expiryMetadata == .unavailable)

    #expect(chmod(root.path, mode_t(0o700)) == 0)
    _ = state.tombstonesPersisted(try await tombstones.record([key]))
    #expect(state.readiness == .ready)
    #expect(state.expiryMetadata == .available(alreadyExpired: [key]))
}

private func expectDegradedProviderStart(
    _ bootstrap: RuntimePersistenceBootstrap
) {
    #expect(bootstrap.health == .degradedPersistence)
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: bootstrap.rootStore != nil,
        tombstonePersistenceAvailable: bootstrap.tombstoneStore != nil
    )
    #expect(state.readiness == .degradedPersistence)
    #expect(state.completeProviderStart(settingsSucceeded: true, hasActivePolicy: false)
        == .degradedPersistence)
    #expect(state.expiryMetadata == .unavailable)
}

private func expiryKey() -> ExpiredRuleKey {
    ExpiredRuleKey(
        lineageID: UUID(),
        ruleID: UUID(),
        revision: 1,
        expiresAt: Date(timeIntervalSince1970: 100)
    )
}
