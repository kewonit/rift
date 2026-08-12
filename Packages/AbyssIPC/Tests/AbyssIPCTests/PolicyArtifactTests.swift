import AbyssCore
import CryptoKit
import Foundation
import Testing
@testable import AbyssIPC

@Test func compiledPolicyBytesAreCanonicalAndVerified() throws {
    let payload = try CompiledPolicyPayload(
        lineageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        generation: 7,
        authorizedUID: 501,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        operationMode: .alert,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    )
    let first = try PolicyArtifact.compile(payload)
    let second = try PolicyArtifact.compile(payload)

    #expect(first == second)
    #expect(try first.decode() == payload)
    #expect(first.hash.abyssHexString.count == 64)
}

@Test func artifactRejectsCorruption() throws {
    let payload = try CompiledPolicyPayload(
        lineageID: UUID(), generation: 1, authorizedUID: 501,
        createdAt: Date(timeIntervalSince1970: 0), operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
    )
    let artifact = try PolicyArtifact.compile(payload)
    var changed = artifact.bytes
    changed[changed.startIndex] ^= 0xff

    #expect(throws: PolicyArtifactError.hashMismatch) {
        _ = try PolicyArtifact(bytes: changed, hash: artifact.hash)
    }
}

@Test func artifactRejectsUnknownFieldsEvenWithARecomputedHash() throws {
    let payload = try CompiledPolicyPayload(
        lineageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        generation: 2,
        authorizedUID: 501,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        operationMode: .silentAllow,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    )
    let compiled = try PolicyArtifact.compile(payload)
    var root = try #require(
        JSONSerialization.jsonObject(with: compiled.bytes) as? [String: Any]
    )
    var compatibility = try #require(root["compatibility"] as? [String: Any])
    compatibility["futureCapability"] = true
    root["compatibility"] = compatibility
    let changed = try JSONSerialization.data(
        withJSONObject: root,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let artifact = try PolicyArtifact(
        bytes: changed,
        hash: Data(SHA256.hash(data: changed))
    )

    #expect(throws: PolicyArtifactError.nonCanonicalEncoding) {
        _ = try artifact.decode()
    }
}

@Test func artifactRejectsInternalModesAndNonCanonicalGroups() throws {
    let group = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let payload = try CompiledPolicyPayload(
        lineageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        generation: 3,
        authorizedUID: 501,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        operationMode: .silentAllow,
        activeProfileID: nil,
        enabledLocalGroupIDs: [group],
        rules: []
    )
    let compiled = try PolicyArtifact.compile(payload)
    let decodedRoot = try #require(
        JSONSerialization.jsonObject(with: compiled.bytes) as? [String: Any]
    )

    var internalMode = decodedRoot
    internalMode["operationMode"] = OperationMode.degradedFallback.rawValue
    let internalModeBytes = try JSONSerialization.data(
        withJSONObject: internalMode,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let internalModeArtifact = try PolicyArtifact(
        bytes: internalModeBytes,
        hash: Data(SHA256.hash(data: internalModeBytes))
    )
    #expect(throws: PolicyArtifactError.invalidOperationMode) {
        _ = try internalModeArtifact.decode()
    }

    var duplicateGroups = decodedRoot
    duplicateGroups["enabledLocalGroupIDs"] = [group.uuidString, group.uuidString]
    let duplicateGroupBytes = try JSONSerialization.data(
        withJSONObject: duplicateGroups,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let duplicateGroupArtifact = try PolicyArtifact(
        bytes: duplicateGroupBytes,
        hash: Data(SHA256.hash(data: duplicateGroupBytes))
    )
    #expect(throws: PolicyArtifactError.nonCanonicalOrdering) {
        _ = try duplicateGroupArtifact.decode()
    }
}

@Test func protocolRangeNegotiatesOnlyCompatibleMajors() {
    let local = ProtocolRange(
        minimum: ProtocolVersion(major: 1, minor: 0),
        maximum: ProtocolVersion(major: 1, minor: 3)
    )
    let peer = ProtocolRange(
        minimum: ProtocolVersion(major: 1, minor: 2),
        maximum: ProtocolVersion(major: 1, minor: 4)
    )
    #expect(local.highestMutualVersion(with: peer) == ProtocolVersion(major: 1, minor: 3))
}
