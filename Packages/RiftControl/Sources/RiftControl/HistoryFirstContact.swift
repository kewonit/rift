import CryptoKit
import Foundation
import GRDB
import RiftCore
import RiftIPC

/// Which app reached which name, kept beside each connection in history so
/// an alert can say "first time" without reading every saved connection. It
/// holds nothing history doesn't already hold, and goes when the connection
/// does.
enum HistoryContactIndex {
    /// A short, stable key for an app: the start of a SHA-256 of the same
    /// encoding the review list uses.
    static func appKey(_ identity: ProcessIdentity) -> Int64 {
        let digest = SHA256.hash(data: Data(ReviewQueue.key(for: identity).utf8))
        return digest.prefix(8).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }

    static func appKey(_ flow: FlowDescriptor) -> Int64? {
        (flow.sourceAppIdentity ?? flow.sourceProcessIdentity).map(appKey)
    }

    /// The name the connection reached, or nil when it arrived with only an
    /// address.
    static func destinationName(_ flow: FlowDescriptor) -> String? {
        if flow.metadataConfidence.contains(.observedHostname), let name = flow.observedHostname {
            return name.ascii.lowercased()
        }
        return flow.destinationEndpoint?.hostname?.ascii.lowercased()
    }

    /// Fills in the key for connections saved before the index existed.
    static func backfill(in database: Database) throws {
        let decoder = CanonicalPolicyJSON.decoder()
        let rows = try Row.fetchCursor(
            database,
            sql: "SELECT provider_epoch, flow_id, decision_event FROM flow_lifecycle WHERE decision_event IS NOT NULL"
        )
        var updates: [(epoch: String, flowID: String, key: Int64, name: String?)] = []
        while let row = try rows.next() {
            let encoded: Data = row["decision_event"]
            guard let flow = try? decoder.decode(RuntimeEvent.self, from: encoded).flow,
                  let key = appKey(flow) else { continue }
            updates.append((row["provider_epoch"], row["flow_id"], key, destinationName(flow)))
        }
        for update in updates {
            try database.execute(
                sql: "UPDATE flow_lifecycle SET app_key = ?, destination_name = ? WHERE provider_epoch = ? AND flow_id = ?",
                arguments: [update.key, update.name, update.epoch, update.flowID]
            )
        }
    }

    /// `%` and `_` are wildcards in LIKE, and `_` can appear in a name.
    static func likeSuffix(_ domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%." + escaped
    }
}

public enum HistoryFirstContact {
    /// History younger than this can't tell a new destination from one it
    /// just hasn't seen yet.
    public static let minimumRecording: TimeInterval = 24 * 60 * 60

    public static func sentence(domain: String) -> String {
        String(localized: "First time this app has connected to \(DisplaySanitizer.plainText(domain))", bundle: .module)
    }
}

extension HistoryRepository {
    /// Whether this is the first time history has seen the app connect to the
    /// domain or a name under it. Nil when history can't say: it's off, or
    /// it hasn't been recording for a day yet.
    /// - Parameters:
    ///   - before: when the connection being asked about arrived; anything
    ///     saved from then on doesn't count.
    ///   - excluding: that connection's own flow, in case it's saved already.
    public func isFirstContact(
        app identity: ProcessIdentity,
        domain: String,
        before: Date,
        excluding flowID: UUID? = nil
    ) throws -> Bool? {
        let name = domain.lowercased()
        guard !name.isEmpty, name.utf8.count <= 253, try settings().enabled else { return nil }
        return try database.read { database in
            let coverage = try HistoryCoverageStore.snapshot(in: database)
            guard coverage.isRecording, let since = coverage.recordingSince,
                  before.timeIntervalSince(since) >= HistoryFirstContact.minimumRecording else { return nil }
            let earlier = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM flow_lifecycle
                        WHERE app_key = ?
                          AND (destination_name = ? OR destination_name LIKE ? ESCAPE '\\')
                          AND decision_event IS NOT NULL AND decision_at < ? AND flow_id != ?
                    )
                    """,
                arguments: [
                    HistoryContactIndex.appKey(identity), name, HistoryContactIndex.likeSuffix(name),
                    before.timeIntervalSince1970, flowID?.uuidString.lowercased() ?? "",
                ]
            ) ?? false
            return !earlier
        }
    }
}
