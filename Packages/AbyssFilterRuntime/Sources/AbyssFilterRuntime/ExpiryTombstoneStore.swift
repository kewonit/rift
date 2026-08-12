import AbyssCore
import CryptoKit
import Foundation

public enum ExpiryTombstoneStoreError: Error, Sendable, Equatable {
    case corrupt
    case overCapacity
    case rootMismatch
}

enum ExpiryTombstoneStoreCheckpoint: Sendable, Equatable {
    case beforeWrite
}

public actor ExpiryTombstoneStore {
    public static let maximumKeys = 4_096
    private static let fileName = "expiry-tombstones.json"
    nonisolated private let directory: SecureDirectory
    nonisolated private let writeFault: (@Sendable (ExpiryTombstoneStoreCheckpoint) throws -> Void)?

    public init(rootURL: URL) throws {
        directory = try SecureDirectory(url: rootURL)
        writeFault = nil
    }

    init(
        rootURL: URL,
        writeFault: @escaping @Sendable (ExpiryTombstoneStoreCheckpoint) throws -> Void
    ) throws {
        directory = try SecureDirectory(url: rootURL)
        self.writeFault = writeFault
    }

    public func load() throws -> Set<ExpiredRuleKey> {
        try directory.withExclusiveLock { try loadAssumingExclusiveRootLock() }
    }

    @discardableResult
    public func record(_ additions: Set<ExpiredRuleKey>) throws -> Set<ExpiredRuleKey> {
        try directory.withExclusiveLock {
            var keys = try loadAssumingExclusiveRootLock()
            keys.formUnion(additions)
            guard keys.count <= Self.maximumKeys else {
                throw ExpiryTombstoneStoreError.overCapacity
            }
            try writeAssumingExclusiveRootLock(keys)
            return keys
        }
    }

    @discardableResult
    public func prune(retaining referenced: Set<ExpiredRuleKey>) throws -> Set<ExpiredRuleKey> {
        try directory.withExclusiveLock {
            try pruneAssumingExclusiveRootLock(retaining: referenced)
        }
    }

    public func erase() throws {
        try directory.withExclusiveLock { try directory.remove(Self.fileName) }
    }

    nonisolated var rootURL: URL { directory.url }

    nonisolated func pruneAssumingExclusiveRootLock(
        retaining referenced: Set<ExpiredRuleKey>
    ) throws -> Set<ExpiredRuleKey> {
        let keys = try loadAssumingExclusiveRootLock().intersection(referenced)
        try writeAssumingExclusiveRootLock(keys)
        return keys
    }

    nonisolated private func loadAssumingExclusiveRootLock() throws -> Set<ExpiredRuleKey> {
        guard let data = try directory.read(Self.fileName, maximumBytes: 2 * 1_024 * 1_024) else {
            return []
        }
        let file = try Self.decoder.decode(TombstoneFile.self, from: data)
        let content = try Self.encoder.encode(file.keys)
        guard file.schemaVersion == TombstoneFile.schemaVersion,
              Data(SHA256.hash(data: content)) == file.checksum,
              file.keys.count <= Self.maximumKeys else {
            throw ExpiryTombstoneStoreError.corrupt
        }
        return Set(file.keys)
    }

    nonisolated private func writeAssumingExclusiveRootLock(
        _ keys: Set<ExpiredRuleKey>
    ) throws {
        try writeFault?(.beforeWrite)
        let sorted = keys.sorted {
            if $0.lineageID != $1.lineageID {
                return $0.lineageID.uuidString < $1.lineageID.uuidString
            }
            if $0.ruleID != $1.ruleID { return $0.ruleID.uuidString < $1.ruleID.uuidString }
            if $0.revision != $1.revision { return $0.revision < $1.revision }
            return $0.expiresAt < $1.expiresAt
        }
        let content = try Self.encoder.encode(sorted)
        let file = TombstoneFile(
            schemaVersion: TombstoneFile.schemaVersion,
            keys: sorted,
            checksum: Data(SHA256.hash(data: content))
        )
        try directory.writeAtomically(try Self.encoder.encode(file), to: Self.fileName)
    }

    private struct TombstoneFile: Codable {
        static let schemaVersion: UInt16 = 1

        let schemaVersion: UInt16
        let keys: [ExpiredRuleKey]
        let checksum: Data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
