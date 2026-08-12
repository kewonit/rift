import RiftCore
import RiftIPC
import Darwin
import Foundation
import Security

struct ResolvedIdentityPair: Sendable {
    let app: ProcessIdentity?
    let process: ProcessIdentity?
    let resolutionFailed: Bool
}

enum IdentityResolverError: Error, Sendable {
    case queueFull
    case deadlineExceeded
    case invalidAuditToken
    case codeLookupFailed(OSStatus)
}

final class IdentityResolver: @unchecked Sendable {
    static let maximumCacheEntries = 1_024
    static let maximumPendingPairs = 64
    static let maximumCallbacksPerPair = 64
    static let cacheLifetime: TimeInterval = 300

    private struct CacheEntry {
        let identity: ProcessIdentity
        let storedAt: Date
    }

    private struct TokenPair: Hashable {
        let app: Data?
        let process: Data?
    }

    private let stateQueue = DispatchQueue(label: "io.rift.firewall.identity.state")
    private let workers = BoundedIdentityWorkerPool(
        label: "io.rift.firewall.identity.worker"
    )
    private var cache: [Data: CacheEntry] = [:]
    private var pending: [TokenPair: [@Sendable (ResolvedIdentityPair) -> Void]] = [:]
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: stateQueue
        )
        source.setEventHandler { [weak self] in
            self?.cache.removeAll(keepingCapacity: false)
        }
        source.resume()
        memoryPressureSource = source
    }

    func clear() {
        stateQueue.async { [self] in
            cache.removeAll(keepingCapacity: false)
        }
    }

    func cachedPair(app: Data?, process: Data?, now: Date) -> ResolvedIdentityPair? {
        stateQueue.sync {
            let appIdentity = app.flatMap { validCacheValue(for: $0, now: now) }
            let processIdentity = process.flatMap { validCacheValue(for: $0, now: now) }
            guard (app == nil || appIdentity != nil),
                  (process == nil || processIdentity != nil) else { return nil }
            return ResolvedIdentityPair(
                app: appIdentity,
                process: processIdentity,
                resolutionFailed: false
            )
        }
    }

    func resolve(
        app: Data?,
        process: Data?,
        deadline: Date,
        completion: @escaping @Sendable (ResolvedIdentityPair) -> Void
    ) {
        let pair = TokenPair(app: app, process: process)
        stateQueue.async { [self] in
            guard Date() < deadline else {
                completion(ResolvedIdentityPair(app: nil, process: nil, resolutionFailed: true))
                return
            }
            if var callbacks = pending[pair] {
                guard callbacks.count < Self.maximumCallbacksPerPair else {
                    completion(ResolvedIdentityPair(app: nil, process: nil, resolutionFailed: true))
                    return
                }
                callbacks.append(completion)
                pending[pair] = callbacks
                return
            }
            guard pending.count < Self.maximumPendingPairs else {
                completion(ResolvedIdentityPair(app: nil, process: nil, resolutionFailed: true))
                return
            }
            pending[pair] = [completion]
            workers.submit { [self] in
                let appResult = resolveOne(app, deadline: deadline)
                let processResult = app == process
                    ? appResult : resolveOne(process, deadline: deadline)
                stateQueue.async { [self] in
                    let callbacks = pending.removeValue(forKey: pair) ?? []
                    let now = Date()
                    guard now < deadline else {
                        let result = ResolvedIdentityPair(app: nil, process: nil, resolutionFailed: true)
                        callbacks.forEach { $0(result) }
                        return
                    }
                    if case .success(let identity?) = appResult, let app {
                        insert(identity, for: app, now: now)
                    }
                    if case .success(let identity?) = processResult, let process {
                        insert(identity, for: process, now: now)
                    }
                    let appIdentity = try? appResult.get()
                    let processIdentity = try? processResult.get()
                    let result = ResolvedIdentityPair(
                        app: appIdentity ?? nil,
                        process: processIdentity ?? nil,
                        resolutionFailed: appResult.isFailure || processResult.isFailure
                    )
                    callbacks.forEach { $0(result) }
                }
            }
        }
    }

    private func validCacheValue(for token: Data, now: Date) -> ProcessIdentity? {
        guard let entry = cache[token], now.timeIntervalSince(entry.storedAt) <= Self.cacheLifetime else {
            cache.removeValue(forKey: token)
            return nil
        }
        return entry.identity
    }

    private func insert(_ identity: ProcessIdentity, for token: Data, now: Date) {
        if cache.count >= Self.maximumCacheEntries,
           let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[token] = CacheEntry(identity: identity, storedAt: now)
    }

    private func resolveOne(
        _ token: Data?,
        deadline: Date
    ) -> Result<ProcessIdentity?, Error> {
        guard let token else { return .success(nil) }
        guard Date() < deadline else {
            return .failure(IdentityResolverError.deadlineExceeded)
        }
        guard token.count == MemoryLayout<audit_token_t>.size else {
            return .failure(IdentityResolverError.invalidAuditToken)
        }
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributeAudit as String: token as CFData] as CFDictionary,
            [],
            &code
        )
        guard status == errSecSuccess, let code else {
            return .failure(IdentityResolverError.codeLookupFailed(status))
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return .failure(IdentityResolverError.codeLookupFailed(staticStatus))
        }
        var information: CFDictionary?
        let signingInformation = SecCSFlags(rawValue: 1 << 1)
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            signingInformation,
            &information
        )
        guard infoStatus == errSecSuccess, let info = information as? [String: Any] else {
            return .failure(IdentityResolverError.codeLookupFailed(infoStatus))
        }
        guard Date() < deadline else {
            return .failure(IdentityResolverError.deadlineExceeded)
        }
        do {
            return .success(try StaticCodeIdentityResolver.identity(
                code: code,
                staticCode: staticCode,
                information: info,
                shouldCancel: { Date() >= deadline }
            ))
        } catch {
            return .failure(error)
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
