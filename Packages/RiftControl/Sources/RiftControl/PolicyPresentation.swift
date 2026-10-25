import RiftCore

public struct PolicyPresentation: Sendable, Hashable {
    public let baseMode: OperationMode
    public let effectiveMode: OperationMode
    public let profile: PolicyProfile?

    public init(
        baseMode: OperationMode,
        effectiveMode: OperationMode,
        profile: PolicyProfile?
    ) {
        self.baseMode = baseMode
        self.effectiveMode = effectiveMode
        self.profile = profile
    }

    public init(configuration: PolicyConfigurationDraft) {
        self.init(
            baseMode: configuration.baseOperationMode,
            effectiveMode: configuration.operationMode,
            profile: configuration.profiles.first { $0.id == configuration.activeProfileID }
        )
    }
}
