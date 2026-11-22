import Foundation
import RiftCore
import RiftIPC

/// The process rows that an alert's Details and the Map inspector share, so
/// both name the same things the same way.
public enum ProcessDetailsPresentation {
    public struct Row: Sendable, Hashable, Identifiable {
        public let title: String
        public let value: String
        /// A file path, which wants a monospaced face and middle truncation.
        public let isPath: Bool

        public var id: String { title }
    }

    /// With one process, its ID and path. When a helper connected for an
    /// app, both, each labelled, because the helper's path is often what
    /// tells two connections from the same app apart.
    public static func rows(for details: FlowProcessDetails?) -> [Row] {
        guard let details else { return [] }
        guard let app = details.app else {
            return details.process.map { rows(for: $0, role: nil) } ?? []
        }
        return rows(for: app, role: .app)
            + (details.process.map { rows(for: $0, role: .helper) } ?? [])
    }

    private enum Role { case app, helper }

    private static func rows(for process: ObservedProcess, role: Role?) -> [Row] {
        let idTitle = switch role {
        case nil: String(localized: "Process ID", bundle: .module)
        case .app: String(localized: "App process ID", bundle: .module)
        case .helper: String(localized: "Helper process ID", bundle: .module)
        }
        var rows = [Row(
            title: idTitle,
            value: String(process.processID),
            isPath: false
        )]
        if let path = process.executablePath {
            let pathTitle = switch role {
            case nil: String(localized: "Path", bundle: .module)
            case .app: String(localized: "App path", bundle: .module)
            case .helper: String(localized: "Helper path", bundle: .module)
            }
            rows.append(Row(
                title: pathTitle,
                value: DisplaySanitizer.plainText(path, maximumScalars: ObservedProcess.maximumPathScalars),
                isPath: true
            ))
        }
        return rows
    }
}
