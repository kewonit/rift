import Foundation

/// One running process as the filter saw it when a connection started.
public struct ObservedProcess: Sendable, Hashable, Codable {
    public static let maximumPathScalars = 1_024

    public let processID: Int32
    /// Nil when the process had already exited or macOS wouldn't say.
    public let executablePath: String?

    /// Nil for a process ID no process can have. A path that isn't absolute,
    /// is too long, or holds control characters is left out.
    public init?(processID: Int32, executablePath: String?) {
        guard processID > 0 else { return nil }
        self.processID = processID
        self.executablePath = executablePath.flatMap(Self.acceptedPath)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = ObservedProcess(
            processID: try values.decode(Int32.self, forKey: .processID),
            executablePath: try values.decodeIfPresent(String.self, forKey: .executablePath)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .processID,
                in: values,
                debugDescription: "A process ID must be positive."
            )
        }
        self = value
    }

    private static func acceptedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              path.unicodeScalars.count <= maximumPathScalars,
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return path
    }

    private enum CodingKeys: String, CodingKey {
        case processID, executablePath
    }
}

/// The processes behind a connection. Protocol 1.4 adds them to prompts and
/// decision events, so the alert and the Map can show a process ID and the
/// full path of what's running, not only who signed it.
public struct FlowProcessDetails: Sendable, Hashable, Codable {
    /// The process that opened the connection.
    public let process: ObservedProcess?
    /// The app it was acting for, when that's a different process.
    public let app: ObservedProcess?

    /// Nil when neither process is known, so an empty value never travels.
    public init?(process: ObservedProcess?, app: ObservedProcess?) {
        guard process != nil || app != nil else { return nil }
        self.process = process
        self.app = app == process ? nil : app
    }
}
