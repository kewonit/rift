import RiftControl
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum GeoFileAccess {
    static func importCSV(to destination: URL) async throws -> GeoDatabaseMetadata? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose an extracted DB-IP City Lite CSV file. The lookup stays local."
        guard await panel.begin() == .OK, let source = panel.url else { return nil }

        defer { source.stopAccessingSecurityScopedResource() }
        let values = try validatedValues(for: source)
        let version = GeoCSVImporter.versionLabel(
            filename: source.lastPathComponent,
            modifiedAt: values.contentModificationDate
        )
        let sourceDate = GeoCSVImporter.sourceDate(
            filename: source.lastPathComponent,
            modifiedAt: values.contentModificationDate
        )
        return try await Task.detached(priority: .utility) {
            try coordinatedImport(
                from: source,
                to: destination,
                version: version,
                modifiedAt: sourceDate
            )
        }.value
    }

    nonisolated private static func coordinatedImport(
        from source: URL,
        to destination: URL,
        version: String,
        modifiedAt: Date?
    ) throws -> GeoDatabaseMetadata {
        var coordinationError: NSError?
        var result: Result<GeoDatabaseMetadata, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: source,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                _ = try validatedValues(for: coordinatedURL)
                result = .success(try GeoCSVImporter.importFile(
                    from: coordinatedURL,
                    to: destination,
                    sourceVersion: version,
                    sourceModifiedAt: modifiedAt
                ))
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw GeoFileAccessError.coordinationFailed }
        return try result.get()
    }

    nonisolated private static func validatedValues(
        for url: URL
    ) throws -> URLResourceValues {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= GeoCSVImporter.maximumFileBytes else {
            throw GeoFileAccessError.invalidFile
        }
        return values
    }
}

private enum GeoFileAccessError: Error {
    case invalidFile
    case coordinationFailed
}
