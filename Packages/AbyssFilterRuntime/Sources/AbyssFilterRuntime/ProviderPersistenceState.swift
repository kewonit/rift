import AbyssCore
import AbyssIPC
import Foundation

public enum RuntimeBootstrapHealth: Sendable, Equatable {
    case available
    case degradedPersistence
}

public struct RuntimePersistenceBootstrap: Sendable {
    public let rootStore: RootPolicyStore?
    public let tombstoneStore: ExpiryTombstoneStore?
    public let health: RuntimeBootstrapHealth

    public init(rootURL: URL?) {
        guard let rootURL else {
            rootStore = nil
            tombstoneStore = nil
            health = .degradedPersistence
            return
        }
        rootStore = try? RootPolicyStore(rootURL: rootURL)
        tombstoneStore = try? ExpiryTombstoneStore(rootURL: rootURL)
        health = rootStore != nil && tombstoneStore != nil
            ? .available : .degradedPersistence
    }
}

public struct ProviderPersistenceState: Sendable, Equatable {
    public private(set) var readiness: ProviderReadiness = .unavailable
    public private(set) var expiryMetadata: ExpiryMetadata = .unavailable

    private var rootPersistenceAvailable = false
    private var tombstonePersistenceAvailable = false
    private var startCompleted = false
    private var settingsSucceeded = false
    private var hasActivePolicy = false

    public init() {}

    public mutating func beginProviderStart(
        rootPersistenceAvailable: Bool,
        tombstonePersistenceAvailable: Bool
    ) {
        self.rootPersistenceAvailable = rootPersistenceAvailable
        self.tombstonePersistenceAvailable = tombstonePersistenceAvailable
        startCompleted = false
        settingsSucceeded = false
        hasActivePolicy = false
        expiryMetadata = .unavailable
        updateReadiness()
    }

    public mutating func rootPersistenceSucceeded() {
        rootPersistenceAvailable = true
        updateReadiness()
    }

    public mutating func rootPersistenceFailed() {
        rootPersistenceAvailable = false
        updateReadiness()
    }

    @discardableResult
    public mutating func tombstonesLoaded(_ keys: Set<ExpiredRuleKey>) -> ExpiryMetadata {
        tombstonePersistenceAvailable = true
        expiryMetadata = .available(alreadyExpired: keys)
        updateReadiness()
        return expiryMetadata
    }

    @discardableResult
    public mutating func tombstonesPersisted(_ keys: Set<ExpiredRuleKey>) -> ExpiryMetadata {
        tombstonePersistenceAvailable = true
        expiryMetadata = .available(alreadyExpired: keys)
        updateReadiness()
        return expiryMetadata
    }

    @discardableResult
    public mutating func tombstonePersistenceFailed() -> ExpiryMetadata {
        tombstonePersistenceAvailable = false
        expiryMetadata = .unavailable
        updateReadiness()
        return expiryMetadata
    }

    @discardableResult
    public mutating func completeProviderStart(
        settingsSucceeded: Bool,
        hasActivePolicy: Bool
    ) -> ProviderReadiness {
        startCompleted = true
        self.settingsSucceeded = settingsSucceeded
        self.hasActivePolicy = settingsSucceeded && hasActivePolicy
        updateReadiness()
        return readiness
    }

    public mutating func activePolicyChanged(_ isActive: Bool) {
        hasActivePolicy = settingsSucceeded && isActive
        updateReadiness()
    }

    public mutating func stopProvider() {
        self = ProviderPersistenceState()
    }

    public var canActivatePolicy: Bool {
        startCompleted && settingsSucceeded
    }

    private mutating func updateReadiness() {
        guard startCompleted else {
            readiness = rootPersistenceAvailable && tombstonePersistenceAvailable
                ? .starting : .degradedPersistence
            return
        }
        guard settingsSucceeded else {
            readiness = .unavailable
            return
        }
        guard rootPersistenceAvailable, tombstonePersistenceAvailable else {
            readiness = .degradedPersistence
            return
        }
        readiness = hasActivePolicy ? .ready : .degradedNoPolicy
    }
}
