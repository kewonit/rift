import Foundation

public enum CLICommandKind: String, Sendable, Hashable, Codable {
    case rulesExportBegin
    case rulesImportBegin
    case rulesImportAppend
    case rulesImportPreviewFinish
    case diagnosticsBegin
    case transferRead
    case transferFinish
    case profilesList
    case profilesActivate
}

public struct CLIRelayRequest: Sendable, Hashable, Codable {
    public let command: CLICommandKind
    public let argument: String?
    public let payload: Data

    public init(command: CLICommandKind, argument: String? = nil, payload: Data = Data()) throws {
        guard payload.count <= IPCProtocolLimits.maximumSnapshotBytes else {
            throw CLIValueError.oversizedPayload
        }
        self.command = command
        self.argument = argument.map { String($0.unicodeScalars.prefix(256)) }
        self.payload = payload
    }
}

public struct CLIRelayResponse: Sendable, Hashable, Codable {
    public let summary: String
    public let json: Data
    public let payload: Data

    public init(summary: String, json: Data = Data(), payload: Data = Data()) throws {
        guard json.count <= 1 * 1_024 * 1_024,
              payload.count <= IPCProtocolLimits.maximumSnapshotBytes else {
            throw CLIValueError.oversizedPayload
        }
        self.summary = String(summary.unicodeScalars.prefix(4_096))
        self.json = json
        self.payload = payload
    }
}

public enum CLIValueError: Error, Sendable, Equatable {
    case oversizedPayload
    case invalidTransfer
}

public struct CLITransferDescriptor: Sendable, Hashable, Codable {
    public let transferID: UUID
    public let totalBytes: Int

    public init(transferID: UUID = UUID(), totalBytes: Int) throws {
        guard totalBytes >= 0, totalBytes <= IPCProtocolLimits.maximumSnapshotBytes else {
            throw CLIValueError.invalidTransfer
        }
        self.transferID = transferID
        self.totalBytes = totalBytes
    }
}

public struct CLITransferChunk: Sendable, Hashable, Codable {
    public let transferID: UUID
    public let offset: Int
    public let bytes: Data

    public init(transferID: UUID, offset: Int, bytes: Data) throws {
        guard offset >= 0, bytes.count <= IPCProtocolLimits.maximumChunkBytes else {
            throw CLIValueError.invalidTransfer
        }
        self.transferID = transferID
        self.offset = offset
        self.bytes = bytes
    }
}

public struct CLITransferRead: Sendable, Hashable, Codable {
    public let transferID: UUID
    public let offset: Int
    public let maximumBytes: Int

    public init(transferID: UUID, offset: Int, maximumBytes: Int) throws {
        guard offset >= 0, maximumBytes > 0,
              maximumBytes <= IPCProtocolLimits.maximumChunkBytes else {
            throw CLIValueError.invalidTransfer
        }
        self.transferID = transferID
        self.offset = offset
        self.maximumBytes = maximumBytes
    }
}

public struct CLITransferFinish: Sendable, Hashable, Codable {
    public let transferID: UUID

    public init(transferID: UUID) {
        self.transferID = transferID
    }
}
