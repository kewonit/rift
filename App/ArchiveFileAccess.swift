import RiftControl
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
            return "This disk can’t keep the file private to your account, so nothing was saved. Choose a location on your Mac’s disk."
        case .nonLocalFile:
            return "Choose a file stored on this Mac. Network and cloud-only files aren’t supported."
        case .wrongOwner, .notRegularFile, .symbolicLink:
            return "Choose a regular file that belongs to your Mac account. Links to other files aren’t supported."
        case .oversized:
            return "This file is too large for Rift to import. Nothing was changed."
        case .fileChangedWhileReading:
            return "The file changed while Rift was reading it. Nothing was changed. Try again."
        case .destinationChanged:
            return "The save location changed before Rift could save. Nothing was replaced. Try again."
        case .invalidPath, .ioFailure:
            return fallback
        }
    }
}

private enum ArchiveFileError: Error {
    case coordinationFailed
}
