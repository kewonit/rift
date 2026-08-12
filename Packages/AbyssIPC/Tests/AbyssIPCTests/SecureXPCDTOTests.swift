import AbyssCore
import Foundation
import Testing
@testable import AbyssIPC

@Test func secureEnvelopeRoundTripsOnlyAllowedClasses() throws {
    let original = SecureIPCEnvelope(
        requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        kind: .health,
        payload: Data([1, 2, 3])
    )
    let archived = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
    let candidate = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: SecureIPCEnvelope.self,
        from: archived
    )
    let decoded = try #require(candidate)
    #expect(decoded.requestID == original.requestID)
    #expect(decoded.messageKind == .health)
    #expect(decoded.payload == Data([1, 2, 3]))
}

@Test func replyBoundsRedactedErrors() {
    let reply = SecureIPCReply(
        requestID: UUID(), status: .rejected,
        redactedErrorCode: String(repeating: "x", count: 1_000)
    )
    #expect(reply.redactedErrorCode?.count == 128)
}

@Test func cliRelayValuesEnforceWireBounds() throws {
    let request = try CLIRelayRequest(
        command: .profilesActivate,
        argument: String(repeating: "a", count: 300)
    )
    #expect(request.argument?.count == 256)

    #expect(throws: CLIValueError.oversizedPayload) {
        try CLIRelayRequest(
            command: .rulesImportAppend,
            payload: Data(repeating: 0, count: IPCProtocolLimits.maximumSnapshotBytes + 1)
        )
    }
    #expect(throws: CLIValueError.oversizedPayload) {
        try CLIRelayResponse(
            summary: "oversized JSON",
            json: Data(repeating: 0, count: 1 * 1_024 * 1_024 + 1)
        )
    }

    #expect(throws: CLIValueError.invalidTransfer) {
        try CLITransferChunk(
            transferID: UUID(), offset: 0,
            bytes: Data(repeating: 0, count: IPCProtocolLimits.maximumChunkBytes + 1)
        )
    }
}

@Test func cliTransferStoreRequiresOrderedBoundedChunksAndExpires() async throws {
    let store = CLITransferStore(maximumConcurrentTransfers: 1)
    let start = Date(timeIntervalSince1970: 1_000)
    let source = Data(repeating: 7, count: IPCProtocolLimits.maximumChunkBytes + 3)
    let download = try await store.beginDownload(data: source, now: start)
    await #expect(throws: CLITransferStoreError.busy) {
        try await store.beginDownload(data: Data(), now: start)
    }
    let first = try await store.readDownload(
        CLITransferRead(
            transferID: download.transferID,
            offset: 0,
            maximumBytes: IPCProtocolLimits.maximumChunkBytes
        ),
        now: start
    )
    #expect(first.bytes.count == IPCProtocolLimits.maximumChunkBytes)
    await store.cancel(download.transferID)

    let upload = try CLITransferDescriptor(totalBytes: 3)
    try await store.beginUpload(upload, now: start)
    await #expect(throws: CLITransferStoreError.invalidTransfer) {
        try await store.appendUpload(
            CLITransferChunk(transferID: upload.transferID, offset: 1, bytes: Data([1])),
            now: start
        )
    }
    try await store.appendUpload(
        CLITransferChunk(transferID: upload.transferID, offset: 0, bytes: Data([1, 2, 3])),
        now: start
    )
    #expect(try await store.finishUpload(upload.transferID, now: start) == Data([1, 2, 3]))

    let expired = try await store.beginDownload(data: Data([1]), now: start)
    await #expect(throws: CLITransferStoreError.invalidTransfer) {
        try await store.readDownload(
            CLITransferRead(transferID: expired.transferID, offset: 0, maximumBytes: 1),
            now: start.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds + 1)
        )
    }
}

@Test func promptDeadlineRoundTripsAndOlderPayloadGetsFixedFallback() throws {
    let observedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    let deadline = observedAt.addingTimeInterval(5)
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 3,
        flowID: UUID(), observedAt: observedAt, deadline: deadline, cohortCount: 7,
        owner: .user(uid: 501), appIdentity: nil, processIdentity: nil,
        direction: .outgoing, transportProtocol: .udp, endpoint: nil,
        winningRuleID: nil, affectingRuleIDs: []
    )
    let encoded = try JSONEncoder().encode(prompt)
    let roundTrip = try JSONDecoder().decode(PromptRequest.self, from: encoded)
    #expect(roundTrip.deadline == deadline)
    #expect(roundTrip.cohortCount == 7)

    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "deadline")
    object.removeValue(forKey: "cohortCount")
    let olderPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(PromptRequest.self, from: olderPayload)
    #expect(decoded.deadline == observedAt.addingTimeInterval(8))
    #expect(decoded.cohortCount == 1)

    for invalidCount in [0, 257] {
        object["cohortCount"] = invalidCount
        let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PromptRequest.self, from: invalid)
        }
    }
}

@Test func secureCodecRejectsUnknownFieldsButAllowsOlderMissingKnownFields() throws {
    let observedAt = Date(timeIntervalSinceReferenceDate: 4_000)
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 8,
        flowID: UUID(), observedAt: observedAt,
        owner: .user(uid: 501), appIdentity: nil, processIdentity: nil,
        direction: .outgoing, transportProtocol: .tcp,
        endpoint: Endpoint(
            address: try IPAddress("203.0.113.10"), port: 443,
            hostname: try DomainName("example.test"), hostnameCoverage: .observed,
            classes: [], interfaceSnapshotGeneration: 2
        ),
        winningRuleID: nil, affectingRuleIDs: []
    )
    let encoded = try SecureIPCCodec.encode(prompt)

    var older = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    older.removeValue(forKey: "deadline")
    older.removeValue(forKey: "cohortCount")
    let olderBytes = try JSONSerialization.data(withJSONObject: older, options: [.sortedKeys])
    let decoded = try SecureIPCCodec.decode(PromptRequest.self, from: olderBytes)
    #expect(decoded.deadline == observedAt.addingTimeInterval(30))
    #expect(decoded.cohortCount == 1)

    var unknownRoot = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    unknownRoot["futureField"] = true
    let unknownRootBytes = try JSONSerialization.data(
        withJSONObject: unknownRoot, options: [.sortedKeys]
    )
    #expect(throws: SecureIPCCodecError.unknownField) {
        try SecureIPCCodec.decode(PromptRequest.self, from: unknownRootBytes)
    }

    var unknownNested = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var endpoint = try #require(unknownNested["endpoint"] as? [String: Any])
    endpoint["futureField"] = true
    unknownNested["endpoint"] = endpoint
    let unknownNestedBytes = try JSONSerialization.data(
        withJSONObject: unknownNested, options: [.sortedKeys]
    )
    #expect(throws: SecureIPCCodecError.unknownField) {
        try SecureIPCCodec.decode(PromptRequest.self, from: unknownNestedBytes)
    }
}
