import CryptoKit
import Darwin
import Foundation

enum GeoDatabasePromotionError: Error, Sendable, Equatable {
    case invalidStagingMetadata
    case unexpectedStagingFamily
    case unsafeDatabaseFamily
    case promotedFileChanged
    case interruptedPromotionUnrecoverable
    case rollbackFailed
    case ioFailure(Int32)
}

enum GeoDatabasePromotionCheckpoint: CaseIterable, Sendable, Equatable {
    case afterPromotion
    case afterPermissions
    case afterOpenValidation
    case afterMetadataVerification
    case afterHashVerification
    case afterDirectorySync
}

enum GeoDatabasePromotion {
    typealias FaultInjector = @Sendable (GeoDatabasePromotionCheckpoint) throws -> Void

    private static let familySuffixes = ["", "-wal", "-shm", "-journal"]
    private static let cleanupSuffixes = ["-journal", "-shm", "-wal", ""]
    private static let hashChunkBytes = 64 * 1_024
    private static let maximumDatabaseBytes: Int64 = 16 * 1_024 * 1_024 * 1_024

    static func promote(
        staging: URL,
        to destination: URL,
        expectedMetadata: GeoDatabaseMetadata,
        faultInjector: FaultInjector = { _ in }
    ) throws {
        try recoverInterruptedPromotion(at: destination)
        let stagedMetadata = try GeoDatabase.validateExisting(at: staging)
        guard metadataMatches(stagedMetadata, expectedMetadata) else {
            throw GeoDatabasePromotionError.invalidStagingMetadata
        }
        guard familySuffixes.dropFirst().allSatisfy({
            !FileManager.default.fileExists(atPath: staging.path + $0)
        }) else {
            throw GeoDatabasePromotionError.unexpectedStagingFamily
        }
        let stagedFingerprint = try fingerprint(at: staging)
        let predecessor = predecessorURL(for: destination)
        guard existingSuffixes(at: predecessor).isEmpty else {
            throw GeoDatabasePromotionError.interruptedPromotionUnrecoverable
        }

        let oldMetadata = try? GeoDatabase.validateExisting(at: destination)
        let hadDestination = FileManager.default.fileExists(atPath: destination.path)
        if hadDestination { try validateFamily(at: destination) }
        var predecessorMoved = false
        var promoted = false
        do {
            if hadDestination {
                try moveFamily(from: destination, to: predecessor)
                predecessorMoved = true
                try synchronizeDirectory(containing: destination)
            }
            try moveFamily(from: staging, to: destination)
            promoted = true
            try faultInjector(.afterPromotion)

            try setOwnerOnlyPermissions(at: destination)
            try faultInjector(.afterPermissions)
            let promotedMetadata = try GeoDatabase.validateExisting(at: destination)
            try faultInjector(.afterOpenValidation)
            guard metadataMatches(promotedMetadata, expectedMetadata) else {
                throw GeoDatabasePromotionError.invalidStagingMetadata
            }
            try faultInjector(.afterMetadataVerification)
            let promotedFingerprint = try fingerprint(at: destination)
            guard stagedFingerprint.matchesPromoted(promotedFingerprint) else {
                throw GeoDatabasePromotionError.promotedFileChanged
            }
            try faultInjector(.afterHashVerification)
            try synchronizeDirectory(containing: destination)
            try faultInjector(.afterDirectorySync)
        } catch let promotionError {
            do {
                try rollback(
                    destination: destination,
                    predecessor: predecessorMoved ? predecessor : nil,
                    expectedOldMetadata: oldMetadata,
                    removePromoted: promoted
                )
            } catch {
                throw GeoDatabasePromotionError.rollbackFailed
            }
            throw promotionError
        }
    }

    static func recoverInterruptedPromotion(at destination: URL) throws {
        let predecessor = predecessorURL(for: destination)
        let predecessorSuffixes = existingSuffixes(at: predecessor)
        guard !predecessorSuffixes.isEmpty else { return }
        guard predecessorSuffixes.contains("") else {
            throw GeoDatabasePromotionError.interruptedPromotionUnrecoverable
        }

        if (try? GeoDatabase.validateExisting(at: destination)) != nil {
            try synchronizeDirectory(containing: destination)
            try removeFamily(at: predecessor)
            try synchronizeDirectory(containing: destination)
            return
        }
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        if !destinationExists {
            try consolidatePartialPredecessor(from: destination, to: predecessor)
        }
        _ = try GeoDatabase.validateExisting(at: predecessor)
        if destinationExists {
            try removeFamily(at: destination)
        }
        try moveFamily(from: predecessor, to: destination)
        try synchronizeDirectory(containing: destination)
        _ = try GeoDatabase.validateExisting(at: destination)
    }

    private static func rollback(
        destination: URL,
        predecessor: URL?,
        expectedOldMetadata: GeoDatabaseMetadata?,
        removePromoted: Bool
    ) throws {
        if removePromoted { try removeFamily(at: destination) }
        if let predecessor {
            try moveFamily(from: predecessor, to: destination)
        }
        try synchronizeDirectory(containing: destination)
        if let expectedOldMetadata {
            let restored = try GeoDatabase.validateExisting(at: destination)
            guard restored == expectedOldMetadata else {
                throw GeoDatabasePromotionError.rollbackFailed
            }
        } else if predecessor == nil {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw GeoDatabasePromotionError.rollbackFailed
            }
        }
    }

    private static func moveFamily(from source: URL, to destination: URL) throws {
        let suffixes = existingSuffixes(at: source)
        guard suffixes.contains("") else {
            throw GeoDatabasePromotionError.unsafeDatabaseFamily
        }
        try validateFamily(at: source)
        guard existingSuffixes(at: destination).isEmpty else {
            throw GeoDatabasePromotionError.unsafeDatabaseFamily
        }
        var moved: [String] = []
        do {
            for suffix in suffixes {
                try rename(source.path + suffix, destination.path + suffix)
                moved.append(suffix)
            }
        } catch let moveError {
            var rollbackFailed = false
            for suffix in moved.reversed() {
                do { try rename(destination.path + suffix, source.path + suffix) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw GeoDatabasePromotionError.rollbackFailed }
            throw moveError
        }
    }

    private static func consolidatePartialPredecessor(
        from destination: URL,
        to predecessor: URL
    ) throws {
        for suffix in familySuffixes.dropFirst()
        where FileManager.default.fileExists(atPath: destination.path + suffix) {
            guard !FileManager.default.fileExists(atPath: predecessor.path + suffix) else {
                throw GeoDatabasePromotionError.interruptedPromotionUnrecoverable
            }
            try rename(destination.path + suffix, predecessor.path + suffix)
        }
    }

    private static func removeFamily(at url: URL) throws {
        try validateFamily(at: url)
        for suffix in cleanupSuffixes
        where FileManager.default.fileExists(atPath: url.path + suffix) {
            let result = (url.path + suffix).withCString { Darwin.unlink($0) }
            guard result == 0 else { throw GeoDatabasePromotionError.ioFailure(errno) }
        }
    }

    private static func validateFamily(at url: URL) throws {
        for suffix in existingSuffixes(at: url) {
            var value = stat()
            let status = (url.path + suffix).withCString { Darwin.lstat($0, &value) }
            guard status == 0,
                  value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  value.st_uid == geteuid(),
                  value.st_nlink == 1 else {
                throw GeoDatabasePromotionError.unsafeDatabaseFamily
            }
        }
    }

    private static func setOwnerOnlyPermissions(at url: URL) throws {
        for suffix in existingSuffixes(at: url) {
            let status = (url.path + suffix).withCString {
                Darwin.chmod($0, mode_t(0o600))
            }
            guard status == 0 else { throw GeoDatabasePromotionError.ioFailure(errno) }
        }
    }

    private static func existingSuffixes(at url: URL) -> [String] {
        familySuffixes.filter { FileManager.default.fileExists(atPath: url.path + $0) }
    }

    private static func predecessorURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).predecessor"
        )
    }

    private static func rename(_ source: String, _ destination: String) throws {
        let status = source.withCString { sourcePath in
            destination.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else { throw GeoDatabasePromotionError.ioFailure(errno) }
    }

    private static func synchronizeDirectory(containing url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw GeoDatabasePromotionError.ioFailure(errno) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw GeoDatabasePromotionError.ioFailure(errno)
        }
    }

    private static func fingerprint(at url: URL) throws -> GeoDatabaseFingerprint {
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw GeoDatabasePromotionError.ioFailure(errno) }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw GeoDatabasePromotionError.ioFailure(errno)
        }
        try validateFingerprintMetadata(before, descriptor: descriptor)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: hashChunkBytes)
        var remaining = before.st_size
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, Int(remaining)))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw GeoDatabasePromotionError.promotedFileChanged
            }
            buffer.withUnsafeBytes {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: $0.baseAddress,
                    count: count
                ))
            }
            remaining -= Int64(count)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw GeoDatabasePromotionError.ioFailure(errno)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameSnapshot(before, after) else {
            throw GeoDatabasePromotionError.promotedFileChanged
        }
        var pathStatus = stat()
        let pathResult = url.path.withCString { Darwin.lstat($0, &pathStatus) }
        guard pathResult == 0, sameSnapshot(after, pathStatus) else {
            throw GeoDatabasePromotionError.promotedFileChanged
        }
        return GeoDatabaseFingerprint(
            device: before.st_dev,
            inode: before.st_ino,
            size: before.st_size,
            digest: Data(hasher.finalize())
        )
    }

    private static func validateFingerprintMetadata(
        _ value: stat,
        descriptor: Int32
    ) throws {
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & mode_t(0o777) == mode_t(0o600),
              value.st_size >= 0, value.st_size <= maximumDatabaseBytes else {
            throw GeoDatabasePromotionError.unsafeDatabaseFamily
        }
        var fileSystem = statfs()
        guard Darwin.fstatfs(descriptor, &fileSystem) == 0 else {
            throw GeoDatabasePromotionError.ioFailure(errno)
        }
        guard fileSystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw GeoDatabasePromotionError.unsafeDatabaseFamily
        }
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
            lhs.st_size == rhs.st_size && lhs.st_uid == rhs.st_uid &&
            lhs.st_gid == rhs.st_gid && lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func metadataMatches(
        _ lhs: GeoDatabaseMetadata,
        _ rhs: GeoDatabaseMetadata
    ) -> Bool {
        lhs.sourceName == rhs.sourceName &&
            lhs.sourceVersion == rhs.sourceVersion &&
            lhs.recordCount == rhs.recordCount &&
            datesMatch(lhs.sourceModifiedAt, rhs.sourceModifiedAt) &&
            abs(lhs.importedAt.timeIntervalSince1970 - rhs.importedAt.timeIntervalSince1970) < 0.001
    }

    private static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
        default: return false
        }
    }
}

private struct GeoDatabaseFingerprint {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let digest: Data

    func matchesPromoted(_ other: GeoDatabaseFingerprint) -> Bool {
        device == other.device && inode == other.inode &&
            size == other.size && digest == other.digest
    }
}
