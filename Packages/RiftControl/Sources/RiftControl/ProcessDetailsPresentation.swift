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
            return details.process.map { rows(for: $0, prefix: nil) } ?? []
        }
        return rows(for: app, prefix: "App")
            + (details.process.map { rows(for: $0, prefix: "Helper") } ?? [])
    }

    private static func rows(for process: ObservedProcess, prefix: String?) -> [Row] {
        var rows = [Row(
            title: prefix.map { "\($0) process ID" } ?? "Process ID",
            value: String(process.processID),
            isPath: false
        )]
        if let path = process.executablePath {
            rows.append(Row(
                title: prefix.map { "\($0) path" } ?? "Path",
                value: DisplaySanitizer.plainText(path, maximumScalars: ObservedProcess.maximumPathScalars),
                isPath: true
            ))
        }
        return rows
    }
}
