import Foundation
import Testing
@testable import RiftCore

private let vectors: [(unicode: String, aLabel: String)] = [
    ("bücher", "xn--bcher-kva"),
    ("münchen", "xn--mnchen-3ya"),
    ("faß", "xn--fa-hia"),
    ("例え", "xn--r8jz45g"),
    ("пример", "xn--e1afmkfd"),
]

@Test func punycodeRoundTripsKnownLabels() throws {
    for vector in vectors {
        let scalars = Array(vector.unicode.unicodeScalars)
        let payload = Array(vector.aLabel.utf8.dropFirst(4))
        #expect(Punycode.encode(scalars) == payload)
        #expect(Punycode.decode(payload) == scalars)
        #expect(try DomainName("\(vector.aLabel).example").ascii == "\(vector.aLabel).example")
    }
}

@Test func punycodeRejectsLabelsThatArentRealALabels() {
    for input in [
        "xn--.example",
        "xn--example-.de",
        "xn--abc-.de",
        "xn--999999999999999999999999.de",
        "xn--a_b-kva.de",
    ] {
        #expect(throws: DomainNameError.self) { try DomainName(input) }
    }
}

@Test func punycodeRejectsUnicodeThatIDNAWouldNotAllow() throws {
    let refused = [
        "BÜCHER", "a\u{200B}b\u{00E9}", "\u{0301}abc\u{00E9}",
        "caf\u{00E9}\u{1F600}", "\u{00E9}\u{3002}x", "\u{00E9}!x",
        "-caf\u{00E9}", "caf\u{00E9}-", "ab--caf\u{00E9}",
    ]
    for unicode in refused {
        let encoded = try #require(Punycode.encode(Array(unicode.unicodeScalars)))
        let label = "xn--" + String(decoding: encoded, as: UTF8.self).lowercased()
        #expect(!Punycode.isValidALabel(label[...]), "accepted \(unicode)")
    }
}
