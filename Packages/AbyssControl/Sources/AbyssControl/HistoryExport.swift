import AbyssCore
import AbyssIPC
import Foundation

public enum HistoryExportFormat: String, Sendable, Hashable {
    case json
    case csv
}

public enum HistoryExportError: Error, Sendable, Equatable {
    case maximumBytesExceeded
}

public enum HistoryExportCodec {
    public static let maximumBytes = 64 * 1_024 * 1_024

    public static func encode(
        rows: [MonitorEventRow],
        format: HistoryExportFormat,
        exportedAt: Date,
        maximumBytes: Int = maximumBytes
    ) throws -> Data {
        guard maximumBytes > 0 else { throw HistoryExportError.maximumBytesExceeded }
        switch format {
        case .json:
            return try encodeJSON(
                rows: rows,
                exportedAt: exportedAt,
                maximumBytes: maximumBytes
            )
        case .csv:
            return try encodeCSV(rows: rows, maximumBytes: maximumBytes)
        }
    }

    private static func encodeJSON(
        rows: [MonitorEventRow],
        exportedAt: Date,
        maximumBytes: Int
    ) throws -> Data {
        var output = BoundedExportData(maximumBytes: maximumBytes)
        let encoder = CanonicalPolicyJSON.encoder()
        try output.appendUTF8("{\"events\":[")
        for (index, row) in rows.enumerated() {
            if index > 0 { try output.appendUTF8(",") }
            try output.append(encoder.encode(HistoryExportRecord(row)))
        }
        try output.appendUTF8("],\"exportedAt\":")
        try output.append(encoder.encode(exportedAt))
        try output.appendUTF8(",\"schemaVersion\":1}")
        return output.data
    }

    private static func encodeCSV(rows: [MonitorEventRow], maximumBytes: Int) throws -> Data {
        let header = [
            "occurred_at_ms", "closed_at_ms", "provider_epoch", "flow_id", "application_identity",
            "direction", "protocol", "hostname", "address", "port", "decision", "reason",
            "winning_rule_id", "bytes_inbound", "bytes_outbound", "end_reason", "coverage",
        ]
        var output = BoundedExportData(maximumBytes: maximumBytes)
        try appendCSVRow(header, to: &output)
        for row in rows {
            try appendCSVRow(HistoryExportRecord(row).csvValues, to: &output)
        }
        return output.data
    }

    private static func appendCSVRow(
        _ values: [String],
        to output: inout BoundedExportData
    ) throws {
        for (index, value) in values.enumerated() {
            if index > 0 { try output.appendUTF8(",") }
            try output.appendUTF8(csvCell(value))
        }
        try output.appendUTF8("\r\n")
    }

    static func csvCell(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar.value == 0 || (scalar.value < 32 && scalar != "\t" && scalar != "\n" && scalar != "\r") {
                return " "
            }
            return scalar
        }
        var safe = String(String.UnicodeScalarView(scalars))
        let first = safe.drop(while: { $0.isWhitespace }).first
        if let first, "=+-@".contains(first) { safe = "'" + safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private struct HistoryExportRecord: Codable {
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

    var csvValues: [String] {
        let endpoint = event.flow.destinationEndpoint
        return [
            milliseconds(event.occurredAt), closedAt.map(milliseconds) ?? "",
            event.providerEpoch.uuidString.lowercased(), event.flow.flowID.uuidString.lowercased(),
            encoded(event.flow.sourceAppIdentity ?? event.flow.sourceProcessIdentity),
            event.flow.direction.rawValue, encoded(event.flow.transportProtocol),
            (event.flow.observedHostname ?? endpoint?.hostname)?.ascii ?? "",
            endpoint?.address.description ?? "", endpoint?.port.map(String.init) ?? "",
            encoded(event.action), event.reason.rawValue,
            event.winningRuleID?.uuidString.lowercased() ?? "",
            bytesInbound.map(String.init) ?? "", bytesOutbound.map(String.init) ?? "",
            flowEndReason?.rawValue ?? "", coverage.rawValue,
        ]
    }

    private func encoded<T: Encodable>(_ value: T?) -> String {
        guard let value, let data = try? CanonicalPolicyJSON.encoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}

private struct BoundedExportData {
    private(set) var data = Data()
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ value: Data) throws {
        try checkCapacity(for: value.count)
        data.append(value)
    }

    mutating func appendUTF8(_ value: String) throws {
        try checkCapacity(for: value.utf8.count)
        data.append(contentsOf: value.utf8)
    }

    private func checkCapacity(for additionalBytes: Int) throws {
        guard additionalBytes <= maximumBytes - data.count else {
            throw HistoryExportError.maximumBytesExceeded
        }
    }
}
