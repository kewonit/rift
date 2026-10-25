import RiftCore
import AppKit
import Darwin
import Foundation

struct ApplicationArtwork {
    let image: NSImage
    let displayName: String?
}

@MainActor
final class ApplicationArtworkStore {
    static let maximumCandidates = 16
    static let maximumRunningApplications = 128
    static let maximumPending = 64
    static let maximumEntries = 128
    static let maximumCost = 16 * 1_024 * 1_024

    private struct CacheEntry {
        let artwork: ApplicationArtwork?
        let expiresAt: Date
        let cost: Int
        var lastAccess: UInt64
    }

    private let verifier = ApplicationArtworkVerifier()
    private var cache: [ProcessIdentity: CacheEntry] = [:]
    private var inFlight: [ProcessIdentity: Task<ApplicationArtwork?, Never>] = [:]
    private var cacheCost = 0
    private var accessCounter: UInt64 = 0
    private var runningIndex: [ProcessIdentity: [URL]]?
    private var runningIndexTask: Task<[ProcessIdentity: [URL]], Never>?
    private var workspaceGeneration: UInt64 = 0
#if DEBUG
    private static let fixtureCanary = "RIFT_UI_FIXTURE_ARTWORK_ONLY_5C8E1D42"
    private static let fixtureBundleIdentifiers = [
        "Safari": "com.apple.Safari",
        "Google Chrome": "com.google.Chrome",
        "Mail": "com.apple.mail",
        "Music": "com.apple.Music",
        "App Store": "com.apple.AppStore",
        "FaceTime": "com.apple.FaceTime",
        "Maps": "com.apple.Maps",
        "Calendar": "com.apple.iCal",
        "Messages": "com.apple.MobileSMS",
        "Notes": "com.apple.Notes",
        "Photos": "com.apple.Photos",
        "Terminal": "com.apple.Terminal",
        "Preview": "com.apple.Preview",
        "Weather": "com.apple.weather",
        "Xcode": "com.apple.dt.Xcode",
        "Books": "com.apple.iBooksX",
        "Podcasts": "com.apple.podcasts",
        "TV": "com.apple.TV",
    ]
    private let usesFixtureArtwork: Bool
#endif

#if DEBUG
    init(uiFixture: Bool) {
        usesFixtureArtwork = uiFixture
        if !uiFixture { observeWorkspace() }
    }
#else
    init() {
        observeWorkspace()
    }
#endif

    func artwork(for identity: ProcessIdentity) async -> ApplicationArtwork? {
#if DEBUG
        if usesFixtureArtwork { return fixtureArtwork(for: identity) }
#endif
        if let cached = cachedArtwork(for: identity) { return cached }
        if let task = inFlight[identity] { return await task.value }
        guard inFlight.count < Self.maximumPending else { return nil }
        let candidates = await candidateURLs(for: identity)
        guard !candidates.isEmpty else {
            insert(nil, for: identity)
            return nil
        }
        let task: Task<ApplicationArtwork?, Never> = Task { [verifier] in
            guard let proof = await verifier.select(
                candidates: candidates,
                identity: identity
            ), let artwork = renderArtwork(at: proof.url),
                  await verifier.revalidate(proof, identity: identity) else { return nil }
            return artwork
        }
        inFlight[identity] = task
        let artwork = await task.value
        if cache[identity] == nil { insert(artwork, for: identity) }
        inFlight.removeValue(forKey: identity)
        return artwork
    }

    func revealApplication(for identity: ProcessIdentity) async -> Bool {
#if DEBUG
        if usesFixtureArtwork { return false }
#endif
        let candidates = await candidateURLs(for: identity)
        guard !candidates.isEmpty,
              let proof = await verifier.select(candidates: candidates, identity: identity),
              await verifier.revalidate(proof, identity: identity) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([proof.url])
        return true
    }

    private func candidateURLs(for identity: ProcessIdentity) async -> [URL] {
        let workspace = NSWorkspace.shared
        var candidates = await indexedRunningApplications(for: identity)
        if case .unsigned(let path, _) = identity,
           let enclosing = enclosingApplication(forExecutablePath: path) {
            candidates.insert(enclosing, at: 0)
        }
        if let identifier = lookupIdentifier(identity), isSafeLookup(identifier) {
            candidates.append(contentsOf: workspace.urlsForApplications(withBundleIdentifier: identifier))
        }
        var seen: Set<String> = []
        let distinct = candidates.compactMap { url -> URL? in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return url
        }
        guard distinct.count <= Self.maximumCandidates else { return [] }
        return distinct
    }

    private func indexedRunningApplications(for identity: ProcessIdentity) async -> [URL] {
        if let runningIndex { return runningIndex[identity] ?? [] }
        if let runningIndexTask {
            return await runningIndexTask.value[identity] ?? []
        }
        var seen: Set<String> = []
        let candidates = NSWorkspace.shared.runningApplications.compactMap { application -> URL? in
            guard let url = application.bundleURL else { return nil }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return url
        }
        guard candidates.count <= Self.maximumRunningApplications else { return [] }
        let generation = workspaceGeneration
        let task = Task { [verifier] in
            await verifier.index(candidates: candidates)
        }
        runningIndexTask = task
        let result = await task.value
        runningIndexTask = nil
        guard generation == workspaceGeneration else { return [] }
        runningIndex = result
        return result[identity] ?? []
    }

    private func enclosingApplication(forExecutablePath path: String) -> URL? {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if candidate.pathExtension.lowercased() == "app" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return nil
    }

    private func lookupIdentifier(_ identity: ProcessIdentity) -> String? {
        switch identity {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            value.signingIdentifier
        case .otherSigner(_, let identifier): identifier
        case .adHoc, .unsigned: nil
        }
    }

    private func isSafeLookup(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "-")
        }
    }

    private func cachedArtwork(for identity: ProcessIdentity) -> ApplicationArtwork?? {
        guard var entry = cache[identity] else { return nil }
        guard entry.expiresAt > Date() else {
            cacheCost -= entry.cost
            cache.removeValue(forKey: identity)
            return nil
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[identity] = entry
        return .some(entry.artwork)
    }

    private func insert(_ artwork: ApplicationArtwork?, for identity: ProcessIdentity) {
        if let previous = cache.removeValue(forKey: identity) { cacheCost -= previous.cost }
        accessCounter &+= 1
        let cost = artwork == nil ? 1 : 128 * 128 * 4
        cache[identity] = CacheEntry(
            artwork: artwork,
            expiresAt: Date().addingTimeInterval(artwork == nil ? 30 : 300),
            cost: cost,
            lastAccess: accessCounter
        )
        cacheCost += cost
        while cache.count > Self.maximumEntries || cacheCost > Self.maximumCost {
            guard let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
                break
            }
            cacheCost -= oldest.value.cost
            cache.removeValue(forKey: oldest.key)
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearCache() }
            }
        }
    }

    private func clearCache() {
        cache.removeAll(keepingCapacity: true)
        cacheCost = 0
        runningIndex = nil
        runningIndexTask?.cancel()
        runningIndexTask = nil
        workspaceGeneration &+= 1
    }

    private func renderArtwork(at url: URL) -> ApplicationArtwork? {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 128,
            pixelsHigh: 128,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(representation)
        let bundle = Bundle(url: url)
        let rawName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = rawName.map { DisplaySanitizer.plainText($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return ApplicationArtwork(image: image, displayName: name)
    }

#if DEBUG
    private func fixtureArtwork(for identity: ProcessIdentity) -> ApplicationArtwork? {
        let label = lookupIdentifier(identity) ?? "App"
        if let bundleIdentifier = Self.fixtureBundleIdentifiers[label] {
            let candidates = NSWorkspace.shared.urlsForApplications(
                withBundleIdentifier: bundleIdentifier
            )
            let distinct = Dictionary(grouping: candidates, by: { $0.standardizedFileURL.path })
                .compactMap { $0.value.first }
            if distinct.count == 1, let artwork = renderArtwork(at: distinct[0]) {
                return artwork
            }
        }
        let seed = (Self.fixtureCanary + label).unicodeScalars.reduce(0) {
            ($0 &* 33 &+ Int($1.value)) % 360
        }
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedHue: CGFloat(seed) / 360, saturation: 0.72, brightness: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 118, height: 118), xRadius: 25, yRadius: 25).fill()
        let initial = String(label.prefix(1)).uppercased() as NSString
        initial.draw(
            at: NSPoint(x: 43, y: 31),
            withAttributes: [.font: NSFont.systemFont(ofSize: 58, weight: .semibold), .foregroundColor: NSColor.white]
        )
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(representation)
        return ApplicationArtwork(image: image, displayName: nil)
    }
#endif
}

private struct ApplicationCandidateProof: Sendable, Equatable {
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

private final class ApplicationArtworkVerifier: @unchecked Sendable {
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
                let matches = candidates.compactMap { Self.proof(for: $0, identity: identity) }
                continuation.resume(returning: matches.count == 1 ? matches[0] : nil)
            }
        }
    }

    func index(candidates: [URL]) async -> [ProcessIdentity: [URL]] {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                var result: [ProcessIdentity: [URL]] = [:]
                for candidate in candidates {
                    guard let (proof, identity) = Self.validatedCandidate(candidate) else { continue }
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
                continuation.resume(returning: Self.proof(for: proof.url, identity: identity) == proof)
            }
        }
    }

    private static func proof(
        for candidate: URL,
        identity: ProcessIdentity
    ) -> ApplicationCandidateProof? {
        guard let (proof, resolved) = validatedCandidate(candidate), resolved == identity else {
            return nil
        }
        return proof
    }

    private static func validatedCandidate(
        _ candidate: URL
    ) -> (ApplicationCandidateProof, ProcessIdentity)? {
        guard candidate.isFileURL, candidate.pathExtension.lowercased() == "app" else { return nil }
        let url = candidate.standardizedFileURL
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
