import AbyssIPC
import AppKit
import Foundation

enum CLIServiceError: Error, Sendable {
    case missingConfiguration
    case unsignedBuild
    case unavailable
    case rejected(String?)
    case invalidReply
    case appLaunchFailed
    case timeout
}

actor CLIServiceClient {
    private var connection: NSXPCConnection?

    static func connected() async throws -> CLIServiceClient {
        let client = CLIServiceClient()
        try await client.connect()
        return client
    }

    static func withConnected<Result>(
        _ operation: (CLIServiceClient) async throws -> Result
    ) async throws -> Result {
        let client = try await connected()
        do {
            let result = try await operation(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func connect() throws {
        guard connection == nil else { return }
        guard let serviceName = Bundle.main.object(
            forInfoDictionaryKey: "AbyssMachServiceName"
        ) as? String, !serviceName.isEmpty else {
            throw CLIServiceError.missingConfiguration
        }
        guard let requirement = Self.extensionCodeSigningRequirement() else {
            throw CLIServiceError.unsignedBuild
        }
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: AbyssFilterControlXPC.self)
        connection.setCodeSigningRequirement(requirement)
        connection.activate()
        self.connection = connection
    }

    private func disconnect() {
        let activeConnection = connection
        connection = nil
        activeConnection?.invalidate()
    }

    func health() async throws -> HandshakeState {
        let request = SecureIPCEnvelope(kind: .health)
        let reply = try await call(request) { $0.health($1, withReply: $2) }
        return try decode(HandshakeState.self, reply: reply)
    }

    func relay(
        _ value: CLIRelayRequest,
        launchingAppIfNeeded: Bool
    ) async throws -> CLIRelayResponse {
        let request = SecureIPCEnvelope(
            kind: .cliRequest,
            payload: try SecureIPCCodec.encode(value)
        )
        do {
            return try await relay(request)
        } catch CLIServiceError.rejected(let code)
            where launchingAppIfNeeded && code == "sameUserAppUnavailable" {
            guard NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Abyss.app")) else {
                throw CLIServiceError.appLaunchFailed
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(200))
                if let response = try? await relay(request) { return response }
            }
            throw CLIServiceError.rejected("sameUserAppUnavailable")
        }
    }

    func beginDownload(
        command: CLICommandKind,
        launchingAppIfNeeded: Bool
    ) async throws -> (summary: String, descriptor: CLITransferDescriptor) {
        let begin = try await relay(
            try CLIRelayRequest(command: command),
            launchingAppIfNeeded: launchingAppIfNeeded
        )
        let descriptor = try SecureIPCCodec.decode(CLITransferDescriptor.self, from: begin.payload)
        return (begin.summary, descriptor)
    }

    func downloadChunk(
        descriptor: CLITransferDescriptor,
        offset: Int
    ) async throws -> Data {
        let read = try CLITransferRead(
            transferID: descriptor.transferID,
            offset: offset,
            maximumBytes: IPCProtocolLimits.maximumChunkBytes
        )
        let response = try await relay(
            try CLIRelayRequest(
                command: .transferRead,
                payload: try SecureIPCCodec.encode(read)
            ),
            launchingAppIfNeeded: false
        )
        let chunk = try SecureIPCCodec.decode(CLITransferChunk.self, from: response.payload)
        guard chunk.transferID == descriptor.transferID,
              chunk.offset == offset,
              !chunk.bytes.isEmpty,
              offset + chunk.bytes.count <= descriptor.totalBytes else {
            throw CLIServiceError.invalidReply
        }
        return chunk.bytes
    }

    func beginImport(totalBytes: Int, launchingAppIfNeeded: Bool) async throws -> CLITransferDescriptor {
        let descriptor = try CLITransferDescriptor(totalBytes: totalBytes)
        _ = try await relay(
            try CLIRelayRequest(
                command: .rulesImportBegin,
                payload: try SecureIPCCodec.encode(descriptor)
            ),
            launchingAppIfNeeded: launchingAppIfNeeded
        )
        return descriptor
    }

    func appendImport(_ data: Data, descriptor: CLITransferDescriptor, offset: Int) async throws {
        let chunk = try CLITransferChunk(
            transferID: descriptor.transferID,
            offset: offset,
            bytes: data
        )
        _ = try await relay(
            try CLIRelayRequest(
                command: .rulesImportAppend,
                payload: try SecureIPCCodec.encode(chunk)
            ),
            launchingAppIfNeeded: false
        )
    }

    func finishImport(_ descriptor: CLITransferDescriptor) async throws -> CLIRelayResponse {
        try await relay(
            try CLIRelayRequest(
                command: .rulesImportPreviewFinish,
                payload: try SecureIPCCodec.encode(
                    CLITransferFinish(transferID: descriptor.transferID)
                )
            ),
            launchingAppIfNeeded: false
        )
    }

    func cancelTransfer(_ transferID: UUID) async throws {
        _ = try await relay(
            try CLIRelayRequest(
                command: .transferFinish,
                payload: try SecureIPCCodec.encode(CLITransferFinish(transferID: transferID))
            ),
            launchingAppIfNeeded: false
        )
    }

    private func relay(_ request: SecureIPCEnvelope) async throws -> CLIRelayResponse {
        let reply = try await call(request) { $0.cliRequest($1, withReply: $2) }
        return try decode(CLIRelayResponse.self, reply: reply)
    }

    private func call(
        _ request: SecureIPCEnvelope,
        invoke: @escaping (AbyssFilterControlXPC, SecureIPCEnvelope, @escaping (SecureIPCReply) -> Void) -> Void
    ) async throws -> SecureIPCReply {
        guard let connection else { throw CLIServiceError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = CLIContinuationGate(continuation, timeout: .seconds(5))
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? AbyssFilterControlXPC else {
                gate.fail(CLIServiceError.unavailable)
                return
            }
            invoke(proxy, request) { gate.succeed($0) }
        }
    }

    private func decode<Value: Codable>(
        _ type: Value.Type,
        reply: SecureIPCReply
    ) throws -> Value {
        guard reply.status == .success else {
            throw CLIServiceError.rejected(reply.redactedErrorCode)
        }
        do { return try SecureIPCCodec.decode(type, from: reply.payload) }
        catch { throw CLIServiceError.invalidReply }
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

private final class CLIContinuationGate: @unchecked Sendable {
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
            self?.fail(CLIServiceError.timeout)
        }
    }

    func succeed(_ reply: SecureIPCReply) { take()?.resume(returning: reply) }
    func fail(_ error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<SecureIPCReply, Error>? {
        lock.withLock {
            timeoutTask?.cancel()
            timeoutTask = nil
            defer { continuation = nil }
            return continuation
        }
    }
}
