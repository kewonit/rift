import RiftIPC
import ArgumentParser
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct RiftCTL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "riftctl",
        abstract: "Inspect and manage the installed Rift firewall.",
        subcommands: [Status.self, Rules.self, Profiles.self, Diagnostics.self]
    )

    struct Status: AsyncParsableCommand {
        @Flag(name: .long, help: "Emit stable JSON.") var json = false

        mutating func run() async throws {
            let state = try await CLIServiceClient.withConnected { client in
                try await client.health()
            }
            if json {
                try CLIOutput.writeJSON(state)
            } else {
                try CLIOutput.write("Provider: \(state.readiness.rawValue)\n"
                    + "Epoch: \(state.providerEpoch?.uuidString.lowercased() ?? "none")\n"
                    + "Persisted generation: \(state.persisted.map { String($0.generation) } ?? "none")\n"
                    + "Active generation: \(state.active.map { String($0.generation) } ?? "none")")
            }
        }
    }

    struct Rules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [Export.self, Import.self])

        struct Export: AsyncParsableCommand {
            @Argument(help: "New absolute destination path.") var path: String

            mutating func run() async throws {
                try await CLIServiceClient.withConnected { client in
                    let writer = try CLIFileAccess.beginCreate(path: path)
                    let begin = try await client.beginDownload(
                        command: .rulesExportBegin, launchingAppIfNeeded: true
                    )
                    do {
                        try await CLITransferPump.download(
                            totalBytes: begin.descriptor.totalBytes,
                            maximumChunkBytes: IPCProtocolLimits.maximumChunkBytes,
                            fetch: { offset, _ in
                                try await client.downloadChunk(
                                    descriptor: begin.descriptor, offset: offset
                                )
                            },
                            write: writer.append
                        )
                        try writer.finish()
                        try await client.cancelTransfer(begin.descriptor.transferID)
                        try CLIOutput.write(begin.summary)
                    } catch {
                        writer.abort()
                        try? await client.cancelTransfer(begin.descriptor.transferID)
                        throw error
                    }
                }
            }
        }

        struct Import: AsyncParsableCommand {
            @Argument(help: "Absolute configuration archive path.") var path: String
            @Flag(name: .long, help: "Validate and preview without applying.") var dryRun = false

            mutating func validate() throws {
                guard dryRun else {
                    throw ValidationError("Core 1.0 CLI import is preview-only; pass --dry-run.")
                }
            }

            mutating func run() async throws {
                try await CLIServiceClient.withConnected { client in
                    let input = try CLIFileAccess.beginRead(
                        path: path,
                        maximumBytes: IPCProtocolLimits.maximumSnapshotBytes
                    )
                    let descriptor = try await client.beginImport(
                        totalBytes: input.totalBytes,
                        launchingAppIfNeeded: true
                    )
                    do {
                        try await CLITransferPump.upload(
                            totalBytes: descriptor.totalBytes,
                            maximumChunkBytes: IPCProtocolLimits.maximumChunkBytes,
                            read: input.readChunk,
                            send: { chunk, offset in
                                try await client.appendImport(
                                    chunk, descriptor: descriptor, offset: offset
                                )
                            }
                        )
                        try input.finish()
                        let response = try await client.finishImport(descriptor)
                        try CLIOutput.write(response.summary)
                    } catch {
                        try? await client.cancelTransfer(descriptor.transferID)
                        throw error
                    }
                }
            }
        }
    }

    struct Profiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [List.self, Activate.self])

        struct List: AsyncParsableCommand {
            @Flag(name: .long, help: "Emit stable JSON.") var json = false

            mutating func run() async throws {
                let response = try await CLIServiceClient.withConnected { client in
                    try await client.relay(
                        try CLIRelayRequest(command: .profilesList),
                        launchingAppIfNeeded: true
                    )
                }
                if json { try CLIOutput.writeRawJSON(response.json) }
                else { try CLIOutput.write(response.summary) }
            }
        }

        struct Activate: AsyncParsableCommand {
            @Argument(help: "Profile UUID, exact name, or 'none'.") var profile: String

            mutating func run() async throws {
                let response = try await CLIServiceClient.withConnected { client in
                    try await client.relay(
                        try CLIRelayRequest(command: .profilesActivate, argument: profile),
                        launchingAppIfNeeded: true
                    )
                }
                try CLIOutput.write(response.summary)
            }
        }
    }

    struct Diagnostics: AsyncParsableCommand {
        @Argument(help: "New absolute destination path.") var path: String

        mutating func run() async throws {
            try await CLIServiceClient.withConnected { client in
                let writer = try CLIFileAccess.beginCreate(path: path)
                let begin = try await client.beginDownload(
                    command: .diagnosticsBegin, launchingAppIfNeeded: true
                )
                do {
                    try await CLITransferPump.download(
                        totalBytes: begin.descriptor.totalBytes,
                        maximumChunkBytes: IPCProtocolLimits.maximumChunkBytes,
                        fetch: { offset, _ in
                            try await client.downloadChunk(
                                descriptor: begin.descriptor, offset: offset
                            )
                        },
                        write: writer.append
                    )
                    try writer.finish()
                    try await client.cancelTransfer(begin.descriptor.transferID)
                    try CLIOutput.write(begin.summary)
                } catch {
                    writer.abort()
                    try? await client.cancelTransfer(begin.descriptor.transferID)
                    throw error
                }
            }
        }
    }
}

enum CLIOutput {
    static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writeData(try encoder.encode(value))
    }

    static func writeRawJSON(_ data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        try writeData(data)
    }

    static func write(_ value: String) throws {
        let safe = value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || (!CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains(scalar))
        }
        try writeData(Data(String(String.UnicodeScalarView(safe)).utf8))
    }

    private static func writeData(_ data: Data) throws {
        var value = data
        if value.last != 0x0A { value.append(0x0A) }
        try FileHandle.standardOutput.write(contentsOf: value)
    }
}
