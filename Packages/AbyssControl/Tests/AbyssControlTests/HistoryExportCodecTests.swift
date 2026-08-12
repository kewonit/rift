import AbyssCore
import AbyssIPC
import Foundation
import Testing
@testable import AbyssControl

@Suite("History export codec")
struct HistoryExportCodecTests {
    @Test func incrementalJSONMatchesSchemaOneCanonicalDocument() throws {
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_100.125)
        let rows = try [exportRow(sequence: 2), exportRow(sequence: 7)]
        let expected = try CanonicalPolicyJSON.encoder().encode(
            ReferenceHistoryExportDocument(
                schemaVersion: 1,
                exportedAt: exportedAt,
                events: rows.map(ReferenceHistoryExportRecord.init)
            )
        )

        let actual = try HistoryExportCodec.encode(
            rows: rows,
            format: .json,
            exportedAt: exportedAt
        )

        #expect(actual == expected)
        let decoded = try CanonicalPolicyJSON.decoder().decode(
            ReferenceHistoryExportDocument.self,
            from: actual
        )
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.events.map(\.event.sequence) == [2, 7])
    }

    @Test(arguments: [HistoryExportFormat.json, .csv])
    func byteLimitAcceptsExactSizeAndRejectsBoundaryPlusOne(
        format: HistoryExportFormat
    ) throws {
        let rows = try [exportRow(sequence: 2), exportRow(sequence: 7)]
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_100.125)
        let full = try HistoryExportCodec.encode(
            rows: rows,
            format: format,
            exportedAt: exportedAt
        )

        let exact = try HistoryExportCodec.encode(
            rows: rows,
            format: format,
            exportedAt: exportedAt,
            maximumBytes: full.count
        )
        #expect(exact == full)
        #expect(throws: HistoryExportError.maximumBytesExceeded) {
            try HistoryExportCodec.encode(
                rows: rows,
                format: format,
                exportedAt: exportedAt,
                maximumBytes: full.count - 1
            )
        }
        #expect(throws: HistoryExportError.maximumBytesExceeded) {
            try HistoryExportCodec.encode(
                rows: rows,
                format: format,
                exportedAt: exportedAt,
                maximumBytes: full.count - 1
            )
        }
    }

    @Test(arguments: [HistoryExportFormat.json, .csv])
    func nonpositiveByteLimitsAreRejected(format: HistoryExportFormat) throws {
        let row = try exportRow(sequence: 2)
        for maximumBytes in [0, -1] {
            #expect(throws: HistoryExportError.maximumBytesExceeded) {
                try HistoryExportCodec.encode(
                    rows: [row],
                    format: format,
                    exportedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    maximumBytes: maximumBytes
                )
            }
        }
    }

    @Test func CSVPreservesOrderCRLFAndFormulaNeutralization() throws {
        let first = try exportRow(sequence: 2)
        let second = try exportRow(sequence: 7)
        let data = try HistoryExportCodec.encode(
            rows: [first, second],
            format: .csv,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let csv = try #require(String(data: data, encoding: .utf8))
        let firstID = first.event.flow.flowID.uuidString.lowercased()
        let secondID = second.event.flow.flowID.uuidString.lowercased()
        let firstRange = try #require(csv.range(of: firstID))
        let secondRange = try #require(csv.range(of: secondID))

        #expect(firstRange.lowerBound < secondRange.lowerBound)
        #expect(csv.hasSuffix("\r\n"))
        #expect(!csv.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(HistoryExportCodec.csvCell(" =cmd") == "\"' =cmd\"")
        #expect(HistoryExportCodec.csvCell("safe \"value\"") == "\"safe \"\"value\"\"\"")
    }
}

private struct ReferenceHistoryExportDocument: Codable {
    let schemaVersion: UInt16
    let exportedAt: Date
    let events: [ReferenceHistoryExportRecord]
}

private struct ReferenceHistoryExportRecord: Codable {
    let event: RuntimeEvent
    let coverage: HistoryCoverage
    let closedAt: Date?
    let bytesInbound: UInt64?
    let bytesOutbound: UInt64?
    let flowEndReason: RuntimeFlowEndReason?

    init(_ row: MonitorEventRow) {
        event = row.event
        coverage = row.coverage
        closedAt = row.closedAt
        bytesInbound = row.bytesInbound
        bytesOutbound = row.bytesOutbound
        flowEndReason = row.flowEndReason
    }
}

private func exportRow(sequence: UInt64) throws -> MonitorEventRow {
    let providerEpoch = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
    let flowID = try #require(
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llu", sequence))
    )
    let occurredAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
    let flow = FlowDescriptor(
        flowID: flowID,
        observedAt: occurredAt,
        sourceAppIdentity: nil,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("198.51.100.8"),
            port: 443,
            hostname: nil,
            hostnameCoverage: .absent,
            classes: [],
            interfaceSnapshotGeneration: 4
        ),
        observedHostname: nil,
        metadataConfidence: [.endpoint, .owner]
    )
    let event = RuntimeEvent(
        providerEpoch: providerEpoch,
        sequence: sequence,
        occurredAt: occurredAt,
        flow: flow,
        action: sequence.isMultiple(of: 2) ? .allow : .deny,
        reason: .concreteDecision,
        policy: nil,
        bytesInbound: sequence * 10,
        bytesOutbound: sequence * 20
    )
    return MonitorEventRow(
        event: event,
        coverage: sequence.isMultiple(of: 2) ? .complete : .partial,
        closedAt: occurredAt.addingTimeInterval(1),
        bytesInbound: sequence * 10,
        bytesOutbound: sequence * 20,
        flowEndReason: .networkExtensionReport
    )
}
