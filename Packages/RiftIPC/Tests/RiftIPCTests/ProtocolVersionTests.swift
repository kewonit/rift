import Foundation
import Testing
@testable import RiftIPC

@Test func compatibilityRequiresMatchingMajorVersion() {
    #expect(ProtocolVersion.current == .configurationReset)
    #expect(ProtocolVersion.current.supports(minimum: .baseline))
    #expect(ProtocolVersion.current.isCompatible(with: .init(major: 1, minor: 99)))
    #expect(!ProtocolVersion.current.isCompatible(with: .init(major: 2, minor: 0)))
}

@Test func protocolSupportRequiresTheSameMajorAndSufficientMinor() {
    let current = ProtocolVersion(major: 1, minor: 2)
    #expect(current.supports(minimum: .init(major: 1, minor: 0)))
    #expect(current.supports(minimum: .init(major: 1, minor: 2)))
    #expect(!current.supports(minimum: .init(major: 1, minor: 3)))
    #expect(!current.supports(minimum: .init(major: 2, minor: 0)))
}

@Test func healthSnapshotHasDeterministicJSONEncoding() throws {
    let value = HealthSnapshot(providerStatus: .ready, filterEnabled: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let first = try encoder.encode(value)
    let second = try encoder.encode(value)
    #expect(first == second)
}

@Test func handshakeDecodesPayloadFromBeforeOptionalLineageFieldsWereAdded() throws {
    let state = HandshakeState(
        runtimeInstanceID: UUID(), providerEpoch: nil, readiness: .degradedNoPolicy,
        protocolRange: ProtocolRange(minimum: .current, maximum: .current),
        snapshotSchemaRange: 1...1, acceptedGenerationHighWater: 0,
        persisted: nil, active: nil, controllerLeaseID: nil
    )
    let encoded = try JSONEncoder().encode(state)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "boundLineageID")
    object.removeValue(forKey: "configurationResetLineageID")
    let legacyPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(HandshakeState.self, from: legacyPayload)
    #expect(decoded.boundLineageID == nil)
    #expect(decoded.configurationResetLineageID == nil)
    #expect(decoded.runtimeInstanceID == state.runtimeInstanceID)
}
