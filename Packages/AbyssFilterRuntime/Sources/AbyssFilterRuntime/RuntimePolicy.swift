import AbyssCore
import AbyssIPC
import Foundation

public struct RuntimePolicy: Sendable {
    public let tuple: PolicyTuple
    public let payload: CompiledPolicyPayload
    private let recovered: RecoveredPolicy
    private let matcher: CompiledRuleMatcher
    private let expiryMetadata: ExpiryMetadata

    public init(recovered: RecoveredPolicy, expiryMetadata: ExpiryMetadata = .available(alreadyExpired: [])) {
        self.tuple = recovered.tuple
        self.payload = recovered.payload
        self.recovered = recovered
        self.matcher = CompiledRuleMatcher(rules: recovered.payload.rules)
        self.expiryMetadata = expiryMetadata
    }

    public func decision(for flow: FlowDescriptor, now: Date) -> Decision {
        matcher.decision(
            for: flow,
            context: MatchContext(
                activeProfileID: payload.activeProfileID,
                enabledLocalGroupIDs: Set(payload.enabledLocalGroupIDs),
                authorizedUID: payload.authorizedUID,
                policyTime: PolicyTime(now: now, expiryMetadata: expiryMetadata)
            ),
            mode: payload.operationMode
        )
    }

    public var recordedExpiryKeys: Set<ExpiredRuleKey> {
        if case .available(let keys) = expiryMetadata { return keys }
        return []
    }

    public var expiryMetadataAvailable: Bool {
        if case .available = expiryMetadata { return true }
        return false
    }

    public var referencedExpiryKeys: Set<ExpiredRuleKey> {
        Set(payload.rules.compactMap(\.expiryKey))
    }

    public func expiryKeys(dueAt date: Date) -> Set<ExpiredRuleKey> {
        Set(payload.rules.compactMap { rule in
            guard let key = rule.expiryKey, key.expiresAt <= date else { return nil }
            return key
        })
    }

    public func nextExpiry(after date: Date) -> Date? {
        payload.rules.compactMap(\.expiresAt).filter { $0 > date }.min()
    }

    public func replacingExpiryMetadata(_ metadata: ExpiryMetadata) -> RuntimePolicy {
        RuntimePolicy(recovered: recovered, expiryMetadata: metadata)
    }
}

// This is a narrow synchronization primitive for one immutable value. No
// NetworkExtension or XPC reference crosses this boundary.
public final class ActivePolicyReference: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: RuntimePolicy?

    public init() {}

    public func load() -> RuntimePolicy? {
        lock.withLock { policy }
    }

    public func store(_ newValue: RuntimePolicy?) {
        lock.withLock { policy = newValue }
    }
}
