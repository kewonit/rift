import CryptoKit
import Foundation
import RiftCore
import Testing
@testable import RiftIPC

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private func payload(_ alerts: UnansweredAlertPolicy?) throws -> CompiledPolicyPayload {
    try CompiledPolicyPayload(
        lineageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        generation: 4, authorizedUID: 501, createdAt: fixedNow, operationMode: .alert,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: [], unansweredAlerts: alerts
    )
}

/// The compiled policy as builds before protocol 1.4 declare it. They ignore
/// keys they don't know when decoding, then refuse bytes that don't match
/// what they would have written.
private struct PayloadBeforeExtendedPolicy: Codable {
    let schemaVersion: UInt16
    let lineageID: UUID
    let generation: UInt64
    let authorizedUID: UInt32
    let compatibility: PolicyCompatibility
    let createdAt: Date
    let operationMode: OperationMode
    let activeProfileID: UUID?
    let enabledLocalGroupIDs: [UUID]
    let rules: [Rule]
}

@Test func unansweredAlertPolicyAcceptsOnlyAllowOrDenyWithinTheWaitBounds() throws {
    #expect(throws: UnansweredAlertPolicyError.actionMustAllowOrDeny) {
        try UnansweredAlertPolicy(action: .ask, waitSeconds: 30)
    }
    #expect(throws: UnansweredAlertPolicyError.waitOutOfRange(4)) {
        try UnansweredAlertPolicy(action: .deny, waitSeconds: 4)
    }
    #expect(throws: UnansweredAlertPolicyError.waitOutOfRange(121)) {
        try UnansweredAlertPolicy(action: .deny, waitSeconds: 121)
    }
    #expect(try UnansweredAlertPolicy(action: .deny, waitSeconds: 120).waitSeconds == 120)
    #expect(UnansweredAlertPolicy.maximumWaitSeconds <= 120)
}

@Test func unansweredAlertPolicyRefusesOutOfRangeValuesWhenDecoding() throws {
    for body in [
        #"{"action":"ask","waitSeconds":30}"#,
        #"{"action":"deny","waitSeconds":0}"#,
        #"{"action":"deny","waitSeconds":600}"#,
        #"{"action":"deny"}"#,
        #"{"action":"drop","waitSeconds":30}"#,
    ] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UnansweredAlertPolicy.self, from: Data(body.utf8))
        }
    }
}

@Test func withoutAPolicyTheWaitAndOutcomeAreWhatEarlierBuildsUsed() {
    let observed = fixedNow
    let later = observed.addingTimeInterval(12)
    #expect(UnansweredAlertPolicy.action(for: nil) == .allow)
    #expect(UnansweredAlertPolicy.deadline(
        for: .tcp, observedAt: observed, askedAt: later, policy: nil
    ) == observed.addingTimeInterval(30))
    #expect(UnansweredAlertPolicy.deadline(
        for: .udp, observedAt: observed, askedAt: later, policy: nil
    ) == observed.addingTimeInterval(8))
}

@Test func aPolicyWaitsFromWhenTheAlertIsAskedForAndNeverPastTheLongestHold() throws {
    let observed = fixedNow
    let block = try UnansweredAlertPolicy(action: .deny, waitSeconds: 60)
    #expect(UnansweredAlertPolicy.action(for: block) == .deny)
    #expect(UnansweredAlertPolicy.deadline(
        for: .tcp, observedAt: observed, askedAt: observed.addingTimeInterval(10), policy: block
    ) == observed.addingTimeInterval(70))
    // A slow identity check can't push the whole hold past the cap.
    let longest = try UnansweredAlertPolicy(action: .allow, waitSeconds: 120)
    #expect(UnansweredAlertPolicy.deadline(
        for: .tcp, observedAt: observed, askedAt: observed.addingTimeInterval(25), policy: longest
    ) == observed.addingTimeInterval(120))
    // UDP is never held longer than it always was.
    #expect(UnansweredAlertPolicy.deadline(
        for: .udp, observedAt: observed, askedAt: observed.addingTimeInterval(3), policy: block
    ) == observed.addingTimeInterval(8))
    let short = try UnansweredAlertPolicy(action: .deny, waitSeconds: 5)
    #expect(UnansweredAlertPolicy.deadline(
        for: .udp, observedAt: observed, askedAt: observed, policy: short
    ) == observed.addingTimeInterval(5))
}

@Test func onlyAPolicyThatSetsUnansweredAlertsNeedsProtocolOnePointFour() throws {
    #expect(ProtocolVersion.current.supports(minimum: .extendedPolicy))
    #expect(!ProtocolVersion.internationalNames.supports(minimum: .extendedPolicy))

    let plain = try payload(nil)
    #expect(plain.compatibility.minimumExtensionProtocol == .baseline)
    let block = try payload(UnansweredAlertPolicy(action: .deny, waitSeconds: 30))
    #expect(block.compatibility.minimumExtensionProtocol == .extendedPolicy)
    #expect(try PolicyArtifact.compile(block).decode() == block)
}

@Test func aPolicyWithoutUnansweredAlertsKeepsTheBytesEarlierBuildsWrote() throws {
    let artifact = try PolicyArtifact.compile(try payload(nil))
    #expect(!String(decoding: artifact.bytes, as: UTF8.self).contains("unansweredAlerts"))
    let older = try CanonicalPolicyJSON.decoder()
        .decode(PayloadBeforeExtendedPolicy.self, from: artifact.bytes)
    #expect(try CanonicalPolicyJSON.encoder().encode(older) == artifact.bytes)
}

@Test func anOlderFilterRefusesAPolicyThatBlocksUnansweredAlertsInsteadOfDroppingTheSetting() throws {
    let block = try payload(UnansweredAlertPolicy(action: .deny, waitSeconds: 30))
    let artifact = try PolicyArtifact.compile(block)
    // Both of an older filter's checks fail: its re-encoding loses the field,
    // so the bytes don't match, and the policy asks for a protocol it lacks.
    let older = try CanonicalPolicyJSON.decoder()
        .decode(PayloadBeforeExtendedPolicy.self, from: artifact.bytes)
    #expect(try CanonicalPolicyJSON.encoder().encode(older) != artifact.bytes)
    #expect(!ProtocolVersion.internationalNames.supports(
        minimum: older.compatibility.minimumExtensionProtocol
    ))
}

@Test func aCorruptUnansweredAlertPolicyFailsTheWholePolicy() throws {
    let artifact = try PolicyArtifact.compile(
        try payload(UnansweredAlertPolicy(action: .deny, waitSeconds: 30))
    )
    var root = try #require(JSONSerialization.jsonObject(with: artifact.bytes) as? [String: Any])
    root["unansweredAlerts"] = ["action": "ask", "waitSeconds": 30]
    let changed = try JSONSerialization.data(
        withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let edited = try PolicyArtifact(bytes: changed, hash: Data(SHA256.hash(data: changed)))
    #expect(throws: DecodingError.self) { _ = try edited.decode() }
}

@Test func promptsCarryTheUnansweredActionOnlyToAppsThatCanDecodeIt() throws {
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 3,
        flowID: UUID(), observedAt: fixedNow, deadline: fixedNow.addingTimeInterval(60),
        cohortCount: 2, owner: .user(uid: 501), appIdentity: nil, processIdentity: nil,
        direction: .outgoing, transportProtocol: .tcp, endpoint: nil,
        winningRuleID: nil, affectingRuleIDs: [], unansweredAction: .deny
    )
    let current = prompt.compatible(with: .extendedPolicy)
    #expect(current == prompt)
    #expect(try SecureIPCCodec.decode(
        PromptRequest.self, from: SecureIPCCodec.encode(current)
    ).unansweredAction == .deny)

    let older = prompt.compatible(with: .internationalNames)
    #expect(older.unansweredAction == nil)
    #expect(older.deadline == prompt.deadline)
    #expect(older.cohortCount == 2)
    #expect(older.nonce == prompt.nonce)
    let olderBytes = try SecureIPCCodec.encode(older)
    #expect(!String(decoding: olderBytes, as: UTF8.self).contains("unansweredAction"))

    // A prompt from an older filter has no such field and still decodes.
    #expect(try SecureIPCCodec.decode(PromptRequest.self, from: olderBytes).unansweredAction == nil)
    #expect(prompt.updated(deadline: fixedNow, cohortCount: 3).unansweredAction == .deny)
}

@Test func onlyAPolicyWithAPortListRuleNeedsProtocolOnePointFour() throws {
    func compiled(_ ports: String) throws -> CompiledPolicyPayload {
        let lineage = UUID()
        let rule = try Rule(
            id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .normal,
            process: .anyProcess, destination: .anyEndpoint, transportProtocol: .tcp,
            port: try PortRange.parse(ports), direction: .outgoing, owner: .authorizedUser,
            createdAt: fixedNow, modifiedAt: fixedNow
        )
        return try CompiledPolicyPayload(
            lineageID: lineage, generation: 1, authorizedUID: 501, createdAt: fixedNow,
            operationMode: .alert, activeProfileID: nil, enabledLocalGroupIDs: [], rules: [rule]
        )
    }
    #expect(try compiled("443").compatibility.minimumExtensionProtocol == .baseline)
    #expect(try compiled("8000-8080").compatibility.minimumExtensionProtocol == .baseline)
    let list = try compiled("20-30, 80, 443")
    #expect(list.compatibility.minimumExtensionProtocol == .extendedPolicy)
    let artifact = try PolicyArtifact.compile(list)
    #expect(try artifact.decode() == list)
    #expect(try artifact.decode().rules[0].port?.contains(80) == true)
}

@Test func onlyAPolicyWithAHighPriorityRuleNeedsProtocolOnePointFour() throws {
    func compiled(_ priority: RulePriority) throws -> CompiledPolicyPayload {
        let lineage = UUID()
        let rule = try Rule(
            id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: priority,
            process: .anyProcess, destination: .anyEndpoint, transportProtocol: .tcp,
            port: nil, direction: .outgoing, owner: .authorizedUser,
            createdAt: fixedNow, modifiedAt: fixedNow
        )
        return try CompiledPolicyPayload(
            lineageID: lineage, generation: 1, authorizedUID: 501, createdAt: fixedNow,
            operationMode: .alert, activeProfileID: nil, enabledLocalGroupIDs: [], rules: [rule]
        )
    }
    #expect(try compiled(.normal).compatibility.minimumExtensionProtocol == .baseline)
    let high = try compiled(.high)
    #expect(high.compatibility.minimumExtensionProtocol == .extendedPolicy)
    #expect(try PolicyArtifact.compile(high).decode() == high)
}
