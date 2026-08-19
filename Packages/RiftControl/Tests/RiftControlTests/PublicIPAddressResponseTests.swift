import Foundation
import RiftControl
import RiftCore
import Testing

@Test func publicIPAddressResponseAcceptsCanonicalIPv4AndIPv6() throws {
    let ipv4 = try PublicIPAddressResponse.parse(Data(" 203.0.113.8\n".utf8))
    let ipv6 = try PublicIPAddressResponse.parse(Data("2001:db8::7\r\n".utf8))
    let expectedIPv4 = try IPAddress("203.0.113.8")
    let expectedIPv6 = try IPAddress("2001:db8::7")

    #expect(ipv4 == expectedIPv4)
    #expect(ipv6 == expectedIPv6)
}

@Test func publicIPAddressResponseRejectsEmptyInvalidAndOversizedBodies() {
    #expect(throws: PublicIPAddressResponseError.empty) {
        try PublicIPAddressResponse.parse(Data())
    }
    #expect(throws: PublicIPAddressResponseError.empty) {
        try PublicIPAddressResponse.parse(Data(" \r\n".utf8))
    }
    #expect(throws: PublicIPAddressResponseError.invalidAddress) {
        try PublicIPAddressResponse.parse(Data("203.0.113.8 extra".utf8))
    }
    #expect(throws: PublicIPAddressResponseError.invalidEncoding) {
        try PublicIPAddressResponse.parse(Data([0xFF]))
    }
    #expect(throws: PublicIPAddressResponseError.tooLarge) {
        try PublicIPAddressResponse.parse(Data(repeating: 0x31, count: 65))
    }
}
