import Darwin
import Foundation

enum SecureDirectoryError: Error, Sendable, Equatable {
    case invalidName
    case unsafeRoot
    case openFailed(Int32)
    case notRegularFile
    case oversizedFile(Int)
    case shortWrite
}

struct SecureDirectory: Sendable {
    let url: URL
    let wasCreated: Bool

    init(url: URL) throws {
        self.url = url
        self.wasCreated = try Self.ensureSafeDirectory(url)
    }

    func contains(_ name: String) throws -> Bool {
        try validate(name)
        return try withDirectoryDescriptor { descriptor in
            var status = stat()
            if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
                guard status.st_mode & S_IFMT != S_IFLNK else { throw SecureDirectoryError.unsafeRoot }
                return true
            }
            if errno == ENOENT { return false }
            throw SecureDirectoryError.openFailed(errno)
        }
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data? {
        try validate(name)
        return try withDirectoryDescriptor { directory in
            let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if descriptor < 0 {
                if errno == ENOENT { return nil }
                throw SecureDirectoryError.openFailed(errno)
            }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw SecureDirectoryError.openFailed(errno) }
            guard status.st_mode & S_IFMT == S_IFREG else { throw SecureDirectoryError.notRegularFile }
            let count = Int(status.st_size)
            guard count <= maximumBytes else { throw SecureDirectoryError.oversizedFile(count) }
            var data = Data(count: count)
            let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var total = 0
                while total < count {
                    let result = Darwin.read(descriptor, base.advanced(by: total), count - total)
                    if result <= 0 { return result < 0 ? -1 : total }
                    total += result
                }
                return total
            }
            guard bytesRead == count else { throw SecureDirectoryError.openFailed(errno) }
            return data
        }
    }

    func writeAtomically(_ data: Data, to name: String) throws {
        try validate(name)
        try withDirectoryDescriptor { directory in
            let (temporary, descriptor) = try createTemporaryFile(in: directory)
            var shouldDelete = true
            defer {
                close(descriptor)
                if shouldDelete { unlinkat(directory, temporary, 0) }
            }
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var total = 0
                while total < buffer.count {
                    let result = Darwin.write(descriptor, base.advanced(by: total), buffer.count - total)
                    if result <= 0 { return -1 }
                    total += result
                }
                return total
            }
            guard written == data.count else { throw SecureDirectoryError.shortWrite }
            guard fsync(descriptor) == 0 else { throw SecureDirectoryError.openFailed(errno) }
            guard renameat(directory, temporary, directory, name) == 0 else {
                throw SecureDirectoryError.openFailed(errno)
            }
            shouldDelete = false
            guard fsync(directory) == 0 else { throw SecureDirectoryError.openFailed(errno) }
        }
    }

    func withExclusiveLock<Value>(_ body: () throws -> Value) throws -> Value {
        try withDirectoryDescriptor { directory in
            let descriptor = openat(
                directory,
                ".root-policy.lock",
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { throw SecureDirectoryError.openFailed(errno) }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw SecureDirectoryError.openFailed(errno)
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw SecureDirectoryError.notRegularFile
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw SecureDirectoryError.openFailed(errno)
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { throw SecureDirectoryError.openFailed(errno) }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    func remove(_ name: String) throws {
        try validate(name)
        try withDirectoryDescriptor { directory in
            if unlinkat(directory, name, 0) != 0, errno != ENOENT {
                throw SecureDirectoryError.openFailed(errno)
            }
            guard fsync(directory) == 0 else { throw SecureDirectoryError.openFailed(errno) }
        }
    }

    private func withDirectoryDescriptor<Value>(_ body: (Int32) throws -> Value) throws -> Value {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SecureDirectoryError.openFailed(errno) }
        defer { close(descriptor) }
        return try body(descriptor)
    }

    private func createTemporaryFile(in directory: Int32) throws -> (name: String, descriptor: Int32) {
        for _ in 0..<8 {
            let name = ".tmp-\(UUID().uuidString.lowercased())"
            let descriptor = openat(
                directory,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            if descriptor >= 0 { return (name, descriptor) }
            guard errno == EEXIST else { throw SecureDirectoryError.openFailed(errno) }
        }
        throw SecureDirectoryError.openFailed(EEXIST)
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SecureDirectoryError.invalidName
        }
    }

    private static func ensureSafeDirectory(_ url: URL) throws -> Bool {
        var status = stat()
        let created: Bool
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else { throw SecureDirectoryError.unsafeRoot }
            created = false
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            created = true
        } else {
            throw SecureDirectoryError.openFailed(errno)
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else { throw SecureDirectoryError.openFailed(errno) }
        return created
    }
}
