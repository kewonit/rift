import Foundation

extension ControlPlaneController {
    /// Opens a database off the main actor. Opening runs migrations and an
    /// integrity check that reads the whole file, which would otherwise delay
    /// the first window.
    nonisolated static func openDatabase<Value: Sendable>(
        _ open: @escaping @Sendable () throws -> Value
    ) async -> Result<Value, any Error> {
        await Task.detached(priority: .userInitiated) { Result { try open() } }.value
    }
}
