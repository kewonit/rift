import CryptoKit
import Darwin
import Foundation

enum SecureExecutableHashError: Error, Sendable, Equatable {
    case invalidLimits
    case notFileURL
    case pathIsNotAbsolute
    case metadataFailed(Int32)
    case openFailed(Int32)
    case readFailed(Int32)
    case symbolicLink
    case notRegularFile
    case notExecutable
    case unsafePermissions
    case nonLocalFileSystem
    case fileTooLarge(maximum: Int64, actual: Int64)
    case fileChanged
    case cancelled
}

enum SecureExecutableHasher {
    static let maximumBytes = 64 * 1_024 * 1_024
    static let chunkBytes = 64 * 1_024

    static func hash(
        at url: URL,
        maximumBytes: Int = maximumBytes,
        chunkBytes: Int = chunkBytes,
        shouldCancel: @Sendable () -> Bool = { false },
        didReadChunk: (@Sendable (Int) -> Void)? = nil
    ) throws -> CodeDigest {
        guard maximumBytes > 0,
              maximumBytes <= Self.maximumBytes,
              chunkBytes > 0,
              chunkBytes <= Self.chunkBytes else {
            throw SecureExecutableHashError.invalidLimits
        }
        guard url.isFileURL else { throw SecureExecutableHashError.notFileURL }
        let path = url.standardized.path
        guard path.hasPrefix("/") else { throw SecureExecutableHashError.pathIsNotAbsolute }
        guard !shouldCancel() else { throw SecureExecutableHashError.cancelled }

        let pathBefore = try pathMetadata(path)
        try validate(pathBefore, maximumBytes: maximumBytes)
        let descriptor = try openNoFollow(path)
        defer { _ = Darwin.close(descriptor) }

        let descriptorBefore = try descriptorMetadata(descriptor)
        try validate(descriptorBefore, maximumBytes: maximumBytes)
        guard pathBefore.isSameFileAndState(as: descriptorBefore) else {
            throw SecureExecutableHashError.fileChanged
        }
        try requireLocalFileSystem(descriptor)

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        var remaining = descriptorBefore.size
        while remaining > 0 {
            guard !shouldCancel() else { throw SecureExecutableHashError.cancelled }
            let requested = min(Int64(chunkBytes), remaining)
            let count = try read(descriptor, into: &buffer, count: Int(requested))
            guard count > 0 else { throw SecureExecutableHashError.fileChanged }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: bytes.baseAddress,
                    count: count
                ))
            }
            didReadChunk?(count)
            remaining -= Int64(count)
        }
        guard !shouldCancel() else { throw SecureExecutableHashError.cancelled }

        let descriptorAfter = try descriptorMetadata(descriptor)
        guard descriptorBefore.isSameFileAndState(as: descriptorAfter) else {
            throw SecureExecutableHashError.fileChanged
        }
        let pathAfter: ExecutableFileMetadata
        do {
            pathAfter = try pathMetadata(path)
        } catch {
            throw SecureExecutableHashError.fileChanged
        }
        guard descriptorAfter.isSameFileAndState(as: pathAfter) else {
            throw SecureExecutableHashError.fileChanged
        }
        return try digest(Data(hasher.finalize()))
    }

    private static func openNoFollow(_ path: String) throws -> Int32 {
        let descriptor = path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw SecureExecutableHashError.symbolicLink }
            throw SecureExecutableHashError.openFailed(errno)
        }
        return descriptor
    }

    private static func read(
        _ descriptor: Int32,
        into buffer: inout [UInt8],
        count: Int
    ) throws -> Int {
        while true {
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, count)
            }
            if result >= 0 { return result }
            if errno != EINTR { throw SecureExecutableHashError.readFailed(errno) }
        }
    }

    private static func pathMetadata(_ path: String) throws -> ExecutableFileMetadata {
        var value = stat()
        let status = path.withCString { Darwin.lstat($0, &value) }
        guard status == 0 else { throw SecureExecutableHashError.metadataFailed(errno) }
        if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            throw SecureExecutableHashError.symbolicLink
        }
        return ExecutableFileMetadata(value)
    }

    private static func descriptorMetadata(_ descriptor: Int32) throws -> ExecutableFileMetadata {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw SecureExecutableHashError.metadataFailed(errno)
        }
        return ExecutableFileMetadata(value)
    }

    private static func validate(
        _ metadata: ExecutableFileMetadata,
        maximumBytes: Int
    ) throws {
        guard metadata.fileType == mode_t(S_IFREG) else {
            throw SecureExecutableHashError.notRegularFile
        }
        guard metadata.size >= 0 else { throw SecureExecutableHashError.fileChanged }
        guard metadata.size <= Int64(maximumBytes) else {
            throw SecureExecutableHashError.fileTooLarge(
                maximum: Int64(maximumBytes),
                actual: metadata.size
            )
        }
        let executeBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
        guard metadata.permissions & executeBits != 0 else {
            throw SecureExecutableHashError.notExecutable
        }
        let unsafeBits = mode_t(S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)
        guard metadata.permissions & unsafeBits == 0 else {
            throw SecureExecutableHashError.unsafePermissions
        }
        guard metadata.linkCount == 1 else {
            throw SecureExecutableHashError.unsafePermissions
        }
    }

    private static func requireLocalFileSystem(_ descriptor: Int32) throws {
        var value = statfs()
        guard Darwin.fstatfs(descriptor, &value) == 0 else {
            throw SecureExecutableHashError.metadataFailed(errno)
        }
        guard value.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw SecureExecutableHashError.nonLocalFileSystem
        }
    }

    private static func digest(_ data: Data) throws -> CodeDigest {
        try CodeDigest(
            hex: data.map { String(format: "%02x", $0) }.joined(),
            expectedByteCount: 32
        )
    }
}

private struct ExecutableFileMetadata {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let fileType: mode_t
    let permissions: mode_t
    let owner: uid_t
    let group: gid_t
    let linkCount: nlink_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        fileType = value.st_mode & mode_t(S_IFMT)
        permissions = value.st_mode & ~mode_t(S_IFMT)
        owner = value.st_uid
        group = value.st_gid
        linkCount = value.st_nlink
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }

    func isSameFileAndState(as other: ExecutableFileMetadata) -> Bool {
        device == other.device &&
            inode == other.inode &&
            size == other.size &&
            fileType == other.fileType &&
            permissions == other.permissions &&
            owner == other.owner &&
            group == other.group &&
            linkCount == other.linkCount &&
            modifiedSeconds == other.modifiedSeconds &&
            modifiedNanoseconds == other.modifiedNanoseconds &&
            changedSeconds == other.changedSeconds &&
            changedNanoseconds == other.changedNanoseconds
    }
}
