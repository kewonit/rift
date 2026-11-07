import NetworkExtension

/// Reads and writes the macOS filter configuration, retrying once when the
/// saved preferences changed underneath Rift.
@MainActor
enum FilterConfigurationStore {
    static func save(
        extensionIdentifier: String,
        retryStaleOnce: Bool = true,
        onStale: () -> Void
    ) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        let configuration = NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterPackets = false
        configuration.organization = "Rift"
        configuration.filterDataProviderBundleIdentifier = extensionIdentifier
        configuration.filterPacketProviderBundleIdentifier = nil
        manager.providerConfiguration = configuration
        manager.localizedDescription = "Rift Network Filter"
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
        } catch let error as NSError where retryStaleOnce && isStale(error) {
            onStale()
            try await save(
                extensionIdentifier: extensionIdentifier,
                retryStaleOnce: false,
                onStale: onStale
            )
        }
    }

    static func remove(retryStaleOnce: Bool = true) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        guard manager.providerConfiguration != nil else { return }
        do {
            try await manager.removeFromPreferences()
        } catch let error as NSError where retryStaleOnce && isStale(error) {
            try await remove(retryStaleOnce: false)
        }
    }

    private static func isStale(_ error: NSError) -> Bool {
        error.domain == NEFilterErrorDomain &&
            error.code == NEFilterManagerError.configurationStale.rawValue
    }
}
