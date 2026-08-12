import RiftCore
import Foundation

public enum PolicyDefinitionError: Error, Sendable, Equatable {
    case emptyName
    case nameTooLong
    case noteTooLong
    case duplicateName
}

public enum PolicyDefinitionValidator {
    public static func name(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolicyDefinitionError.emptyName }
        guard trimmed.unicodeScalars.count <= 128 else { throw PolicyDefinitionError.nameTooLong }
        return trimmed
    }

    public static func note(_ value: String) throws -> String {
        guard value.unicodeScalars.count <= PolicyLimits.maximumNotesScalars else {
            throw PolicyDefinitionError.noteTooLong
        }
        return value
    }

    public static func rejectCollision(
        _ name: String,
        existing: [(id: UUID, name: String)],
        excludingID: UUID? = nil
    ) throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        guard !existing.contains(where: {
            $0.id != excludingID
                && $0.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: locale
                ) == key
        }) else { throw PolicyDefinitionError.duplicateName }
    }
}

public struct LocalRuleGroup: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let note: String
    public let isEnabled: Bool
    public let createdAt: Date
    public let modifiedAt: Date

    public init(id: UUID, name: String, note: String, isEnabled: Bool, createdAt: Date, modifiedAt: Date) {
        self.id = id
        self.name = String(name.unicodeScalars.prefix(128))
        self.note = String(note.unicodeScalars.prefix(PolicyLimits.maximumNotesScalars))
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public struct PolicyProfile: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let symbolName: String?
    public let operationModeOverride: OperationMode?
    public let createdAt: Date
    public let modifiedAt: Date

    public init(
        id: UUID,
        name: String,
        symbolName: String?,
        operationModeOverride: OperationMode?,
        createdAt: Date,
        modifiedAt: Date
    ) {
        self.id = id
        self.name = String(name.unicodeScalars.prefix(128))
        self.symbolName = symbolName.map { String($0.prefix(64)) }
        self.operationModeOverride = operationModeOverride
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum BlocklistSourceStatus: String, Sendable, Hashable, Codable {
    case active
    case disabled
}

public struct BlocklistSource: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let importedAt: Date
    public let entryCount: Int
    public let domainEntryCount: Int?
    public let addressEntryCount: Int?
    public let contentHash: Data
    public let status: BlocklistSourceStatus

    public init(
        id: UUID,
        name: String,
        importedAt: Date,
        entryCount: Int,
        domainEntryCount: Int? = nil,
        addressEntryCount: Int? = nil,
        contentHash: Data,
        status: BlocklistSourceStatus
    ) {
        self.id = id
        self.name = String(name.unicodeScalars.prefix(128))
        self.importedAt = importedAt
        self.entryCount = max(0, entryCount)
        self.domainEntryCount = domainEntryCount.map { max(0, $0) }
        self.addressEntryCount = addressEntryCount.map { max(0, $0) }
        self.contentHash = contentHash
        self.status = status
    }
}
