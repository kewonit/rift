import Darwin
import Foundation

public enum SecureArchiveFileError: Error, Sendable, Equatable {
    case invalidPath
    case symbolicLink
    case notRegularFile
    case wrongOwner
    case nonLocalFile
    case oversized
    case fileChangedWhileReading
    case ownerOnlyPermissionsUnsupported
    case destinationChanged
    case ioFailure(Int32)
}

public enum SecureArchiveFile {
    private static let readPageBytes = 64 * 1_024

    public static func readSnapshot(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw SecureArchiveFileError.oversized }
        let descriptor = try openReadDescriptor(at: url)
        var handle: FileHandle?
        do {
            let original = try status(descriptor)
            try validateInput(original, descriptor: descriptor, maximumBytes: maximumBytes)
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            handle = input
            var data = Data()
            data.reserveCapacity(Int(original.st_size))
            while true {
                let remaining = maximumBytes - data.count
                let request = remaining >= readPageBytes ? readPageBytes : remaining + 1
                guard let chunk = try input.read(upToCount: request), !chunk.isEmpty else { break }
                guard chunk.count <= remaining else { throw SecureArchiveFileError.oversized }
                data.append(chunk)
            }
            let current = try status(descriptor)
            guard sameSnapshot(original, current), data.count == Int(original.st_size) else {
                throw SecureArchiveFileError.fileChangedWhileReading
            }
            try input.close()
            handle = nil
            return data
        } catch {
            if let handle { try? handle.close() }
            else { Darwin.close(descriptor) }
            throw error
        }
    }

    public static func writeReplacing(_ data: Data, at url: URL) throws {
        try writeReplacing(data, at: url, permissionValidator: ownerOnly)
    }

    static func writeReplacing(
        _ data: Data,
        at url: URL,
        permissionValidator: (stat) -> Bool,
        beforePromotion: () throws -> Void = {}
    ) throws {
        let destinationName = url.lastPathComponent
        guard url.isFileURL, !destinationName.isEmpty,
              destinationName != ".", destinationName != "..",
              !destinationName.utf8.contains(0) else {
            throw SecureArchiveFileError.invalidPath
        }
        let directoryURL = url.deletingLastPathComponent()
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else { throw openError(errno) }
        defer { Darwin.close(directory) }
        try requireLocalFileSystem(directory)
        let originalDestination = try destinationStatus(
            directory: directory,
            name: destinationName
        )
        if let originalDestination {
            try validateOwnedRegularFile(originalDestination)
        }

        let temporaryName = ".abyss-export-\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString {
            openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw openError(errno) }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { break }
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else { throw SecureArchiveFileError.ioFailure(errno) }
                offset += written
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            if errno == ENOTSUP || errno == EOPNOTSUPP || errno == EPERM {
                throw SecureArchiveFileError.ownerOnlyPermissionsUnsupported
            }
            throw SecureArchiveFileError.ioFailure(errno)
        }
        guard fsync(descriptor) == 0 else { throw SecureArchiveFileError.ioFailure(errno) }
        let staged = try status(descriptor)
        guard permissionValidator(staged) else {
            throw SecureArchiveFileError.ownerOnlyPermissionsUnsupported
        }
        let stagedPath = try requirePathStatus(
            directory: directory,
            name: temporaryName
        )
        guard sameFile(staged, stagedPath) else {
            throw SecureArchiveFileError.destinationChanged
        }
        try verifyDestinationUnchanged(
            originalDestination,
            directory: directory,
            name: destinationName
        )
        try beforePromotion()
        try verifyDestinationUnchanged(
            originalDestination,
            directory: directory,
            name: destinationName
        )
        try promote(
            temporaryName: temporaryName,
            destinationName: destinationName,
            originalDestination: originalDestination,
            directory: directory,
            removeTemporary: &removeTemporary
        )
    }

    private static func openReadDescriptor(at url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.path.utf8.contains(0), url.path.utf8.count < Int(PATH_MAX) else {
            throw SecureArchiveFileError.invalidPath
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw openError(errno) }
        return descriptor
    }

    private static func validateInput(
        _ value: stat,
        descriptor: Int32,
        maximumBytes: Int
    ) throws {
        try validateOwnedRegularFile(value)
        try requireLocalFileSystem(descriptor)
        guard value.st_size >= 0,
              UInt64(value.st_size) <= UInt64(maximumBytes),
              UInt64(value.st_size) <= UInt64(Int.max) else {
            throw SecureArchiveFileError.oversized
        }
    }

    private static func validateOwnedRegularFile(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG else {
            if value.st_mode & S_IFMT == S_IFLNK { throw SecureArchiveFileError.symbolicLink }
            throw SecureArchiveFileError.notRegularFile
        }
        guard value.st_uid == geteuid() else { throw SecureArchiveFileError.wrongOwner }
    }

    private static func requireLocalFileSystem(_ descriptor: Int32) throws {
        var value = statfs()
        guard fstatfs(descriptor, &value) == 0 else {
            throw SecureArchiveFileError.ioFailure(errno)
        }
        guard value.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw SecureArchiveFileError.nonLocalFile
        }
    }

    private static func status(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw SecureArchiveFileError.ioFailure(errno)
        }
        return value
    }

    private static func destinationStatus(directory: Int32, name: String) throws -> stat? {
        var value = stat()
        let result = name.withCString { fstatat(directory, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { return value }
        if errno == ENOENT { return nil }
        throw SecureArchiveFileError.ioFailure(errno)
    }

    private static func requirePathStatus(directory: Int32, name: String) throws -> stat {
        guard let value = try destinationStatus(directory: directory, name: name) else {
            throw SecureArchiveFileError.destinationChanged
        }
        return value
    }

    private static func verifyDestinationUnchanged(
        _ original: stat?,
        directory: Int32,
        name: String
    ) throws {
        let current = try destinationStatus(directory: directory, name: name)
        switch (original, current) {
        case (nil, nil): return
        case (.some(let original), .some(let current)) where sameSnapshot(original, current): return
        default: throw SecureArchiveFileError.destinationChanged
        }
    }

    private static func promote(
        temporaryName: String,
        destinationName: String,
        originalDestination: stat?,
        directory: Int32,
        removeTemporary: inout Bool
    ) throws {
        guard let originalDestination else {
            let result = rename(
                temporaryName: temporaryName,
                destinationName: destinationName,
                directory: directory,
                flags: UInt32(RENAME_EXCL)
            )
            guard result == 0 else {
                if errno == EEXIST || errno == ENOTEMPTY {
                    throw SecureArchiveFileError.destinationChanged
                }
                throw SecureArchiveFileError.ioFailure(errno)
            }
            removeTemporary = false
            guard fsync(directory) == 0 else {
                throw SecureArchiveFileError.ioFailure(errno)
            }
            return
        }

        let swapped = rename(
            temporaryName: temporaryName,
            destinationName: destinationName,
            directory: directory,
            flags: UInt32(RENAME_SWAP)
        )
        guard swapped == 0 else {
            if errno == ENOENT { throw SecureArchiveFileError.destinationChanged }
            throw SecureArchiveFileError.ioFailure(errno)
        }
        // The old destination now occupies the private temporary name. Never
        // let the generic cleanup path remove it unless a verified rollback
        // has put our staged bytes back there.
        removeTemporary = false

        do {
            let displaced = try requirePathStatus(directory: directory, name: temporaryName)
            guard sameRenamedSnapshot(originalDestination, displaced) else {
                throw SecureArchiveFileError.destinationChanged
            }
            guard fsync(directory) == 0 else {
                throw SecureArchiveFileError.ioFailure(errno)
            }
            let removed = temporaryName.withCString { unlinkat(directory, $0, 0) }
            guard removed == 0 else { throw SecureArchiveFileError.ioFailure(errno) }
            // The replacement name is already durable from the first fsync.
            // This second fsync makes removal of the displaced file durable.
            guard fsync(directory) == 0 else {
                throw SecureArchiveFileError.ioFailure(errno)
            }
        } catch {
            guard (try? destinationStatus(directory: directory, name: temporaryName)) != nil else {
                throw error
            }
            let rolledBack = rename(
                temporaryName: temporaryName,
                destinationName: destinationName,
                directory: directory,
                flags: UInt32(RENAME_SWAP)
            )
            guard rolledBack == 0 else {
                throw SecureArchiveFileError.ioFailure(errno)
            }
            // The original destination is restored; the temporary name once
            // again contains only our new bytes and is safe to remove.
            removeTemporary = true
            guard fsync(directory) == 0 else {
                removeTemporary = false
                throw SecureArchiveFileError.ioFailure(errno)
            }
            throw error
        }
    }

    private static func rename(
        temporaryName: String,
        destinationName: String,
        directory: Int32,
        flags: UInt32
    ) -> Int32 {
        temporaryName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(directory, source, directory, destination, flags)
            }
        }
    }

    private static func ownerOnly(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG
            && value.st_uid == geteuid()
            && value.st_mode & 0o777 == 0o600
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFile(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameRenamedSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFile(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func openError(_ code: Int32) -> SecureArchiveFileError {
        code == ELOOP ? .symbolicLink : .ioFailure(code)
    }
}
