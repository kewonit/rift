import Foundation
import RiftControl
import RiftCore
import RiftIPC
import Testing

private func prompt(
    app: ProcessIdentity?,
    helper: ProcessIdentity? = nil,
    host: String? = "example.test"
) throws -> PromptRequest {
    PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 1, flowID: UUID(),
        observedAt: Date(timeIntervalSince1970: 0), owner: .user(uid: 501),
        appIdentity: app, processIdentity: helper ?? app, direction: .outgoing,
        transportProtocol: .tcp,
        endpoint: Endpoint(
            address: try IPAddress("203.0.113.10"), port: 443,
            hostname: try host.map(DomainName.init), hostnameCoverage: host == nil ? .absent : .observed,
            classes: [], interfaceSnapshotGeneration: 0
        ),
        winningRuleID: nil, affectingRuleIDs: []
    )
}

private let signed = ProcessIdentity.developerID(
    try! SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "com.example.app")
)
private let hash32 = try! CodeDigest(hex: String(repeating: "ab", count: 32), expectedByteCount: 32)
private let hash20 = try! CodeDigest(hex: String(repeating: "cd", count: 20), expectedByteCount: 20)

@Test func signedAppsRaiseNoWarning() throws {
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: signed)).isEmpty)
}

@Test func codeWithoutATrustedSignerIsFlagged() throws {
    let unsigned = ProcessIdentity.unsigned(normalizedPath: "/usr/local/bin/tool", fileHash: hash32)
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: unsigned)) == [.unsigned(helper: false)])
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: .adHoc(cdHash: hash20)))
        == [.selfSigned(helper: false)])
    let other = ProcessIdentity.otherSigner(publicKeyHash: hash32, signingIdentifier: "tool")
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: other))
        == [.unrecognizedCertificate(helper: false)])
}

@Test func anUnsignedHelperOfASignedAppIsNamedAsTheHelper() throws {
    let helper = ProcessIdentity.adHoc(cdHash: hash20)
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: signed, helper: helper))
        == [.selfSigned(helper: true)])
}

@Test func translocatedAppsAreFlagged() throws {
    let path = "/private/var/folders/xy/abc/T/AppTranslocation/1234/d/Tool.app/Contents/MacOS/Tool"
    let app = ProcessIdentity.unsigned(normalizedPath: path, fileHash: hash32)
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: app)).contains(.translocated))
}

@Test func internationalNamesAreFlagged() throws {
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: signed, host: "xn--pple-43d.com"))
        == [.internationalName])
    #expect(ConnectionAlertWarnings.warnings(for: try prompt(app: signed, host: nil)).isEmpty)
}

@Test func anyWarningMakesAllowDeliberate() throws {
    #expect(!ConnectionAlertWarnings.requiresDeliberateAllow(for: try prompt(app: signed)))
    let unsigned = ProcessIdentity.unsigned(normalizedPath: "/usr/local/bin/tool", fileHash: hash32)
    #expect(ConnectionAlertWarnings.requiresDeliberateAllow(for: try prompt(app: unsigned)))
    #expect(ConnectionAlertWarnings.requiresDeliberateAllow(for: try prompt(app: .adHoc(cdHash: hash20))))
    #expect(ConnectionAlertWarnings.requiresDeliberateAllow(for: try prompt(app: signed, host: "xn--pple-43d.com")))
}
