import AbyssFilterRuntime
import AbyssIPC
import Foundation
import Security
import SystemConfiguration

struct PeerContext: Sendable {
    let connectionID: UUID
    let uid: UInt32
    let auditSessionID: Int32
    let role: PeerRole
}

final class FilterControlSession: NSObject, AbyssFilterControlXPC {
    private let runtime: PolicyRuntime
    private let peer: PeerContext
    private let relay: AppRelayRegistry

    init(runtime: PolicyRuntime, peer: PeerContext, relay: AppRelayRegistry) {
        self.runtime = runtime
        self.peer = peer
        self.relay = relay
    }

    func handshake(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        let reply = ReplyOnce(requestID: request.requestID, reply)
        Tasks.handshake(request: request, reply: reply, runtime: runtime, peer: peer)
    }

    func claimController(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        let reply = ReplyOnce(requestID: request.requestID, reply)
        Tasks.claimController(
            request: request,
            reply: reply,
            runtime: runtime,
            peer: peer,
            relay: relay
        )
    }

    func beginConfigurationReset(
        _ request: SecureIPCEnvelope,
        withReply reply: @escaping (SecureIPCReply) -> Void
    ) {
        let payload = request.payload
        performMutation(request, expected: .beginConfigurationReset, reply: reply) {
            runtime, peer, leaseID in
            let value = try SecureIPCCodec.decode(
                ConfigurationResetRequest.self,
                from: payload
            )
            try await runtime.beginConfigurationReset(
                targetLineageID: value.targetLineageID,
                connectionID: peer.connectionID,
                leaseID: leaseID
            )
            return Data()
        }
    }

    func health(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        let reply = ReplyOnce(requestID: request.requestID, reply)
        Tasks.health(request: request, reply: reply, runtime: runtime, peer: peer)
    }

    func beginSnapshot(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        let payload = request.payload
        performMutation(request, expected: .beginSnapshot, reply: reply) { runtime, peer, leaseID in
            let header = try SecureIPCCodec.decode(SnapshotTransferBegin.self, from: payload)
            try await runtime.beginTransfer(
                header,
                connectionID: peer.connectionID,
                leaseID: leaseID,
                now: Date()
            )
            return Data()
        }
    }

    func appendSnapshotChunk(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        let payload = request.payload
        performMutation(request, expected: .appendSnapshotChunk, reply: reply) { runtime, peer, leaseID in
            let chunk = try SecureIPCCodec.decode(SnapshotChunk.self, from: payload)
            guard chunk.bytes.count <= IPCProtocolLimits.maximumChunkBytes else {
                throw FilterControlSessionError.oversizedChunk
            }
            try await runtime.appendTransfer(
                chunk,
                connectionID: peer.connectionID,
                leaseID: leaseID,
                now: Date()
            )
            return Data()
        }
    }

    func finishSnapshot(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        performMutation(request, expected: .finishSnapshot, reply: reply) { runtime, peer, leaseID in
            let result = try await runtime.finishTransfer(
                connectionID: peer.connectionID,
                leaseID: leaseID,
                now: Date()
            )
            return try SecureIPCCodec.encode(result)
        }
    }

    func abortSnapshot(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        performMutation(request, expected: .abortSnapshot, reply: reply) { runtime, peer, leaseID in
            try await runtime.abortTransfer(connectionID: peer.connectionID, leaseID: leaseID)
            return Data()
        }
    }

    func drainPrompts(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        performMutation(request, expected: .drainPrompts, reply: reply) { runtime, peer, leaseID in
            try await SecureIPCCodec.encode(runtime.drainPrompts(
                connectionID: peer.connectionID,
                leaseID: leaseID
            ))
        }
    }

    func answerPrompt(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        let payload = request.payload
        performMutation(request, expected: .answerPrompt, reply: reply) { runtime, peer, leaseID in
            let answer = try SecureIPCCodec.decode(PromptAnswer.self, from: payload)
            try await runtime.answerPrompt(
                answer,
                connectionID: peer.connectionID,
                leaseID: leaseID
            )
            return Data()
        }
    }

    func drainEvents(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        performMutation(request, expected: .drainEvents, reply: reply) { runtime, peer, leaseID in
            try await SecureIPCCodec.encode(runtime.drainEvents(
                connectionID: peer.connectionID,
                leaseID: leaseID
            ))
        }
    }

    func drainNotifications(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        performMutation(request, expected: .drainNotifications, reply: reply) { runtime, peer, leaseID in
            try await SecureIPCCodec.encode(runtime.drainNotifications(
                connectionID: peer.connectionID,
                leaseID: leaseID
            ))
        }
    }

    func prepareUninstall(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        performMutation(request, expected: .prepareUninstall, reply: reply) { runtime, peer, leaseID in
            try await runtime.prepareVerifiedUninstall(
                connectionID: peer.connectionID,
                leaseID: leaseID
            )
            return Data()
        }
    }

    func cliRequest(_ request: SecureIPCEnvelope, withReply reply: @escaping (SecureIPCReply) -> Void) {
        do {
            try Self.validate(request, kind: .cliRequest, requiresLease: false)
            guard peer.role == .cli else { throw FilterControlSessionError.capabilityDenied }
            let value = try SecureIPCCodec.decode(CLIRelayRequest.self, from: request.payload)
            try Self.validateCLIRequest(value)
            relay.perform(request: request, peer: peer, reply: ReplyOnce(
                requestID: request.requestID,
                reply
            ).call)
        } catch {
            ReplyOnce(requestID: request.requestID, reply).failure(error)
        }
    }

    private func performMutation(
        _ request: SecureIPCEnvelope,
        expected: IPCMessageKind,
        reply: @escaping (SecureIPCReply) -> Void,
        operation: @escaping @Sendable (PolicyRuntime, PeerContext, UUID) async throws -> Data
    ) {
        let reply = ReplyOnce(requestID: request.requestID, reply)
        Tasks.mutation(
            request: request,
            expected: expected,
            reply: reply,
            runtime: runtime,
            peer: peer,
            operation: operation
        )
    }

    private static func validate(
        _ request: SecureIPCEnvelope,
        kind: IPCMessageKind,
        requiresLease: Bool
    ) throws {
        guard request.protocolVersion.isCompatible(with: .current) else {
            throw FilterControlSessionError.incompatibleProtocol
        }
        guard request.messageKind == kind else { throw FilterControlSessionError.wrongMethodKind }
        guard request.payload.count <= IPCProtocolLimits.maximumSnapshotBytes else {
            throw FilterControlSessionError.oversizedPayload
        }
        if requiresLease, request.controllerLeaseID == nil {
            throw FilterControlSessionError.missingLease
        }
    }

    private static func validateCLIRequest(_ request: CLIRelayRequest) throws {
        switch request.command {
        case .rulesImportAppend:
            let chunk = try SecureIPCCodec.decode(CLITransferChunk.self, from: request.payload)
            guard chunk.bytes.count <= IPCProtocolLimits.maximumChunkBytes else {
                throw FilterControlSessionError.oversizedChunk
            }
        case .rulesExportBegin, .diagnosticsBegin, .profilesList:
            guard request.payload.isEmpty else { throw FilterControlSessionError.oversizedPayload }
        default:
            guard request.payload.count <= 4_096 else {
                throw FilterControlSessionError.oversizedPayload
            }
        }
    }

    private enum Tasks {
        static func handshake(
            request: SecureIPCEnvelope,
            reply: ReplyOnce,
            runtime: PolicyRuntime,
            peer: PeerContext
        ) {
            Task {
                do {
                    guard peer.role == .app else { throw FilterControlSessionError.capabilityDenied }
                    try FilterControlSession.validate(request, kind: .handshake, requiresLease: false)
                    let state = await runtime.handshake(
                        for: peer.connectionID,
                        uid: peer.uid,
                        mayDisclosePolicy: ConsoleSessionAuthorizer.isCurrentConsole(peer)
                    )
                    reply.success(try SecureIPCCodec.encode(state))
                } catch { reply.failure(error) }
            }
        }

        static func claimController(
            request: SecureIPCEnvelope,
            reply: ReplyOnce,
            runtime: PolicyRuntime,
            peer: PeerContext,
            relay: AppRelayRegistry
        ) {
            Task {
                do {
                    guard peer.role == .app else { throw FilterControlSessionError.capabilityDenied }
                    try FilterControlSession.validate(
                        request,
                        kind: .claimController,
                        requiresLease: false
                    )
                    let claim = try SecureIPCCodec.decode(
                        ClaimControllerRequest.self,
                        from: request.payload
                    )
                    let leaseID = try await runtime.claimController(
                        connectionID: peer.connectionID,
                        uid: peer.uid,
                        auditSessionID: peer.auditSessionID,
                        lineageID: claim.lineageID,
                        isCurrentConsoleUser: ConsoleSessionAuthorizer.isCurrentConsole(peer)
                    )
                    guard relay.activate(connectionID: peer.connectionID) else {
                        throw FilterControlSessionError.relayUnavailable
                    }
                    reply.success(try SecureIPCCodec.encode(leaseID))
                } catch { reply.failure(error) }
            }
        }

        static func health(
            request: SecureIPCEnvelope,
            reply: ReplyOnce,
            runtime: PolicyRuntime,
            peer: PeerContext
        ) {
            Task {
                do {
                    try FilterControlSession.validate(request, kind: .health, requiresLease: false)
                    let state = await runtime.handshake(
                        for: peer.connectionID,
                        uid: peer.uid,
                        mayDisclosePolicy: peer.role == .app &&
                            ConsoleSessionAuthorizer.isCurrentConsole(peer)
                    )
                    reply.success(try SecureIPCCodec.encode(state))
                } catch { reply.failure(error) }
            }
        }

        static func mutation(
            request: SecureIPCEnvelope,
            expected: IPCMessageKind,
            reply: ReplyOnce,
            runtime: PolicyRuntime,
            peer: PeerContext,
            operation: @escaping @Sendable (PolicyRuntime, PeerContext, UUID) async throws -> Data
        ) {
            Task {
                do {
                    guard peer.role == .app else { throw FilterControlSessionError.capabilityDenied }
                    guard ConsoleSessionAuthorizer.isCurrentConsole(peer) else {
                        await runtime.connectionInvalidated(peer.connectionID)
                        throw PolicyRuntimeError.notCurrentConsoleSession
                    }
                    try FilterControlSession.validate(request, kind: expected, requiresLease: true)
                    guard let leaseID = request.controllerLeaseID else {
                        throw FilterControlSessionError.missingLease
                    }
                    reply.success(try await operation(runtime, peer, leaseID))
                } catch { reply.failure(error) }
            }
        }
    }
}

enum ConsoleSessionAuthorizer {
    static func isCurrentConsole(_ peer: PeerContext) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", uid != 0 else { return false }
        guard UInt32(uid) == peer.uid, peer.auditSessionID > 0 else { return false }
        let requested = SecuritySessionId(peer.auditSessionID)
        var resolved: SecuritySessionId = 0
        var attributes = SessionAttributeBits(rawValue: 0)
        guard SessionGetInfo(requested, &resolved, &attributes) == errSessionSuccess,
              resolved == requested,
              attributes.contains(.sessionHasGraphicAccess),
              !attributes.contains(.sessionIsRemote),
              !attributes.contains(.sessionIsRoot) else { return false }
        return true
    }
}

private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let requestID: UUID
    private var reply: ((SecureIPCReply) -> Void)?

    init(requestID: UUID, _ reply: @escaping (SecureIPCReply) -> Void) {
        self.requestID = requestID
        self.reply = reply
    }

    func success(_ payload: Data) {
        call(SecureIPCReply(requestID: requestID, status: .success, payload: payload))
    }

    func failure(_ error: Error) {
        let status: IPCReplyStatus
        switch error {
        case is PolicyRuntimeError: status = .rejected
        case is SnapshotTransferError: status = .invalidRequest
        default: status = .internalFailure
        }
        call(SecureIPCReply(
            requestID: requestID,
            status: status,
            redactedErrorCode: String(describing: type(of: error))
        ))
    }

    func call(_ value: SecureIPCReply) {
        let pending = lock.withLock {
            defer { reply = nil }
            return reply
        }
        pending?(value)
    }

}

enum PolicyRuntimeError: Error, Sendable {
    case notCurrentConsoleSession
    case controllerBusy
    case foreignOwner
    case lineageMismatch
    case resetInProgress
    case initialClaimRequiresActiveProvider
    case invalidControllerLease
    case persistenceUnavailable

    init(_ error: ControllerClaimAuthorizationError) {
        switch error {
        case .initialClaimRequiresActiveProvider:
            self = .initialClaimRequiresActiveProvider
        case .foreignOwner:
            self = .foreignOwner
        case .lineageMismatch:
            self = .lineageMismatch
        case .resetInProgress:
            self = .resetInProgress
        }
    }
}

private enum FilterControlSessionError: Error {
    case incompatibleProtocol
    case wrongMethodKind
    case oversizedPayload
    case oversizedChunk
    case missingLease
    case capabilityDenied
    case relayUnavailable
}
