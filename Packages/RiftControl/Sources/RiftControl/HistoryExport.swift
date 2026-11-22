import RiftCore
import RiftIPC
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
        var stream = try HistoryExportStream(format: format, maximumBytes: maximumBytes)
        for row in rows { try stream.append(row) }
        return try stream.finish(exportedAt: exportedAt)
    }

    static let csvHeader = [
        "occurred_at_ms", "closed_at_ms", "provider_epoch", "flow_id", "application_identity",
        "direction", "protocol", "hostname", "address", "port", "decision", "reason",
        "winning_rule_id", "bytes_inbound", "bytes_outbound", "end_reason", "coverage",
    ]

    fileprivate static func appendCSVRow(
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

/// Writes an export one connection at a time, so a long history is read
/// row by row instead of all at once. The output is still bounded.
public struct HistoryExportStream {
    private let format: HistoryExportFormat
    private let encoder = CanonicalPolicyJSON.encoder()
    private var output: BoundedExportData
    private var count = 0

    public init(format: HistoryExportFormat, maximumBytes: Int = HistoryExportCodec.maximumBytes) throws {
        guard maximumBytes > 0 else { throw HistoryExportError.maximumBytesExceeded }
        self.format = format
        output = BoundedExportData(maximumBytes: maximumBytes)
        switch format {
        case .json: try output.appendUTF8("{\"events\":[")
        case .csv: try HistoryExportCodec.appendCSVRow(HistoryExportCodec.csvHeader, to: &output)
        }
    }

    public mutating func append(_ row: MonitorEventRow) throws {
        switch format {
        case .json:
            if count > 0 { try output.appendUTF8(",") }
            try output.append(encoder.encode(HistoryExportRecord(row)))
        case .csv:
            try HistoryExportCodec.appendCSVRow(HistoryExportRecord(row).csvValues, to: &output)
        }
        count += 1
    }

    public mutating func finish(exportedAt: Date) throws -> Data {
        if format == .json {
            try output.appendUTF8("],\"exportedAt\":")
            try output.append(encoder.encode(exportedAt))
            try output.appendUTF8(",\"schemaVersion\":1}")
        }
        return output.data
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

fileprivate struct BoundedExportData {
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
