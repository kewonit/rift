import Darwin
import Foundation
import Security
import Testing
@testable import RiftCore

@Test func identityKindsDoNotCollapseAcrossSignerChangesOrMoves() throws {
    let appleWithoutTeam = ProcessIdentity.applePlatform(
        try SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.fixture")
    )
    _ = try appleWithoutTeam.validated()

    let original = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAMONE", signingIdentifier: "io.rift.app")
    )
    let teamChanged = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAMTWO", signingIdentifier: "io.rift.app")
    )
    #expect(original != teamChanged)

    let fileHash = try CodeDigest(hex: String(repeating: "ab", count: 32), expectedByteCount: 32)
    let firstPath = try ProcessIdentity.unsigned(path: "/opt/tools/client", fileHash: fileHash)
    let movedPath = try ProcessIdentity.unsigned(path: "/usr/local/bin/client", fileHash: fileHash)
    #expect(firstPath != movedPath)

    let oldCDHash = try CodeDigest(hex: String(repeating: "01", count: 20), expectedByteCount: 20)
    let newCDHash = try CodeDigest(hex: String(repeating: "02", count: 20), expectedByteCount: 20)
    #expect(ProcessIdentity.adHoc(cdHash: oldCDHash) != .adHoc(cdHash: newCDHash))
}

@Test func identityValidationRejectsWrongContextualDigestSizes() throws {
    let short = try CodeDigest(hex: "ab", expectedByteCount: 1)
    #expect(throws: CodeIdentityError.self) {
        try ProcessIdentity.adHoc(cdHash: short).validated()
    }
    #expect(throws: CodeIdentityError.self) {
        try ProcessIdentity.unsigned(normalizedPath: "relative", fileHash: short).validated()
    }
}

@Test func staticCodeIdentityResolverValidatesAppleApplication() throws {
    let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    let identity = try StaticCodeIdentityResolver.identity(at: finder)
    guard case .applePlatform(let signed) = identity else {
        Issue.record("Finder did not resolve as Apple platform code")
        return
    }
    #expect(signed.signingIdentifier == "com.apple.finder")
}

@Test func adHocIdentityIsRejectedAfterCodeChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rift-adhoc-identity-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("fixture")
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/usr/bin/true"),
        to: executable
    )
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", "--timestamp=none", executable.path]
    signer.standardOutput = FileHandle.nullDevice
    signer.standardError = FileHandle.nullDevice
    try signer.run()
    signer.waitUntilExit()
    try #require(signer.terminationStatus == 0)

    var staticCode: SecStaticCode?
    try #require(SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess)
    let code = try #require(staticCode)
    var information: CFDictionary?
    try #require(SecCodeCopySigningInformation(
        code,
        SecCSFlags(rawValue: 1 << 1),
        &information
    ) == errSecSuccess)
    let values = try #require(information as? [String: Any])
    guard case .adHoc = try StaticCodeIdentityResolver.identity(
        code: nil,
        staticCode: code,
        information: values
    ) else {
        Issue.record("Ad-hoc fixture did not resolve as ad-hoc code")
        return
    }

    let handle = try FileHandle(forUpdating: executable)
    try handle.seek(toOffset: 4_096)
    let original = try #require(handle.read(upToCount: 1)?.first)
    try handle.seek(toOffset: 4_096)
    try handle.write(contentsOf: Data([original ^ 0xff]))
    try handle.close()
    var tamperedStaticCode: SecStaticCode?
    try #require(SecStaticCodeCreateWithPath(
        executable as CFURL,
        [],
        &tamperedStaticCode
    ) == errSecSuccess)
    let tamperedCode = try #require(tamperedStaticCode)
    #expect(throws: StaticCodeIdentityResolverError.self) {
        try StaticCodeIdentityResolver.identity(
            code: nil,
            staticCode: tamperedCode,
            information: values
        )
    }
}

@Test func signedCodeKindRequiresAnExclusiveDistributionCertificateClass() {
    #expect(StaticCodeIdentityResolver.signedCodeKind(
        hasTeamIdentifier: true,
        satisfiesDeveloperID: true,
        satisfiesAppStore: false
    ) == .developerID)
    #expect(StaticCodeIdentityResolver.signedCodeKind(
        hasTeamIdentifier: true,
        satisfiesDeveloperID: false,
        satisfiesAppStore: true
    ) == .appStore)
    #expect(StaticCodeIdentityResolver.signedCodeKind(
        hasTeamIdentifier: true,
        satisfiesDeveloperID: false,
        satisfiesAppStore: false
    ) == .other)
    #expect(StaticCodeIdentityResolver.signedCodeKind(
        hasTeamIdentifier: true,
        satisfiesDeveloperID: true,
        satisfiesAppStore: true
    ) == .other)
    #expect(StaticCodeIdentityResolver.signedCodeKind(
        hasTeamIdentifier: false,
        satisfiesDeveloperID: true,
        satisfiesAppStore: false
    ) == .other)
}

@Test func staticCodeIdentityResolverKeepsUnsignedExecutablesDistinct() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rift-unsigned-identity-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("fixture")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    let remover = Process()
    remover.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    remover.arguments = ["--remove-signature", executable.path]
    remover.standardOutput = FileHandle.nullDevice
    remover.standardError = FileHandle.nullDevice
    try remover.run()
    remover.waitUntilExit()
    try #require(remover.terminationStatus == 0)

    guard case .unsigned(let path, _) = try StaticCodeIdentityResolver.identity(at: executable) else {
        Issue.record("Unsigned fixture did not resolve as an unsigned identity")
        return
    }
    #expect(path == executable.standardizedFileURL.path)
}

@Test func blocklistRulesAreDenyOnlyAndSourceManaged() throws {
    let sourceID = RuleTestSupport.uuid(4_000)
    #expect(throws: RuleValidationError.self) {
        try RuleTestSupport.rule(
            id: 4_001,
            action: .filter(.allow),
            priority: .blocklistDeny,
            flags: [.sourceManaged],
            source: .blocklist(sourceID: sourceID)
        )
    }
    #expect(throws: RuleValidationError.self) {
        try RuleTestSupport.rule(
            id: 4_002,
            action: .filter(.deny),
            priority: .blocklistDeny,
            source: .manual
        )
    }
    #expect(throws: RuleValidationError.blocklistRequiresManagedFlag) {
        try RuleTestSupport.rule(
            id: 4_003,
            action: .filter(.deny),
            priority: .blocklistDeny,
            source: .blocklist(sourceID: sourceID)
        )
    }
}

@Test func elevatedPriorityIsReservedForExplicitAllowExceptions() throws {
    #expect(throws: RuleValidationError.elevatedPriorityRequiresAllow) {
        try RuleTestSupport.rule(
            id: 4_010,
            action: .filter(.deny),
            priority: .elevatedUser
        )
    }
}

@Test func policySnapshotsRejectDuplicateRuleIdentifiers() throws {
    let rule = try RuleTestSupport.rule(id: 4_100, action: .filter(.deny))
    #expect(throws: PolicySnapshotError.duplicateRuleID(rule.id)) {
        try PolicySnapshot(
            lineageID: rule.lineageID,
            generation: 1,
            rules: [rule, rule]
        )
    }
}

@Test func policySnapshotsRejectRulesFromAnotherLineage() throws {
    let expected = RuleTestSupport.uuid(4_110)
    let actual = RuleTestSupport.uuid(4_111)
    let rule = try RuleTestSupport.rule(
        id: 4_112,
        action: .filter(.deny),
        lineageID: actual
    )
    #expect(throws: PolicySnapshotError.mismatchedRuleLineage(
        ruleID: rule.id,
        expected: expected,
        actual: actual
    )) {
        try PolicySnapshot(lineageID: expected, generation: 1, rules: [rule])
    }
}

@Test func policySnapshotDecodingRejectsMaliciousNestedRangesAndLineage() throws {
    let lineage = RuleTestSupport.uuid(99)
    let portRule = try RuleTestSupport.rule(
        id: 4_120,
        action: .filter(.deny),
        port: PortRange(80, 443)
    )
    let portSnapshot = try PolicySnapshot(lineageID: lineage, generation: 1, rules: [portRule])
    let encodedPortSnapshot = try CanonicalPolicyJSON.encoder().encode(portSnapshot)
    let reversedPort = String(decoding: encodedPortSnapshot, as: UTF8.self).replacingOccurrences(
        of: #""lowerBound":80,"upperBound":443"#,
        with: #""lowerBound":444,"upperBound":443"#
    )
    #expect(Data(reversedPort.utf8) != encodedPortSnapshot)
    #expect(throws: DecodingError.self) {
        try CanonicalPolicyJSON.decoder().decode(
            PolicySnapshot.self,
            from: Data(reversedPort.utf8)
        )
    }

    let interval = try IPInterval(
        range: IPAddress("192.0.2.1"),
        IPAddress("192.0.2.9")
    )
    let intervalRule = try RuleTestSupport.rule(
        id: 4_121,
        action: .filter(.deny),
        destination: .normalizedIPSet([interval])
    )
    let intervalSnapshot = try PolicySnapshot(
        lineageID: lineage,
        generation: 1,
        rules: [intervalRule]
    )
    let encodedIntervalSnapshot = try CanonicalPolicyJSON.encoder().encode(intervalSnapshot)
    let reversedInterval = String(
        decoding: encodedIntervalSnapshot,
        as: UTF8.self
    ).replacingOccurrences(
        of: #""lowerBound":"192.0.2.1","upperBound":"192.0.2.9""#,
        with: #""lowerBound":"192.0.2.1","upperBound":"192.0.2.0""#
    )
    #expect(Data(reversedInterval.utf8) != encodedIntervalSnapshot)
    #expect(throws: DecodingError.self) {
        try CanonicalPolicyJSON.decoder().decode(
            PolicySnapshot.self,
            from: Data(reversedInterval.utf8)
        )
    }

    let expectedFragment = #""lineageID":"00000000-0000-0000-0000-000000000063","modifiedAt"#
    let mismatchedFragment = #""lineageID":"00000000-0000-0000-0000-000000000064","modifiedAt"#
    let mismatchedLineage = String(
        decoding: encodedPortSnapshot,
        as: UTF8.self
    ).replacingOccurrences(of: expectedFragment, with: mismatchedFragment)
    #expect(Data(mismatchedLineage.utf8) != encodedPortSnapshot)
    #expect(throws: PolicySnapshotError.mismatchedRuleLineage(
        ruleID: portRule.id,
        expected: lineage,
        actual: RuleTestSupport.uuid(100)
    )) {
        try CanonicalPolicyJSON.decoder().decode(
            PolicySnapshot.self,
            from: Data(mismatchedLineage.utf8)
        )
    }
}
