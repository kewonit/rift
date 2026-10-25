import Foundation

public enum BlocklistIngestion {
    public static func ingest<Result: Sendable>(
        data: Data,
        name: String,
        mutation: @escaping @Sendable (BlocklistImportPreparation) async throws -> Result
    ) async throws -> Result {
        try await run(
            preparation: {
                try await prepare(data: data, name: name)
            },
            mutation: mutation
        )
    }

    static func run<Result: Sendable>(
        preparation: @escaping @Sendable () async throws -> BlocklistImportPreparation,
        mutation: @escaping @Sendable (BlocklistImportPreparation) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let prepared = try await preparation()
        try Task.checkCancellation()
        return try await mutation(prepared)
    }

    private static func prepare(
        data: Data,
        name: String
    ) async throws -> BlocklistImportPreparation {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let parsed = try BlocklistParser.parseInstrumented(data)
            return try BlocklistImportBuilder.prepare(
                entries: parsed.entries,
                name: name,
                contentHash: parsed.contentHash
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
