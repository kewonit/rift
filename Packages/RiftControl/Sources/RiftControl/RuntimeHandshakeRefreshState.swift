import RiftIPC

public struct RuntimeHandshakeRefreshState: Sendable {
    public private(set) var presentedHandshake: HandshakeState?
    private var refreshInFlight = false
    private var refreshDirty = false

    public init(presentedHandshake: HandshakeState? = nil) {
        self.presentedHandshake = presentedHandshake
    }

    @discardableResult
    public mutating func signal() -> Bool {
        presentedHandshake = nil
        guard !refreshInFlight else {
            refreshDirty = true
            return false
        }
        refreshInFlight = true
        return true
    }

    @discardableResult
    public mutating func complete(with handshake: HandshakeState?) -> Bool {
        guard refreshInFlight else {
            presentedHandshake = handshake
            return false
        }
        guard !refreshDirty else {
            refreshDirty = false
            presentedHandshake = nil
            return true
        }
        refreshInFlight = false
        presentedHandshake = handshake
        return false
    }
}
