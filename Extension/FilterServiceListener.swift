import AbyssIPC
import Foundation
import OSLog
import Security

final class FilterServiceListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener?
    private let runtime: PolicyRuntime
    private let logger = Logger(subsystem: "io.abyss.firewall.filter", category: "xpc")
    private let relay = AppRelayRegistry()

    init(runtime: PolicyRuntime) {
        self.runtime = runtime
        self.listener = Self.serviceName().map(NSXPCListener.init(machServiceName:))
        super.init()
        listener?.delegate = self
        if listener == nil {
            logger.fault("Control service is unavailable because its configured name is missing")
        }
        let relay = self.relay
        RuntimeEnvironment.prompts.installActivitySignal { relay.notifyRuntimeDataAvailable() }
        RuntimeEnvironment.events.installActivitySignal { relay.notifyRuntimeDataAvailable() }
        RuntimeEnvironment.notifications.installActivitySignal { relay.notifyRuntimeDataAvailable() }
        if RuntimeEnvironment.reloads.install({ _ in relay.notifyRuntimeDataAvailable() }) == nil {
            logger.error("Runtime readiness signal observer could not be installed")
        }
    }

    func resume() {
        listener?.activate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let role = Self.peerRoleHint(processIdentifier: connection.processIdentifier),
              let requirement = Self.codeSigningRequirement(identifier: role.signingIdentifier) else {
            logger.error("Rejected XPC peer because its exact signed role could not be established")
            return false
        }
        // The PID lookup only selects a candidate role. The connection itself
        // enforces that exact role requirement against each sender identity
        // before any exported method is dispatched, so PID reuse cannot grant a
        // capability belonging to the other allowed executable.
        connection.setCodeSigningRequirement(requirement)
        let connectionID = UUID()
        let peer = PeerContext(
            connectionID: connectionID,
            uid: UInt32(connection.effectiveUserIdentifier),
            auditSessionID: connection.auditSessionIdentifier,
            role: role
        )
        let session = FilterControlSession(runtime: runtime, peer: peer, relay: relay)
        connection.exportedInterface = NSXPCInterface(with: AbyssFilterControlXPC.self)
        connection.exportedObject = session
        if role == .app {
            connection.remoteObjectInterface = NSXPCInterface(with: AbyssAppRelayXPC.self)
            guard relay.registerCandidate(connection: connection, peer: peer) else {
                logger.error("Rejected app XPC peer because the relay candidate cap was reached")
                return false
            }
        }
        connection.interruptionHandler = { [runtime, relay] in
            relay.unregister(connectionID: connectionID)
            Task { await runtime.connectionInvalidated(connectionID) }
        }
        connection.invalidationHandler = { [runtime, relay] in
            relay.unregister(connectionID: connectionID)
            Task { await runtime.connectionInvalidated(connectionID) }
        }
        connection.activate()
        return true
    }

    private static func serviceName() -> String? {
        guard
            let dictionary = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
            let name = dictionary["NEMachServiceName"] as? String,
            !name.isEmpty
        else { return nil }
        return name
    }

    private static func codeSigningRequirement(identifier: String) -> String? {
        guard let rawPrefix = Bundle.main.object(
            forInfoDictionaryKey: "AbyssTeamIdentifierPrefix"
        ) as? String else { return nil }
        let team = rawPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !team.isEmpty,
              team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func peerRoleHint(processIdentifier: pid_t) -> PeerRole? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)]
            as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }
        if satisfies(code, identifier: "io.abyss.firewall") { return .app }
        if satisfies(code, identifier: "io.abyss.firewall.cli") { return .cli }
        return nil
    }

    private static func satisfies(_ code: SecCode, identifier: String) -> Bool {
        guard let source = codeSigningRequirement(identifier: identifier) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

enum PeerRole: Sendable, Equatable {
    case app
    case cli

    var signingIdentifier: String {
        switch self {
        case .app: "io.abyss.firewall"
        case .cli: "io.abyss.firewall.cli"
        }
    }
}

final class AppRelayRegistry: @unchecked Sendable {
    private struct Entry {
        let connectionID: UUID
        let uid: UInt32
        let auditSessionID: Int32
        let connection: NSXPCConnection
    }

    private let lock = NSLock()
    private var candidates: [UUID: Entry] = [:]
    private var activeConnectionID: UUID?
    private var pendingRequestIDs: Set<UUID> = []
    private var notificationPending = false
    private var notificationDirty = false

    func registerCandidate(connection: NSXPCConnection, peer: PeerContext) -> Bool {
        lock.withLock {
            guard candidates.count < 8 else { return false }
            candidates[peer.connectionID] = Entry(
                connectionID: peer.connectionID,
                uid: peer.uid,
                auditSessionID: peer.auditSessionID,
                connection: connection
            )
            return true
        }
    }

    func activate(connectionID: UUID) -> Bool {
        lock.withLock {
            guard candidates[connectionID] != nil else { return false }
            activeConnectionID = connectionID
            notificationPending = false
            notificationDirty = false
            return true
        }
    }

    func unregister(connectionID: UUID) {
        lock.withLock {
            candidates.removeValue(forKey: connectionID)
            if activeConnectionID == connectionID {
                activeConnectionID = nil
                notificationPending = false
                notificationDirty = false
            }
        }
    }

    func notifyRuntimeDataAvailable() {
        let connection = lock.withLock { () -> NSXPCConnection? in
            guard let activeConnectionID,
                  let entry = candidates[activeConnectionID] else { return nil }
            if notificationPending {
                notificationDirty = true
                return nil
            }
            notificationPending = true
            return entry.connection
        }
        guard let connection else { return }
        let gate = RelayVoidGate(timeout: .seconds(5)) { [weak self] in
            self?.completeNotification()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.call()
        }) as? AbyssAppRelayXPC else {
            gate.call()
            return
        }
        proxy.runtimeDataAvailable { gate.call() }
    }

    private func completeNotification() {
        let again = lock.withLock { () -> Bool in
            notificationPending = false
            guard notificationDirty else { return false }
            notificationDirty = false
            return activeConnectionID.flatMap { candidates[$0] } != nil
        }
        if again { notifyRuntimeDataAvailable() }
    }

    func perform(
        request: SecureIPCEnvelope,
        peer: PeerContext,
        reply: @escaping (SecureIPCReply) -> Void
    ) {
        guard ConsoleSessionAuthorizer.isCurrentConsole(peer) else {
            Self.reject(request, code: "sameUserAppUnavailable", reply: reply)
            return
        }
        let result = beginRequest(requestID: request.requestID, peer: peer)
        guard let entry = result.entry else {
            Self.reject(request, code: result.error ?? "sameUserAppUnavailable", reply: reply)
            return
        }
        let gate = RelayReplyGate(
            requestID: request.requestID,
            timeout: .seconds(5),
            completion: { [weak self] in self?.finishRequest(request.requestID) },
            reply: reply
        )
        guard let proxy = entry.connection.remoteObjectProxyWithErrorHandler({ _ in
            gate.call(SecureIPCReply(
                requestID: request.requestID,
                status: .internalFailure,
                redactedErrorCode: "appRelayFailure"
            ))
        }) as? AbyssAppRelayXPC else {
            gate.call(SecureIPCReply(
                requestID: request.requestID,
                status: .internalFailure,
                redactedErrorCode: "appRelayUnavailable"
            ))
            return
        }
        proxy.performCLIRequest(request) { gate.call($0) }
    }

    private func beginRequest(
        requestID: UUID,
        peer: PeerContext
    ) -> (entry: Entry?, error: String?) {
        lock.withLock {
            guard let activeConnectionID,
                  let entry = candidates[activeConnectionID],
                  entry.uid == peer.uid,
                  entry.auditSessionID == peer.auditSessionID,
                  peer.auditSessionID > 0 else {
                return (nil, "sameUserAppUnavailable")
            }
            guard !pendingRequestIDs.contains(requestID) else {
                return (nil, "duplicateRelayRequest")
            }
            guard pendingRequestIDs.count < 8 else { return (nil, "appRelayBusy") }
            pendingRequestIDs.insert(requestID)
            return (entry, nil)
        }
    }

    private func finishRequest(_ requestID: UUID) {
        lock.withLock { _ = pendingRequestIDs.remove(requestID) }
    }

    private static func reject(
        _ request: SecureIPCEnvelope,
        code: String,
        reply: @escaping (SecureIPCReply) -> Void
    ) {
        reply(SecureIPCReply(
            requestID: request.requestID,
            status: .rejected,
            redactedErrorCode: code
        ))
    }
}

private final class RelayReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var reply: ((SecureIPCReply) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(
        requestID: UUID,
        timeout: Duration,
        completion: @escaping () -> Void,
        reply: @escaping (SecureIPCReply) -> Void
    ) {
        self.completion = completion
        self.reply = reply
        timeoutTask = Task { [self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            call(SecureIPCReply(
                requestID: requestID,
                status: .internalFailure,
                redactedErrorCode: "appRelayTimeout"
            ))
        }
    }

    func call(_ value: SecureIPCReply) {
        let handlers = lock.withLock { () -> (((SecureIPCReply) -> Void)?, (() -> Void)?) in
            guard reply != nil else { return (nil, nil) }
            timeoutTask?.cancel()
            timeoutTask = nil
            defer { reply = nil; completion = nil }
            return (reply, completion)
        }
        handlers.0?(value)
        handlers.1?()
    }
}

private final class RelayVoidGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration, completion: @escaping () -> Void) {
        self.completion = completion
        timeoutTask = Task { [self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            call()
        }
    }

    func call() {
        let handler = lock.withLock { () -> (() -> Void)? in
            timeoutTask?.cancel()
            timeoutTask = nil
            defer { completion = nil }
            return completion
        }
        handler?()
    }
}
