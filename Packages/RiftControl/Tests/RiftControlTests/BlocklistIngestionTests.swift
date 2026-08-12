import RiftCore
import Foundation
import Testing
@testable import RiftControl

@Suite(.serialized)
struct BlocklistIngestionTests {
    @Test func generatedNearCapInputStaysWithinParserBounds() throws {
        let input = generatedDomainInput(count: BlocklistParser.maximumEntries)
        #expect(input.count < BlocklistParser.maximumBytes)
        let clock = ContinuousClock()
        let start = clock.now
        let output = try BlocklistParser.parseInstrumented(input)
        let elapsed = start.duration(to: clock.now)

        #expect(output.entries.count == BlocklistParser.maximumEntries)
        #expect(output.metrics.inputBytes == input.count)
        #expect(output.metrics.uniqueEntryHighWater == BlocklistParser.maximumEntries)
        #expect(
            output.metrics.maximumBufferedLineBytes
                <= BlocklistParser.maximumLineBytes + 3
        )
        #expect(zip(output.entries, output.entries.dropFirst()).allSatisfy { $0.0 < $0.1 })
        print(
            "BLOCKLIST_PARSE_BENCHMARK entries=\(output.entries.count) "
                + "bytes=\(input.count) max_line_buffer="
                + "\(output.metrics.maximumBufferedLineBytes) elapsed=\(elapsed)"
        )
    }

    @Test func invalidUTF8AcrossInputChunkBoundaryIsRejectedAtItsLine() {
        var input = Data()
        input.reserveCapacity(BlocklistParser.inputChunkBytes + 1)
        for _ in 0..<(BlocklistParser.inputChunkBytes / 2 - 1) {
            input.append(contentsOf: "#\n".utf8)
        }
        input.append(0x23)
        input.append(0xC3)
        #expect(input.count == BlocklistParser.inputChunkBytes)
        input.append(0x0A)

        #expect(throws: BlocklistParserError.malformedLine(32_768)) {
            try BlocklistParser.parse(input)
        }
    }

    @Test func overlongLineIsRejectedBeforeTokenAllocation() {
        var input = Data(repeating: 0x61, count: BlocklistParser.maximumLineBytes + 1)
        input.append(0x0A)
        #expect(throws: BlocklistParserError.lineTooLong) {
            try BlocklistParser.parse(input)
        }
    }

    @Test func parserCancellationIsCooperativeAndDeterministic() {
        let input = generatedDomainInput(count: 2_000)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try BlocklistParser.parseInstrumented(input) {
                checks += 1
                if checks == 8 { throw CancellationError() }
            }
        }
        #expect(checks == 8)
    }

    @Test func duplicateStormKeepsOnlyOneCanonicalEntry() throws {
        let count = BlocklistParser.maximumEntries + 50_000
        var input = Data()
        input.reserveCapacity(count * 17)
        for _ in 0..<count {
            input.append(contentsOf: "ads.example.test\n".utf8)
        }
        #expect(input.count < BlocklistParser.maximumBytes)

        let output = try BlocklistParser.parseInstrumented(input)
        #expect(output.entries == [.domain(try DomainName("ads.example.test"))])
        #expect(output.metrics.uniqueEntryHighWater == 1)
        #expect(
            output.metrics.maximumBufferedLineBytes
                <= BlocklistParser.maximumLineBytes + 3
        )
    }

    @Test func BOMCommentsHostsAndNewlineFormsRemainCompatible() throws {
        var input = Data([0xEF, 0xBB, 0xBF])
        input.append(contentsOf: "# comment\r\n".utf8)
        input.append(contentsOf: "0.0.0.0 ads.example.test tracker.example.test\u{85}".utf8)
        input.append(contentsOf: "203.0.113.0/24\u{2028}2001:db8::1\n".utf8)

        let entries = try BlocklistParser.parse(input)
        #expect(entries == [
            .domain(try DomainName("ads.example.test")),
            .domain(try DomainName("tracker.example.test")),
            .address(try IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 24)),
            .address(IPInterval(exact: try IPAddress("2001:db8::1"))),
        ])
    }

    @Test func preparationFailuresNeverReachGenerationMutation() async throws {
        let probe = GenerationMutationProbe()
        await #expect(throws: BlocklistParserError.malformedLine(1)) {
            try await BlocklistIngestion.ingest(
                data: Data("@@bad".utf8), name: "Parse failure"
            ) { preparation in
                await probe.record(preparation)
            }
        }
        #expect(await probe.count() == 0)

        await #expect(throws: BlocklistImportError.universalAddressRange(.ipv4)) {
            try await BlocklistIngestion.ingest(
                data: Data("0.0.0.0/0\n".utf8), name: "High impact"
            ) { preparation in
                await probe.record(preparation)
            }
        }
        #expect(await probe.count() == 0)

        await #expect(throws: CancellationError.self) {
            try await BlocklistIngestion.run(
                preparation: { () async throws -> BlocklistImportPreparation in
                    throw CancellationError()
                },
                mutation: { preparation in
                    await probe.record(preparation)
                }
            )
        }
        #expect(await probe.count() == 0)

        try await BlocklistIngestion.ingest(
            data: Data("ads.example.test\n".utf8), name: "Valid"
        ) { preparation in
            await probe.record(preparation)
        }
        #expect(await probe.count() == 1)
    }
}

private actor GenerationMutationProbe {
    private var calls = 0

    func record(_ preparation: BlocklistImportPreparation) {
        _ = preparation
        calls += 1
    }

    func count() -> Int { calls }
}

private func generatedDomainInput(count: Int) -> Data {
    var data = Data()
    data.reserveCapacity(count * 24)
    for index in 0..<count {
        data.append(contentsOf: "host\(index).example.test\n".utf8)
    }
    return data
}
