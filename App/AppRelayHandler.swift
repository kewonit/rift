import RiftIPC
import Foundation

final class AppRelayHandler: NSObject, RiftAppRelayXPC, @unchecked Sendable {
    private let operation: @Sendable (CLIRelayRequest) async throws -> CLIRelayResponse
    private let runtimeSignal: @Sendable () async -> Void
    private let activitySignal: @Sendable () async -> Void
    private let attentionSignal: @Sendable () async -> Void

    init(
        operation: @escaping @Sendable (CLIRelayRequest) async throws -> CLIRelayResponse,
        runtimeSignal: @escaping @Sendable () async -> Void,
        activitySignal: @escaping @Sendable () async -> Void,
        attentionSignal: @escaping @Sendable () async -> Void
    ) {
        self.operation = operation
        self.runtimeSignal = runtimeSignal
        self.activitySignal = activitySignal
        self.attentionSignal = attentionSignal
    }

    func bound(to client: FilterControlClient, connectionID: UUID) -> AppRelayHandler {
        let operation = operation
        let runtimeSignal = runtimeSignal
        let activitySignal = activitySignal
        let attentionSignal = attentionSignal
        return AppRelayHandler(operation: { request in
            try await client.requireCurrentConnection(connectionID)
            return try await operation(request)
        }, runtimeSignal: {
            guard (try? await client.requireCurrentConnection(connectionID)) != nil else { return }
            await runtimeSignal()
        }, activitySignal: {
            guard (try? await client.requireCurrentConnection(connectionID)) != nil else { return }
            await activitySignal()
        }, attentionSignal: {
            guard (try? await client.requireCurrentConnection(connectionID)) != nil else { return }
            await attentionSignal()
        })
    }

    func performCLIRequest(
        _ request: SecureIPCEnvelope,
        withReply reply: @escaping (SecureIPCReply) -> Void
    ) {
        let operation = self.operation
        let reply = AppRelayReply(reply)
        Task {
            do {
                guard request.messageKind == .cliRequest,
                      request.protocolVersion.isCompatible(with: .current) else {
                    throw ArchiveControllerError.invalidRelayRequest
                }
                let value = try SecureIPCCodec.decode(CLIRelayRequest.self, from: request.payload)
                let response = try await operation(value)
                reply.call(SecureIPCReply(
                    requestID: request.requestID,
                    status: .success,
                    payload: try SecureIPCCodec.encode(response)
                ))
            } catch {
                reply.call(SecureIPCReply(
                    requestID: request.requestID,
                    status: .rejected,
                    redactedErrorCode: String(describing: type(of: error))
                ))
            }
        }
    }

    func runtimeDataAvailable(withReply reply: @escaping () -> Void) {
        let signal = runtimeSignal
        let reply = AppRelayVoidReply(reply)
        Task {
            await signal()
            reply.call()
        }
    }

    func runtimeActivityAvailable(withReply reply: @escaping () -> Void) {
        let signal = activitySignal
        let reply = AppRelayVoidReply(reply)
        Task { await signal(); reply.call() }
    }

    func runtimeAttentionAvailable(withReply reply: @escaping () -> Void) {
        let signal = attentionSignal
        let reply = AppRelayVoidReply(reply)
        Task { await signal(); reply.call() }
    }
}

private final class AppRelayReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((SecureIPCReply) -> Void)?

    init(_ handler: @escaping (SecureIPCReply) -> Void) {
        self.handler = handler
    }

    func call(_ reply: SecureIPCReply) {
        let pending = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?(reply)
    }
}

private final class AppRelayVoidReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        let pending = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?()
    }
}
