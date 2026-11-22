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
    /// The mode, active profile and filter health, as the running app sees them.
    case statusSummary
    /// Connection history as CSV or JSON, named by the request's argument.
    /// Needs Terminal access turned on in Rift.
    case historyExportBegin
}

/// A refusal for a command that needs "Allow access from Terminal" in
/// Rift's settings. Only the type name crosses the connection.
public enum CLIAccessRefusal: Error, Sendable, Hashable {
    case terminalAccessOff

    public static let code = String(describing: CLIAccessRefusal.self)
}

/// What `riftctl status` adds from the running app.
public struct CLIAppStatus: Sendable, Hashable, Codable {
    public let mode: String
    public let profile: String?
    /// The app's one-line reading of the filter, as on the Status page.
    public let filter: String
    public let filterDetail: String

    public init(mode: String, profile: String?, filter: String, filterDetail: String) {
        self.mode = String(mode.unicodeScalars.prefix(256))
        self.profile = profile.map { String($0.unicodeScalars.prefix(256)) }
        self.filter = String(filter.unicodeScalars.prefix(256))
        self.filterDetail = String(filterDetail.unicodeScalars.prefix(1_024))
    }

    /// The lines `riftctl status` prints.
    public var lines: String {
        "Mode: \(mode)\nProfile: \(profile ?? "none")\nFilter: \(filter)"
            + (filterDetail.isEmpty ? "" : " — \(filterDetail)")
    }
}

/// A refusal the app relay returns to `riftctl`. Only the type name crosses
/// the connection, as the reply's redacted error code.
public enum CLIRelayRefusal: Error, Sendable, Hashable {
    /// The profile switch would weaken protection or needs a confirmation
    /// that only Rift can show.
    case profileSwitchNeedsConfirmation

    public static let code = String(describing: CLIRelayRefusal.self)
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
