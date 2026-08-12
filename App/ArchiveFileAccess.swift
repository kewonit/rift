import AbyssControl
import AppKit
import Foundation

@MainActor
enum ArchiveFileAccess {
    static func save(data: Data, suggestedName: String) async throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try SecureArchiveFile.writeReplacing(data, at: coordinatedURL)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    static func open(maximumBytes: Int = 16 * 1_024 * 1_024) async throws -> Data? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            do {
                result = .success(try SecureArchiveFile.readSnapshot(
                    at: $0,
                    maximumBytes: maximumBytes
                ))
            } catch { result = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ArchiveFileError.coordinationFailed }
        return try result.get()
    }

    static func message(for error: any Error, fallback: String) -> String {
        guard let error = error as? SecureArchiveFileError else { return fallback }
        switch error {
        case .ownerOnlyPermissionsUnsupported:
            return "This volume cannot enforce owner-only permissions. Nothing was replaced. Choose a local Mac-formatted volume."
        case .nonLocalFile:
            return "Choose a regular file on a local volume. Network and cloud-only files are not accepted."
        case .wrongOwner, .notRegularFile, .symbolicLink:
            return "Choose a regular, non-symlink file owned by your macOS account."
        case .oversized:
            return "The selected file exceeds Abyss’s safe import limit. Nothing was changed."
        case .fileChangedWhileReading:
            return "The selected file changed while it was being read. Nothing was changed."
        case .destinationChanged:
            return "The selected destination changed before saving. Nothing was replaced."
        case .invalidPath, .ioFailure:
            return fallback
        }
    }
}

private enum ArchiveFileError: Error {
    case coordinationFailed
}
