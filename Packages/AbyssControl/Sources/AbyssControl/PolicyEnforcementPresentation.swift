import AbyssIPC

public enum PolicyEnforcementPresentation {
    public static func state(
        persistedState: PolicyOutboxState,
        desiredTuple: PolicyTuple,
        handshake: HandshakeState?
    ) -> PolicyOutboxState {
        if let handshake,
           handshake.readiness == .ready,
           handshake.providerEpoch != nil,
           handshake.active == desiredTuple {
            return .enforced
        }
        return persistedState == .enforced ? .persistedPendingProvider : persistedState
    }
}
