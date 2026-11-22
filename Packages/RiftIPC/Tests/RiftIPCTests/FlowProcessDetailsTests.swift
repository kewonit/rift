import Foundation
import RiftCore
import Testing
@testable import RiftIPC

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private func details() throws -> FlowProcessDetails {
    try #require(FlowProcessDetails(
        process: ObservedProcess(processID: 812, executablePath: "/usr/local/bin/sync-tool"),
        app: ObservedProcess(processID: 640, executablePath: "/Applications/Sync.app/Contents/MacOS/Sync")
    ))
}

private func flow() -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(), observedAt: fixedNow, sourceAppIdentity: nil, sourceProcessIdentity: nil,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil, remoteEndpoint: nil, observedHostname: nil, metadataConfidence: []
    )
}

@Test func anObservedProcessNeedsARealProcessIDAndKeepsOnlyAUsablePath() throws {
    #expect(ObservedProcess(processID: 0, executablePath: "/bin/ls") == nil)
    #expect(ObservedProcess(processID: -4, executablePath: nil) == nil)
    #expect(ObservedProcess(processID: 7, executablePath: nil)?.executablePath == nil)
    #expect(ObservedProcess(processID: 7, executablePath: "/bin/ls")?.executablePath == "/bin/ls")
    // Relative, oversized and control-character paths are dropped, not shown.
    #expect(ObservedProcess(processID: 7, executablePath: "bin/ls")?.executablePath == nil)
    #expect(ObservedProcess(processID: 7, executablePath: "/a\u{1B}[31m")?.executablePath == nil)
    #expect(ObservedProcess(
        processID: 7, executablePath: "/" + String(repeating: "a", count: 1_024)
    )?.executablePath == nil)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ObservedProcess.self, from: Data(#"{"processID":0}"#.utf8))
    }
}

@Test func processDetailsDropAnAppThatIsTheSameProcess() throws {
    let process = try #require(ObservedProcess(processID: 9, executablePath: "/bin/ls"))
    #expect(FlowProcessDetails(process: nil, app: nil) == nil)
    let same = try #require(FlowProcessDetails(process: process, app: process))
    #expect(same.app == nil)
    #expect(try details().app?.processID == 640)
}

@Test func promptsCarryProcessDetailsOnlyToAppsThatCanDecodeThem() throws {
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 3,
        flowID: UUID(), observedAt: fixedNow, deadline: fixedNow.addingTimeInterval(30),
        owner: .user(uid: 501), appIdentity: nil, processIdentity: nil,
        direction: .outgoing, transportProtocol: .tcp, endpoint: nil,
        winningRuleID: nil, affectingRuleIDs: [], processes: try details()
    )
    let roundTrip = try SecureIPCCodec.decode(
        PromptRequest.self, from: SecureIPCCodec.encode(prompt.compatible(with: .extendedPolicy))
    )
    #expect(roundTrip.processes == prompt.processes)

    let older = prompt.compatible(with: .internationalNames)
    #expect(older.processes == nil)
    #expect(!String(decoding: try SecureIPCCodec.encode(older), as: UTF8.self).contains("processes"))
    #expect(prompt.updated(deadline: fixedNow, cohortCount: 2).processes == prompt.processes)
}

@Test func eventsCarryProcessDetailsOnlyToAppsThatCanDecodeThem() throws {
    let event = RuntimeEvent(
        providerEpoch: UUID(), sequence: 4, occurredAt: fixedNow, flow: flow(), action: .allow,
        reason: .concreteDecision, policy: nil, bytesInbound: 10, bytesOutbound: 20,
        notificationRequested: true, processes: try details()
    )
    let bytes = try SecureIPCCodec.encode(event)
    #expect(try SecureIPCCodec.decode(RuntimeEvent.self, from: bytes) == event)

    let older = event.compatible(with: .internationalNames)
    #expect(older.processes == nil)
    #expect(older.sequence == 4)
    #expect(older.bytesInbound == 10)
    #expect(older.notificationRequested)
    #expect(!String(decoding: try SecureIPCCodec.encode(older), as: UTF8.self).contains("processes"))
    #expect(event.compatible(with: .extendedPolicy) == event)

    // An event saved or sent before the field existed still decodes.
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object.removeValue(forKey: "processes")
    let earlier = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(try SecureIPCCodec.decode(RuntimeEvent.self, from: earlier).processes == nil)
}
