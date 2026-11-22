import Foundation
import RiftCore
import Testing
@testable import RiftControl

private let safari = ProcessIdentity.applePlatform(
    try! SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.Safari")
)
private let notes = ProcessIdentity.developerID(
    try! SignedCodeIdentity(teamIdentifier: "TEAM123456", signingIdentifier: "com.example.notes")
)
private let safariPath = "/Applications/Safari.app/Contents/MacOS/Safari"

private let paths: LSRulesWriter.PathResolver = { identity in identity == safari ? safariPath : nil }
private let resolver: LSRulesConverter.Resolver = { process in
    switch process {
    case .path(safariPath): safari
    case .codeID(let team, let identifier):
        .developerID(try! SignedCodeIdentity(teamIdentifier: team, signingIdentifier: identifier))
    default: nil
    }
}

private func rule(
    _ action: FilterAction = .allow,
    process: ProcessCondition = .exact(notes),
    destination: DestinationCondition = .anyEndpoint,
    transport: ProtocolCondition = .anySupportedProtocol,
    port: PortRange? = nil,
    direction: DirectionCondition = .outgoing,
    owner: OwnerCondition = .authorizedUser,
    profileID: UUID? = nil,
    expiresAt: Date? = nil,
    enabled: Bool = true,
    notes text: String = ""
) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(action), priority: .normal,
        process: process, destination: destination, transportProtocol: transport, port: port,
        direction: direction, owner: owner, profileID: profileID, expiresAt: expiresAt,
        isEnabled: enabled, notes: text,
        createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1)
    )
}

@Test func exportedRulesReadBackAsTheSameRules() throws {
    let originals = [
        try rule(.allow, destination: .normalizedExactHostnameSet([DomainName("sync.example.com")]),
                 transport: .tcp, port: PortRange(443, 443), notes: "Sync"),
        try rule(.deny, process: .exact(safari), destination: .normalizedDomainSet([DomainName("tracker.example")])),
        try rule(.deny, process: .anyProcess,
                 destination: .normalizedIPSet([IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 24)]),
                 transport: .udp, port: PortRange(1_000, 2_000), enabled: false),
        try rule(.allow, destination: .endpointClass(.localNetwork), direction: .incoming),
    ]
    let export = try LSRulesWriter.export(originals, name: "Shared", description: "From Rift", path: paths)
    #expect(export.exported == 4)
    #expect(export.skipped == 0)
    #expect(export.summary == "Exported 4 rules.")

    let file = try LSRulesFile.decode(export.data)
    #expect(file.name == "Shared")
    #expect(file.description == "From Rift")
    let conversion = LSRulesConverter.convert(
        file, fileName: "Fallback", lineageID: UUID(), resolve: resolver,
        suffixes: PublicSuffixList("example\ncom\n"), now: Date()
    )
    #expect(conversion.unsupported == 0)
    #expect(conversion.missingApps == 0)
    let imported = conversion.payload.rules
    #expect(imported.count == originals.count)
    for (original, copy) in zip(originals, imported) {
        #expect(copy.action == original.action)
        #expect(copy.process == original.process)
        #expect(copy.destination == original.destination)
        #expect(copy.transportProtocol == original.transportProtocol)
        #expect(copy.port == original.port)
        #expect(copy.direction == original.direction)
        #expect(copy.isEnabled == original.isEnabled)
        #expect(copy.notes == original.notes)
    }
}

@Test func rulesTheFormatCantExpressAreSkippedAndCounted() throws {
    let unsigned = ProcessIdentity.adHoc(cdHash: try CodeDigest(hex: String(repeating: "ab", count: 20), expectedByteCount: 20))
    let skipped = [
        try rule(expiresAt: Date(timeIntervalSince1970: 10)),
        try rule(profileID: UUID()),
        try rule(process: .exact(unsigned)),
        try rule(process: .exact(.applePlatform(try SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.curl")))),
        try rule(process: .appViaHelper(app: notes, helper: safari)),
        try rule(destination: .normalizedExactHostnameSet([DomainName("a.example")]), direction: .incoming),
    ]
    let kept = try rule(direction: .bidirectional)
    let export = try LSRulesWriter.export(skipped + [kept], name: "Rules", path: paths)
    #expect(export.exported == 1)
    #expect(export.skipped == skipped.count)
    #expect(export.summary.hasPrefix("Exported 1 rule. 6 rules were skipped"))
    // Both directions become one rule each.
    #expect(try LSRulesFile.decode(export.data).rules.map(\.direction) == ["outgoing", "incoming"])
    #expect(throws: LSRulesWriter.ExportError.nothingToExport) {
        try LSRulesWriter.export(skipped, name: "Rules", path: paths)
    }
}

@Test func aTeamsAppIsNamedByItsCodeID() throws {
    #expect(LSRulesWriter.name(notes, path: paths) == "identifier.TEAM123456/com.example.notes")
    #expect(LSRulesWriter.name(safari, path: paths) == safariPath)
    #expect(LSRulesWriter.name(safari, path: { _ in "relative/path" }) == nil)
}
