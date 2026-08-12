import AbyssIPC
import Foundation

enum FilterControlClientError: Error, Sendable {
    case missingConfiguration
    case unsignedBuild
    case proxyUnavailable
    case invalidReply
    case rejected(String?)
    case timeout
}

actor FilterControlClient {
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var controllerLeaseID: UUID?
    private var appRelay: AbyssAppRelayXPC?
    private var invalidationHandler: (@Sendable () async -> Void)?
    private let transferQueue = SnapshotTransferQueue()

    func installAppRelay(_ relay: AbyssAppRelayXPC) {
        appRelay = relay
    }

    func installInvalidationHandler(_ handler: @escaping @Sendable () async -> Void) {
        invalidationHandler = handler
    }

    @discardableResult
    func connect() throws -> UUID {
        if let connectionID, connection != nil { return connectionID }
        guard connection == nil, connectionID == nil else {
            throw FilterControlClientError.invalidReply
        }
        guard let serviceName = Bundle.main.object(
            forInfoDictionaryKey: "AbyssMachServiceName"
        ) as? String, !serviceName.isEmpty else {
            throw FilterControlClientError.missingConfiguration
        }
        guard let requirement = Self.extensionCodeSigningRequirement() else {
            throw FilterControlClientError.unsignedBuild
        }
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: AbyssFilterControlXPC.self)
        if let appRelay {
            connection.exportedInterface = NSXPCInterface(with: AbyssAppRelayXPC.self)
            connection.exportedObject = appRelay
        }
        connection.setCodeSigningRequirement(requirement)
        let connectionID = UUID()
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionEnded(connectionID) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionEnded(connectionID) }
        }
        connection.activate()
        self.connection = connection
        self.connectionID = connectionID
        return connectionID
    }

    func requireCurrentConnection(_ expectedID: UUID) throws {
        guard connection != nil, connectionID == expectedID else {
            throw FilterControlClientError.proxyUnavailable
        }
    }

    func invalidate() {
        let connection = connection
        self.connection = nil
        connectionID = nil
        controllerLeaseID = nil
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
    }

    private func connectionEnded(_ connectionID: UUID) async {
        guard self.connectionID == connectionID else { return }
        connection = nil
        self.connectionID = nil
        controllerLeaseID = nil
        await invalidationHandler?()
    }

    func handshake() async throws -> HandshakeState {
        let request = SecureIPCEnvelope(kind: .handshake)
        let reply = try await call(request) { proxy, request, reply in
            proxy.handshake(request, withReply: reply)
        }
        return try decode(HandshakeState.self, reply: reply)
    }

    func claimController(
        lineageID: UUID,
        requiring expectedConnectionID: UUID? = nil
    ) async throws -> UUID {
        let request = SecureIPCEnvelope(
            kind: .claimController,
            payload: try SecureIPCCodec.encode(ClaimControllerRequest(lineageID: lineageID))
        )
        let reply = try await call(request) { proxy, request, reply in
            proxy.claimController(request, withReply: reply)
        }
        let lease = try decode(UUID.self, reply: reply)
        if let expectedConnectionID {
            try requireCurrentConnection(expectedConnectionID)
        }
        controllerLeaseID = lease
        return lease
    }

    func beginConfigurationReset(targetLineageID: UUID) async throws {
        guard let lease = controllerLeaseID else {
            throw FilterControlClientError.rejected("noLease")
        }
        let request = SecureIPCEnvelope(
            kind: .beginConfigurationReset,
            controllerLeaseID: lease,
            payload: try SecureIPCCodec.encode(ConfigurationResetRequest(
                targetLineageID: targetLineageID
            ))
        )
        _ = try await successfulReply(request) {
            $0.beginConfigurationReset($1, withReply: $2)
        }
    }

    func apply(_ desired: DesiredTransfer) async throws -> SnapshotFinishResult {
        guard let lease = controllerLeaseID else { throw FilterControlClientError.rejected("noLease") }
        let request = SnapshotTransferRequest(
            tuple: desired.tuple,
            schemaVersion: CompiledPolicyPayload.currentSchemaVersion,
            bytes: desired.bytes
        )
        let channel = SnapshotTransferChannel(
            begin: { [weak self] header in
                guard let self else { throw FilterControlClientError.proxyUnavailable }
                try await self.sendTransferBegin(header, leaseID: lease)
            },
            append: { [weak self] chunk in
                guard let self else { throw FilterControlClientError.proxyUnavailable }
                try await self.sendTransferChunk(chunk, leaseID: lease)
            },
            finish: { [weak self] in
                guard let self else { throw FilterControlClientError.proxyUnavailable }
                return try await self.sendTransferFinish(leaseID: lease)
            },
            abort: { [weak self] in
                await self?.abortTransfer(leaseID: lease)
            }
        )
        return try await transferQueue.submit(request, channel: channel)
    }

    func abortTransfer() async {
        guard let lease = controllerLeaseID else { return }
        await abortTransfer(leaseID: lease)
    }

    private func sendTransferBegin(
        _ header: SnapshotTransferBegin,
        leaseID: UUID
    ) async throws {
        try requireCurrentLease(leaseID)
        let request = SecureIPCEnvelope(
            kind: .beginSnapshot,
            controllerLeaseID: leaseID,
            payload: try SecureIPCCodec.encode(header)
        )
        _ = try await successfulReply(request) { $0.beginSnapshot($1, withReply: $2) }
    }

    private func sendTransferChunk(_ chunk: SnapshotChunk, leaseID: UUID) async throws {
        try requireCurrentLease(leaseID)
        let request = SecureIPCEnvelope(
            kind: .appendSnapshotChunk,
            controllerLeaseID: leaseID,
            payload: try SecureIPCCodec.encode(chunk)
        )
        _ = try await successfulReply(request) { $0.appendSnapshotChunk($1, withReply: $2) }
    }

    private func sendTransferFinish(leaseID: UUID) async throws -> SnapshotFinishResult {
        try requireCurrentLease(leaseID)
        let request = SecureIPCEnvelope(kind: .finishSnapshot, controllerLeaseID: leaseID)
        let reply = try await successfulReply(request) { $0.finishSnapshot($1, withReply: $2) }
        return try SecureIPCCodec.decode(SnapshotFinishResult.self, from: reply.payload)
    }

    private func abortTransfer(leaseID: UUID) async {
        guard controllerLeaseID == leaseID else { return }
        let request = SecureIPCEnvelope(kind: .abortSnapshot, controllerLeaseID: leaseID)
        _ = try? await successfulReply(request) { $0.abortSnapshot($1, withReply: $2) }
    }

    private func requireCurrentLease(_ leaseID: UUID) throws {
        guard controllerLeaseID == leaseID else {
            throw FilterControlClientError.rejected("staleLease")
        }
    }

    func drainPrompts() async throws -> [PromptRequest] {
        guard let lease = controllerLeaseID else { throw FilterControlClientError.rejected("noLease") }
        let request = SecureIPCEnvelope(kind: .drainPrompts, controllerLeaseID: lease)
        let reply = try await successfulReply(request) { $0.drainPrompts($1, withReply: $2) }
        return try SecureIPCCodec.decode([PromptRequest].self, from: reply.payload)
    }

    func answerPrompt(_ answer: PromptAnswer) async throws {
        guard let lease = controllerLeaseID else { throw FilterControlClientError.rejected("noLease") }
        let request = SecureIPCEnvelope(
            kind: .answerPrompt,
            controllerLeaseID: lease,
            payload: try SecureIPCCodec.encode(answer)
        )
        _ = try await successfulReply(request) { $0.answerPrompt($1, withReply: $2) }
    }

    func drainEvents() async throws -> RuntimeEventBatch {
        guard let lease = controllerLeaseID else { throw FilterControlClientError.rejected("noLease") }
        let request = SecureIPCEnvelope(kind: .drainEvents, controllerLeaseID: lease)
        let reply = try await successfulReply(request) { $0.drainEvents($1, withReply: $2) }
        return try SecureIPCCodec.decode(RuntimeEventBatch.self, from: reply.payload)
    }

    func drainNotifications() async throws -> [EphemeralNotificationEvent] {
        guard let lease = controllerLeaseID else { throw FilterControlClientError.rejected("noLease") }
        let request = SecureIPCEnvelope(kind: .drainNotifications, controllerLeaseID: lease)
        let reply = try await successfulReply(request) { $0.drainNotifications($1, withReply: $2) }
        return try SecureIPCCodec.decode([EphemeralNotificationEvent].self, from: reply.payload)
    }

    func prepareUninstall() async throws {
        guard let lease = controllerLeaseID else { throw FilterControlClientError.rejected("noLease") }
        let request = SecureIPCEnvelope(kind: .prepareUninstall, controllerLeaseID: lease)
        _ = try await successfulReply(request) { $0.prepareUninstall($1, withReply: $2) }
    }

    private func successfulReply(
        _ request: SecureIPCEnvelope,
        invoke: @escaping (AbyssFilterControlXPC, SecureIPCEnvelope, @escaping (SecureIPCReply) -> Void) -> Void
    ) async throws -> SecureIPCReply {
        let reply = try await call(request, invoke: invoke)
        guard reply.status == .success else {
            throw FilterControlClientError.rejected(reply.redactedErrorCode)
        }
        return reply
    }

    private func call(
        _ request: SecureIPCEnvelope,
        invoke: @escaping (AbyssFilterControlXPC, SecureIPCEnvelope, @escaping (SecureIPCReply) -> Void) -> Void
    ) async throws -> SecureIPCReply {
        guard let connection else { throw FilterControlClientError.proxyUnavailable }
        let cancellation = ContinuationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate(continuation, timeout: .seconds(5))
                guard cancellation.install(gate) else { return }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.fail(error)
                }) as? AbyssFilterControlXPC else {
                    gate.fail(FilterControlClientError.proxyUnavailable)
                    return
                }
                invoke(proxy, request) { gate.succeed($0) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func decode<Value: Codable>(
        _ type: Value.Type,
        reply: SecureIPCReply
    ) throws -> Value {
        guard reply.status == .success else {
            throw FilterControlClientError.rejected(reply.redactedErrorCode)
        }
        return try SecureIPCCodec.decode(type, from: reply.payload)
    }

    private static func extensionCodeSigningRequirement() -> String? {
        guard let rawPrefix = Bundle.main.object(
            forInfoDictionaryKey: "AbyssTeamIdentifierPrefix"
        ) as? String else { return nil }
        let team = rawPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !team.isEmpty,
              team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return "anchor apple generic and identifier \"io.abyss.firewall.filter\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }
}

private final class ContinuationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var gate: ContinuationGate?

    func install(_ gate: ContinuationGate) -> Bool {
        let shouldCancel = lock.withLock {
            self.gate = gate
            return isCancelled
        }
        if shouldCancel {
            gate.fail(CancellationError())
            return false
        }
        return true
    }

    func cancel() {
        let gate = lock.withLock {
            isCancelled = true
            return self.gate
        }
        gate?.fail(CancellationError())
    }
}

struct DesiredTransfer: Sendable {
    let tuple: PolicyTuple
    let bytes: Data
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SecureIPCReply, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(
        _ continuation: CheckedContinuation<SecureIPCReply, Error>,
        timeout: Duration
    ) {
        self.continuation = continuation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(FilterControlClientError.timeout)
        }
    }

    func succeed(_ reply: SecureIPCReply) {
        take()?.resume(returning: reply)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<SecureIPCReply, Error>? {
        lock.withLock {
            timeoutTask?.cancel()
            timeoutTask = nil
            defer { continuation = nil }
            return continuation
        }
    }
}
