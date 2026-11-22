import Foundation
import RiftCore
import Testing
@testable import RiftControl

private let samplePolicy = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationDescription</key>
    <string>DESCRIPTION_KEY</string>
    <key>DeveloperName</key>
    <string>Example Developer</string>
    <key>Connections</key>
    <array>
        <dict>
            <key>Host</key>
            <string>updates.example.com</string>
            <key>NetworkProtocol</key>
            <string>TCP</string>
            <key>Port</key>
            <string>443</string>
            <key>Purpose</key>
            <string>Checks for [new versions](https://example.com/help) of the app.</string>
            <key>DenyConsequences</key>
            <string>You won’t hear about updates.</string>
        </dict>
        <dict>
            <key>Host</key>
            <string>*.example.com, 203.0.113.0/24</string>
            <key>Purpose</key>
            <string>Syncs your documents.</string>
            <key>Services</key>
            <array>
                <dict>
                    <key>Name</key>
                    <string>CloudKit</string>
                    <key>Purpose</key>
                    <string>Stores documents.</string>
                </dict>
            </array>
        </dict>
        <dict>
            <key>Host</key>
            <string>cdn*.example.net</string>
            <key>Relevance</key>
            <string>Essential</string>
            <key>Purpose</key>
            <string>Downloads artwork.</string>
        </dict>
        <dict>
            <key>Host</key>
            <string>=*.example.org</string>
            <key>Purpose</key>
            <string>Everything under example.org.</string>
        </dict>
        <dict>
            <key>Host</key>
            <string>local-net</string>
            <key>IsIncoming</key>
            <true/>
            <key>Port</key>
            <string>5000-5010</string>
            <key>Purpose</key>
            <string>Lets other Macs nearby connect.</string>
        </dict>
        <dict>
            <key>Host</key>
            <string>*</string>
            <key>Purpose</key>
            <string>Anything else.</string>
        </dict>
    </array>
</dict>
</plist>
"""

private func policy() throws -> InternetAccessPolicy {
    try InternetAccessPolicy.decode(
        Data(samplePolicy.utf8), strings: ["DESCRIPTION_KEY": "Writes\nnotes."], appName: "Example"
    )
}

private func query(
    _ host: String?, address: String = "198.51.100.1", port: UInt16? = 443,
    transport: TransportProtocol = .tcp, incoming: Bool = false, local: Bool = false,
    choice: InternetAccessPolicyQuery.Choice = .thisConnection
) throws -> InternetAccessPolicyQuery {
    InternetAccessPolicyQuery(
        host: host, address: try IPAddress(address), isLocalNetwork: local, port: port,
        transport: transport, isIncoming: incoming, choice: choice
    )
}

private func purposes(_ explanation: DeveloperExplanation) -> [String] {
    explanation.connections.map(\.purpose)
}

@Test func aPolicyFileReadsWithTranslationsAndPlainText() throws {
    let policy = try policy()
    #expect(policy.applicationDescription == "Writes notes.")
    #expect(policy.developerName == "Example Developer")
    #expect(policy.connections.count == 6)
    // A Markdown link keeps its words and loses its address.
    #expect(policy.connections[0].purpose == "Checks for new versions of the app.")
    #expect(policy.connections[0].ports == [443...443])
    #expect(policy.connections[0].networkProtocol == .tcp)
    #expect(policy.connections[1].services == [.init(name: "CloudKit", purpose: "Stores documents.")])
    #expect(policy.connections[2].isEssential)
    #expect(policy.connections[4].isIncoming)
}

@Test func theSameFileReadsAsJSON() throws {
    let json = """
    {"ApplicationDescription": "Notes", "Connections": [
      {"Host": "api.example.com", "IsIncoming": false, "Purpose": "Signs you in.", "Port": 443}
    ]}
    """
    let policy = try InternetAccessPolicy.decode(Data(json.utf8))
    #expect(policy.connections.first?.ports == [443...443])
    #expect(throws: InternetAccessPolicyError.missingDescription) {
        try InternetAccessPolicy.decode(Data(#"{"Connections": []}"#.utf8))
    }
    #expect(throws: InternetAccessPolicyError.tooLarge) {
        try InternetAccessPolicy.decode(Data(count: InternetAccessPolicy.maximumBytes + 1))
    }
}

@Test func anExactHostWinsOverDomainsAndTheFallback() throws {
    let policy = try policy()
    let exact = policy.explanation(for: try query("updates.example.com"))
    #expect(purposes(exact) == ["Checks for new versions of the app."])
    #expect(exact.denyConsequences == ["You won’t hear about updates."])
    // The same host on another port isn't the described connection.
    #expect(purposes(policy.explanation(for: try query("updates.example.com", port: 80)))
        == ["Syncs your documents."])
}

@Test func domainsAndAddressRangesMatchWithEssentialOnesFirst() throws {
    let policy = try policy()
    #expect(purposes(policy.explanation(for: try query("example.com"))) == ["Syncs your documents."])
    #expect(purposes(policy.explanation(for: try query("www.example.com"))) == ["Syncs your documents."])
    #expect(purposes(policy.explanation(for: try query(nil, address: "203.0.113.9"))) == ["Syncs your documents."])
    #expect(purposes(policy.explanation(for: try query("cdn7.example.net"))) == ["Downloads artwork."])
    #expect(purposes(policy.explanation(for: try query("www.example.net"))) == ["Anything else."])
}

@Test func anExactDomainAppliesOnlyWhenThatDomainIsChosen() throws {
    let policy = try policy()
    #expect(purposes(policy.explanation(for: try query("www.example.org"))) == ["Anything else."])
    #expect(purposes(policy.explanation(for: try query("www.example.org", choice: .domain("example.org"))))
        == ["Everything under example.org."])
}

@Test func directionProtocolAndPortsNarrowADescription() throws {
    let policy = try policy()
    let nearby = try query(nil, address: "192.168.1.4", port: 5005, incoming: true, local: true)
    #expect(purposes(policy.explanation(for: nearby)) == ["Lets other Macs nearby connect."])
    let otherPort = try query(nil, address: "192.168.1.4", port: 6000, incoming: true, local: true)
    #expect(policy.explanation(for: otherPort).describesConnection == false)
    // UDP to the update host isn't the TCP connection the developer described.
    #expect(purposes(policy.explanation(for: try query("updates.example.com", transport: .udp)))
        == ["Syncs your documents."])
}

@Test func hostsThatCantBeMatchedNeverMatchEverything() {
    #expect(InternetAccessPolicyHost("bpf") == .unsupported)
    #expect(InternetAccessPolicyHost("not a host") == .unsupported)
    #expect(InternetAccessPolicyHost("UPDATES.Example.COM") == .name("updates.example.com"))
    #expect(InternetAccessPolicy.portRanges("80, 70-60") == nil)
    #expect(InternetAccessPolicy.portRanges("0-65535") == [])
    #expect(InternetAccessPolicyHost.glob("a*b*c", matches: "axxbyyc"))
    #expect(!InternetAccessPolicyHost.glob("a*b", matches: "ac"))
}

@Test func developerTextIsBoundedAndPlain() {
    let long = String(repeating: "word ", count: 500)
    #expect(InternetAccessPolicy.plainText(long).unicodeScalars.count == InternetAccessPolicy.maximumTextScalars)
    #expect(InternetAccessPolicy.plainText("a\u{202E}b [c] (d)") == "ab [c] (d)")
}
