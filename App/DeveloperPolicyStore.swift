import Darwin
import Foundation
import RiftControl
import RiftCore

/// The Internet Access Policy an installed app ships in its own bundle, for
/// the alert and the Map inspector. Rift reads it from disk only, never
/// looks anything up, and uses it only for apps signed with a Developer ID or
/// from the Mac App Store, so the words come from a developer Apple
/// identified. Policies for Apple's own software aren't read: those that
/// exist were written by other firewall makers, not by Apple.
@MainActor
final class DeveloperPolicyStore {
    static let shared = DeveloperPolicyStore()
    private static let maximumEntries = 64

    private struct Entry {
        let policy: InternetAccessPolicy?
        let expiresAt: Date
    }

    private var cache: [ProcessIdentity: Entry] = [:]
    private var inFlight: [ProcessIdentity: Task<InternetAccessPolicy?, Never>] = [:]

    /// Nil when the app ships no policy Rift can trust. A policy Rift read is
    /// remembered for an hour, so an updated app is read again.
    func policy(for identity: ProcessIdentity?, artworkStore: ApplicationArtworkStore) async -> InternetAccessPolicy? {
        guard let identity, Self.isEligible(identity) else { return nil }
        if let entry = cache[identity], entry.expiresAt > Date() { return entry.policy }
        if let task = inFlight[identity] { return await task.value }
        let task = Task<InternetAccessPolicy?, Never> {
            guard let bundle = await artworkStore.verifiedBundle(for: identity) else { return nil }
            return await Task.detached(priority: .utility) {
                DeveloperPolicyReader.read(bundle: bundle.url, identity: identity, isParent: bundle.isParent)
            }.value
        }
        inFlight[identity] = task
        let policy = await task.value
        inFlight[identity] = nil
        if cache.count >= Self.maximumEntries { cache.removeAll() }
        cache[identity] = Entry(policy: policy, expiresAt: Date().addingTimeInterval(policy == nil ? 300 : 3_600))
        return policy
    }

    private static func isEligible(_ identity: ProcessIdentity) -> Bool {
        switch identity {
        case .developerID, .appStore: true
        case .applePlatform, .otherSigner, .adHoc, .unsigned: false
        }
    }
}

/// Reads a bundle's policy file and its translation, then checks the app's
/// signature, then checks the files didn't change in between. The signature
/// seals every file in the bundle's resources, so the words shown are the
/// ones the developer signed.
enum DeveloperPolicyReader {
    private struct Snapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modified: timespec
        let changed: timespec

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private struct ReadFile {
        let url: URL
        let data: Data
        let snapshot: Snapshot
    }

    static func read(bundle: URL, identity: ProcessIdentity, isParent: Bool) -> InternetAccessPolicy? {
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let file = InternetAccessPolicy.fileNames.lazy.compactMap({
            readFile(resources.appendingPathComponent($0))
        }).first else { return nil }
        let strings = localizedStrings(in: resources)
        guard let resolved = try? StaticCodeIdentityResolver.identity(at: bundle),
              isParent ? resolved.hasSameSigner(as: identity) : resolved == identity,
              snapshot(file.url) == file.snapshot,
              strings.map({ snapshot($0.url) == $0.snapshot }) ?? true else { return nil }
        let info = Bundle(url: bundle)
        let name = (info?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (info?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        return try? InternetAccessPolicy.decode(
            file.data,
            strings: strings.map { InternetAccessPolicy.strings($0.data) } ?? [:],
            appName: name.map { String($0.prefix(64)) }
        )
    }

    /// The translation for the person's preferred language, if the app has one.
    private static func localizedStrings(in resources: URL) -> ReadFile? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { return nil }
        let languages = names.prefix(500).filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }
        let available = languages.filter {
            FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("\($0).lproj/\(InternetAccessPolicy.stringsFileName)").path
            )
        }
        guard let language = Bundle.preferredLocalizations(from: available).first else { return nil }
        return readFile(resources.appendingPathComponent("\(language).lproj/\(InternetAccessPolicy.stringsFileName)"))
    }

    /// A regular file, not a link, no larger than a policy can be.
    private static func readFile(_ url: URL) -> ReadFile? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0, status.st_size <= Int64(InternetAccessPolicy.maximumBytes) else { return nil }
        var data = Data(count: Int(status.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, Int(status.st_size)) }
        guard count == Int(status.st_size) else { return nil }
        return ReadFile(url: url, data: data, snapshot: snapshot(status))
    }

    private static func snapshot(_ url: URL) -> Snapshot? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return snapshot(status)
    }

    private static func snapshot(_ status: stat) -> Snapshot {
        Snapshot(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
            modified: status.st_mtimespec, changed: status.st_ctimespec
        )
    }
}
