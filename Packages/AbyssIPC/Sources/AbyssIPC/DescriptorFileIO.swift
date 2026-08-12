import Darwin
import Foundation

public enum DescriptorFileError: Error, Sendable, Equatable {
    case invalidPath
    case notRegularFile
    case oversized
    case alreadyExists
    case wrongOwner
    case unsafePermissions
    case unexpectedEndOfFile
    case fileChangedWhileReading
    case destinationChanged
    case ioFailure(Int32)
}

public enum DescriptorFileAccess {
    public static func beginRead(
        path: String,
        maximumBytes: Int
    ) throws -> DescriptorInputFile {
        try DescriptorInputFile(path: path, maximumBytes: maximumBytes)
    }

    public static func beginCreate(path: String) throws -> DescriptorOutputFile {
        try DescriptorOutputFile(path: path)
    }

    fileprivate static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"),
              !path.utf8.contains(0),
              path.utf8.count < Int(PATH_MAX) else {
            throw DescriptorFileError.invalidPath
        }
    }

    fileprivate static func openDescriptor(path: String, flags: Int32) throws -> Int32 {
        try validatePath(path)
        let descriptor = path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw DescriptorFileError.alreadyExists }
            throw DescriptorFileError.ioFailure(errno)
        }
        return descriptor
    }

    fileprivate static func createDescriptor(path: String) throws -> Int32 {
        try validatePath(path)
        let descriptor = path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw DescriptorFileError.alreadyExists }
            throw DescriptorFileError.ioFailure(errno)
        }
        return descriptor
    }

    fileprivate static func status(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw DescriptorFileError.ioFailure(errno)
        }
        return value
    }

    fileprivate static func pathStatus(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw DescriptorFileError.ioFailure(errno)
        }
        return value
    }

    fileprivate static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}

public final class DescriptorInputFile {
    public let totalBytes: Int

    private let original: stat
    private var handle: FileHandle?
    private var bytesRead = 0

    fileprivate init(path: String, maximumBytes: Int) throws {
        guard maximumBytes >= 0 else { throw DescriptorFileError.oversized }
        let descriptor = try DescriptorFileAccess.openDescriptor(
            path: path,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        do {
            let metadata = try DescriptorFileAccess.status(descriptor)
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw DescriptorFileError.notRegularFile
            }
            guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
                throw DescriptorFileError.oversized
            }
            original = metadata
            totalBytes = Int(metadata.st_size)
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public func readChunk(maximumBytes: Int) throws -> Data {
        guard let handle, maximumBytes > 0, bytesRead < totalBytes else {
            throw DescriptorFileError.invalidPath
        }
        let count = min(maximumBytes, totalBytes - bytesRead)
        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
            throw DescriptorFileError.unexpectedEndOfFile
        }
        bytesRead += chunk.count
        return chunk
    }

    public func finish() throws {
        guard let handle, bytesRead == totalBytes else {
            throw DescriptorFileError.unexpectedEndOfFile
        }
        let extra = try handle.read(upToCount: 1)
        let current = try DescriptorFileAccess.status(handle.fileDescriptor)
        try handle.close()
        self.handle = nil
        guard extra?.isEmpty != false,
              DescriptorFileAccess.sameFile(original, current),
              current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw DescriptorFileError.fileChangedWhileReading
        }
    }

    deinit { try? handle?.close() }
}

public final class DescriptorOutputFile {
    private let path: String
    private let original: stat
    private var handle: FileHandle?
    private var completed = false

    fileprivate init(path: String) throws {
        self.path = path
        let descriptor = try DescriptorFileAccess.createDescriptor(path: path)
        do {
            let metadata = try DescriptorFileAccess.status(descriptor)
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw DescriptorFileError.notRegularFile
            }
            guard metadata.st_uid == geteuid() else { throw DescriptorFileError.wrongOwner }
            guard metadata.st_mode & 0o077 == 0 else {
                throw DescriptorFileError.unsafePermissions
            }
            original = metadata
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            _ = path.withCString { Darwin.unlink($0) }
            throw error
        }
    }

    public func append(_ data: Data) throws {
        guard let handle, !completed else { throw DescriptorFileError.invalidPath }
        try handle.write(contentsOf: data)
    }

    public func finish() throws {
        guard let handle, !completed else { throw DescriptorFileError.invalidPath }
        try handle.synchronize()
        let descriptorMetadata = try DescriptorFileAccess.status(handle.fileDescriptor)
        let pathMetadata = try DescriptorFileAccess.pathStatus(path)
        guard DescriptorFileAccess.sameFile(original, descriptorMetadata),
              DescriptorFileAccess.sameFile(original, pathMetadata),
              (descriptorMetadata.st_mode & S_IFMT) == S_IFREG,
              descriptorMetadata.st_uid == geteuid(),
              descriptorMetadata.st_mode & 0o077 == 0 else {
            throw DescriptorFileError.destinationChanged
        }
        try handle.close()
        self.handle = nil
        completed = true
    }

    public func abort() {
        guard !completed else { return }
        try? handle?.close()
        handle = nil
        if let current = try? DescriptorFileAccess.pathStatus(path),
           DescriptorFileAccess.sameFile(original, current) {
            _ = path.withCString { Darwin.unlink($0) }
        }
        completed = true
    }

    deinit { abort() }
}
