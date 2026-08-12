import Darwin
import Foundation

public enum ProcessInstanceLockError: Error, Sendable, Equatable {
    case invalidPath
    case invalidName
    case unsafeDirectory
    case unsafeLockFile
    case ioFailure(Int32)
}

public final class ProcessInstanceLock: @unchecked Sendable {
    public enum Acquisition: Sendable {
        case acquired(ProcessInstanceLock)
        case unavailable
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    public static func acquire(
        in directoryURL: URL,
        name: String = "instance.lock"
    ) throws -> Acquisition {
        try validate(directoryURL: directoryURL, name: name)
        try ensureSecureDirectory(at: directoryURL)
        let directory = try openDirectory(at: directoryURL)
        defer { _ = Darwin.close(directory) }
        let descriptor = try openLockFile(in: directory, name: name)
        do {
            try validateLockFile(descriptor, in: directory, name: name)
            while true {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    return .acquired(ProcessInstanceLock(descriptor: descriptor))
                }
                let code = errno
                if code == EINTR { continue }
                if code == EWOULDBLOCK || code == EAGAIN {
                    _ = Darwin.close(descriptor)
                    return .unavailable
                }
                throw ProcessInstanceLockError.ioFailure(code)
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validate(directoryURL: URL, name: String) throws {
        guard directoryURL.isFileURL,
              directoryURL.path.hasPrefix("/"),
              !directoryURL.path.utf8.contains(0),
              directoryURL.path.utf8.count < Int(PATH_MAX) else {
            throw ProcessInstanceLockError.invalidPath
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), name.utf8.count <= Int(NAME_MAX) else {
            throw ProcessInstanceLockError.invalidName
        }
    }

    private static func ensureSecureDirectory(at url: URL) throws {
        let created = url.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        if created != 0, errno != EEXIST {
            throw ProcessInstanceLockError.ioFailure(errno)
        }
        var metadata = stat()
        guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw ProcessInstanceLockError.ioFailure(errno)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw ProcessInstanceLockError.unsafeDirectory
        }
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw ProcessInstanceLockError.unsafeDirectory
            }
            throw ProcessInstanceLockError.ioFailure(errno)
        }
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              url.path.withCString({ Darwin.lstat($0, &named) }) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw ProcessInstanceLockError.ioFailure(code)
        }
        guard opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              opened.st_uid == geteuid(),
              opened.st_mode & mode_t(0o777) == mode_t(0o700),
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            _ = Darwin.close(descriptor)
            throw ProcessInstanceLockError.unsafeDirectory
        }
        var fileSystem = statfs()
        guard Darwin.fstatfs(descriptor, &fileSystem) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw ProcessInstanceLockError.ioFailure(code)
        }
        guard fileSystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            _ = Darwin.close(descriptor)
            throw ProcessInstanceLockError.unsafeDirectory
        }
        return descriptor
    }

    private static func openLockFile(in directory: Int32, name: String) throws -> Int32 {
        var descriptor = name.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        if descriptor < 0, errno == EEXIST {
            descriptor = name.withCString {
                Darwin.openat(directory, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ProcessInstanceLockError.unsafeLockFile }
            throw ProcessInstanceLockError.ioFailure(errno)
        }
        return descriptor
    }

    private static func validateLockFile(
        _ descriptor: Int32,
        in directory: Int32,
        name: String
    ) throws {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            throw ProcessInstanceLockError.ioFailure(errno)
        }
        guard opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_uid == geteuid(), opened.st_nlink == 1,
              opened.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw ProcessInstanceLockError.unsafeLockFile
        }
        var named = stat()
        let result = name.withCString {
            Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw ProcessInstanceLockError.ioFailure(errno) }
        guard named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw ProcessInstanceLockError.unsafeLockFile
        }
    }
}
