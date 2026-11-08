import RiftCore
import Darwin
import Foundation

struct ApplicationCandidateProof: Sendable, Equatable {
    let url: URL
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let executableDevice: UInt64
    let executableInode: UInt64
    let executableSize: UInt64
    let executableModifiedSeconds: Int64
    let executableModifiedNanoseconds: Int64
}

final class ApplicationArtworkVerifier: @unchecked Sendable {
    /// Signature checks are expensive for large apps. A validated bundle is
    /// remembered against its file proof (bundle and executable device, inode,
    /// size and modification time), which changes whenever the app is replaced
    /// or re-signed, so the identity is only re-derived when the files change.
    private let memoLock = NSLock()
    private var memo: [String: (ApplicationCandidateProof, ProcessIdentity)] = [:]

    func forgetValidations() {
        memoLock.withLock { memo.removeAll() }
    }

    private let queue: OperationQueue = {
        let value = OperationQueue()
        value.name = "io.rift.firewall.application-artwork"
        value.qualityOfService = .utility
        value.maxConcurrentOperationCount = 2
        return value
    }()

    func select(
        candidates: [URL],
        identity: ProcessIdentity
    ) async -> ApplicationCandidateProof? {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                let matches = candidates.compactMap { self.proof(for: $0, identity: identity) }
                continuation.resume(returning: matches.count == 1 ? matches[0] : nil)
            }
        }
    }

    /// The one candidate signed by the same developer as `identity`, for a helper
    /// whose own bundle can't be looked up.
    func selectParent(
        candidates: [URL],
        of identity: ProcessIdentity
    ) async -> ApplicationCandidateProof? {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                let matches = candidates.compactMap { candidate -> ApplicationCandidateProof? in
                    guard let (proof, resolved) = self.validatedCandidate(candidate),
                          resolved.hasSameSigner(as: identity) else { return nil }
                    return proof
                }
                continuation.resume(returning: matches.count == 1 ? matches[0] : nil)
            }
        }
    }

    func index(candidates: [URL]) async -> [ProcessIdentity: [URL]] {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                var result: [ProcessIdentity: [URL]] = [:]
                for candidate in candidates {
                    guard let (proof, identity) = self.validatedCandidate(candidate) else { continue }
                    result[identity, default: []].append(proof.url)
                }
                continuation.resume(returning: result)
            }
        }
    }

    func revalidate(
        _ proof: ApplicationCandidateProof,
        identity: ProcessIdentity
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                // The file proof guards against the bundle changing between
                // selection and drawing; the identity was verified for this proof.
                continuation.resume(returning: Self.fileProof(proof.url) == proof)
            }
        }
    }

    private func proof(
        for candidate: URL,
        identity: ProcessIdentity
    ) -> ApplicationCandidateProof? {
        guard let (proof, resolved) = validatedCandidate(candidate), resolved == identity else {
            return nil
        }
        return proof
    }

    private func validatedCandidate(
        _ candidate: URL
    ) -> (ApplicationCandidateProof, ProcessIdentity)? {
        guard candidate.isFileURL, candidate.pathExtension.lowercased() == "app" else { return nil }
        let url = candidate.standardizedFileURL
        if let current = Self.fileProof(url),
           let remembered = memoLock.withLock({ memo[url.path] }), remembered.0 == current {
            return remembered
        }
        guard let validated = Self.validate(url) else {
            memoLock.withLock { memo[url.path] = nil }
            return nil
        }
        memoLock.withLock {
            if memo.count >= 512 { memo.removeAll() }
            memo[url.path] = validated
        }
        return validated
    }

    private static func validate(_ url: URL) -> (ApplicationCandidateProof, ProcessIdentity)? {
        guard url.resolvingSymlinksInPath().path == url.path,
              let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey,
              ]), values.isDirectory == true, values.isSymbolicLink != true,
              values.volumeIsLocal == true, FileManager.default.isReadableFile(atPath: url.path),
              let before = fileProof(url),
              let resolved = try? StaticCodeIdentityResolver.identity(at: url),
              let after = fileProof(url), before == after else { return nil }
        return (before, resolved)
    }

    private static func fileProof(_ url: URL) -> ApplicationCandidateProof? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              let executableURL = Bundle(url: url)?.executableURL?.standardizedFileURL,
              executableURL.resolvingSymlinksInPath().path == executableURL.path else { return nil }
        var executable = stat()
        guard lstat(executableURL.path, &executable) == 0,
              executable.st_mode & S_IFMT == S_IFREG else { return nil }
        return ApplicationCandidateProof(
            url: url,
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            executableDevice: UInt64(executable.st_dev),
            executableInode: UInt64(executable.st_ino),
            executableSize: UInt64(executable.st_size),
            executableModifiedSeconds: Int64(executable.st_mtimespec.tv_sec),
            executableModifiedNanoseconds: Int64(executable.st_mtimespec.tv_nsec)
        )
    }
}

extension ProcessIdentity {
    var signedCode: SignedCodeIdentity? {
        switch self {
        case .applePlatform(let value), .developerID(let value), .appStore(let value): value
        case .otherSigner, .adHoc, .unsigned: nil
        }
    }

    /// Same kind of signature from the same team, so one developer can't borrow
    /// another's app name and icon.
    func hasSameSigner(as other: ProcessIdentity) -> Bool {
        switch (self, other) {
        case (.developerID(let left), .developerID(let right)), (.appStore(let left), .appStore(let right)):
            left.teamIdentifier != nil && left.teamIdentifier == right.teamIdentifier
        case (.applePlatform, .applePlatform):
            true
        default:
            false
        }
    }
}
