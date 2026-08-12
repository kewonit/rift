import Foundation
import XCTest
@testable import AbyssCore

final class CrossArchitectureGoldenXCTest: XCTestCase {
    func testCanonicalSnapshotMatchesGoldenFixture() throws {
        let rule = try RuleTestSupport.rule(
            id: 3_000,
            action: .filter(.deny),
            lineageID: RuleTestSupport.uuid(44),
            destination: .normalizedDomainSet([try DomainName("example.com")]),
            port: try PortRange(443, 443)
        )
        let snapshot = try PolicySnapshot(
            lineageID: RuleTestSupport.uuid(44),
            generation: 7,
            rules: [rule]
        )
        let encoded = try CanonicalPolicyJSON.encoder().encode(snapshot)
        let goldenURL = try XCTUnwrap(Bundle.module.url(
            forResource: "policy-snapshot-v1",
            withExtension: "json"
        ))
        let golden = try Data(contentsOf: goldenURL)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            String(decoding: golden, as: UTF8.self).trimmingCharacters(in: .newlines)
        )
    }
}
