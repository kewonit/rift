import Foundation
import Testing
@testable import RiftCore

@Test func digestHexEncodingPreservesEveryByteAndCanonicalJSON() throws {
    let bytes = (0...255).map { UInt8($0) }
    let expected = bytes.map { String(format: "%02x", $0) }.joined()
    let digest = try CodeDigest(hex: expected.uppercased(), expectedByteCount: bytes.count)
    #expect(digest.description == expected)
    let encoded = try JSONEncoder().encode(digest)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected)\"")
    #expect(try JSONDecoder().decode(CodeDigest.self, from: encoded) == digest)
}
