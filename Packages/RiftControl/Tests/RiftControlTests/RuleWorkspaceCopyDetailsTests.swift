import RiftControl
import RiftCore
import Foundation
import Testing

@Test func copiedRuleDetailsExposeExactIdentityAndSanitizeText() throws {
    let app = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAM000001",
        signingIdentifier: "com.example.browser"
    ))
    let helper = ProcessIdentity.otherSigner(
        publicKeyHash: try CodeDigest(hex: String(repeating: "11", count: 32), expectedByteCount: 32),
        signingIdentifier: "com.example.helper"
    )
    let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
    let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
    let rule = try Rule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000803")!,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000800")!,
        revision: 7,
        action: .filter(.deny),
        priority: .normal,
        process: .appViaHelper(app: app, helper: helper),
        destination: try .normalizedExactHostnameSet([DomainName("example.com")]),
        transportProtocol: .tcp,
        port: try PortRange(443, 443),
        direction: .outgoing,
        owner: .authorizedUser,
        profileID: profileID,
        localGroupID: groupID,
        isEnabled: true,
        reviewState: .unreviewed,
        notes: "first\nsecond\u{202E}",
        createdAt: Date(timeIntervalSince1970: 1_000),
        modifiedAt: Date(timeIntervalSince1970: 2_000)
    )
    let context = RuleWorkspaceQueryContext(
        activeProfileID: profileID,
        enabledLocalGroupIDs: [groupID],
        localGroupNames: [groupID: "Work\nGroup"],
        profileNames: [profileID: "Focused"],
        now: Date(timeIntervalSince1970: 3_000)
    )

    let text = RuleWorkspaceCopyDetails.text(for: rule, context: context)

    #expect(text.contains("Application identity: Developer ID"))
    #expect(text.contains("Application team identifier: \(DisplaySanitizer.plainText("TEAM000001"))"))
    #expect(text.contains("Helper public-key SHA-256: \(String(repeating: "11", count: 32))"))
    #expect(text.contains("Destination: example.com"))
    #expect(text.contains("Profile ID: \(profileID.uuidString.lowercased())"))
    #expect(text.contains("Group: \(DisplaySanitizer.plainText("Work\nGroup"))"))
    #expect(text.contains("Note: \(DisplaySanitizer.plainText("first\nsecond\u{202E}", maximumScalars: PolicyLimits.maximumNotesScalars))"))
    #expect(!text.contains("first\nsecond"))
    #expect(text.utf8.count <= RuleWorkspaceCopyDetails.maximumUTF8Bytes)
}

@Test func copiedRuleDetailsRetainCanonicalUnsignedEvidence() throws {
    let hash = try CodeDigest(hex: String(repeating: "ab", count: 32), expectedByteCount: 32)
    let identity = try ProcessIdentity.unsigned(path: "/Applications/Tool", fileHash: hash)
    let rule = try Rule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000811")!,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000810")!,
        revision: 1,
        action: .filter(.allow),
        priority: .normal,
        process: .exact(identity),
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        owner: .system,
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0)
    )

    let text = RuleWorkspaceCopyDetails.text(for: rule)

    #expect(text.contains("Application identity: Unsigned"))
    #expect(text.contains("Application path: \(DisplaySanitizer.plainText("/Applications/Tool"))"))
    #expect(text.contains("Application file SHA-256: \(hash.description)"))
    #expect(text.contains("Owner: System"))
    #expect(text.contains("Profile: All profiles"))
    #expect(text.contains("Group: No group"))
}
