import Foundation
import Testing
@testable import AbyssCore

@Test func referenceAndCompiledMatchersAgreeAcrossGeneratedCases() throws {
    var generator = DeterministicGenerator(seed: 0xC0FFEE)
    let identities = try (0..<12).map { index -> ProcessIdentity in
        .developerID(try SignedCodeIdentity(
            teamIdentifier: "TEAM\(index)",
            signingIdentifier: "io.abyss.generated.\(index)"
        ))
    }
    let domains = try ["example.com", "example.net", "invalid.test"].map(DomainName.init)
    var rules: [Rule] = []
    for index in 0..<240 {
        let process: ProcessCondition
        switch generator.index(upperBound: 3) {
        case 0: process = .anyProcess
        case 1: process = .exact(identities[generator.index(upperBound: identities.count)])
        default:
            process = .appViaHelper(
                app: identities[generator.index(upperBound: identities.count)],
                helper: identities[generator.index(upperBound: identities.count)]
            )
        }
        let destination: DestinationCondition
        switch generator.index(upperBound: 4) {
        case 0: destination = .anyEndpoint
        case 1:
            destination = try .normalizedDomainSet([domains[generator.index(upperBound: domains.count)]])
        case 2:
            destination = try .normalizedExactHostnameSet([
                DomainName("api." + domains[generator.index(upperBound: domains.count)].ascii),
            ])
        default:
            let last = UInt8(1 + generator.index(upperBound: 250))
            destination = try .normalizedIPSet([
                IPInterval(exact: IPAddress(family: .ipv4, bytes: [203, 0, 113, last])),
            ])
        }
        let action: RuleAction
        switch generator.index(upperBound: 5) {
        case 0: action = .notification(.notify)
        case 1: action = .privacy(.hide)
        case 2: action = .filter(.allow)
        case 3: action = .filter(.deny)
        default: action = .filter(.ask)
        }
        rules.append(try RuleTestSupport.rule(
            id: UInt64(index + 1_000),
            action: action,
            process: process,
            destination: destination,
            transport: generator.index(upperBound: 2) == 0 ? .tcp : .anySupportedProtocol,
            port: generator.index(upperBound: 3) == 0 ? PortRange(443, 443) : nil,
            direction: generator.index(upperBound: 2) == 0 ? .outgoing : .bidirectional
        ))
    }

    let reference = ReferenceRuleMatcher(rules: rules)
    let compiled = CompiledRuleMatcher(rules: rules)
    for index in 0..<400 {
        let identity = identities[generator.index(upperBound: identities.count)]
        let hostname = try DomainName("api." + domains[generator.index(upperBound: domains.count)].ascii)
        let endpoint = try RuleTestSupport.endpoint(
            address: "203.0.113.\(1 + generator.index(upperBound: 250))",
            port: generator.index(upperBound: 4) == 0 ? nil : 443,
            hostname: hostname.ascii
        )
        let flow = try RuleTestSupport.flow(
            id: UInt64(index + 2_000),
            app: identity,
            process: identities[generator.index(upperBound: identities.count)],
            owner: generator.index(upperBound: 8) == 0 ? .unknown : .user(uid: 501),
            transport: generator.index(upperBound: 8) == 0 ? .unsupported(number: 1) : .tcp,
            remote: endpoint,
            observedHostname: .some(hostname)
        )
        let context = RuleTestSupport.context()
        #expect(reference.decision(for: flow, context: context, mode: .alert) ==
                compiled.decision(for: flow, context: context, mode: .alert))
    }
}

@Test func snapshotEncodingIsDeterministicAndValidated() throws {
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
    let first = try CanonicalPolicyJSON.encoder().encode(snapshot)
    let second = try CanonicalPolicyJSON.encoder().encode(snapshot)
    let goldenURL = try #require(Bundle.module.url(
        forResource: "policy-snapshot-v1",
        withExtension: "json"
    ))
    let golden = try Data(contentsOf: goldenURL)
    #expect(String(decoding: first, as: UTF8.self) ==
            String(decoding: golden, as: UTF8.self).trimmingCharacters(in: .newlines))
    #expect(first == second)
    #expect(try CanonicalPolicyJSON.decoder().decode(PolicySnapshot.self, from: first) == snapshot)

    let unknownVersion = String(decoding: first, as: UTF8.self)
        .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
    #expect(throws: PolicySnapshotError.self) {
        try CanonicalPolicyJSON.decoder().decode(
            PolicySnapshot.self,
            from: Data(unknownVersion.utf8)
        )
    }
}

@Test func compiledDestinationProtocolAndProfileIndexesPreserveSemantics() throws {
    var rules: [Rule] = []
    for index in 0..<500 {
        rules.append(try RuleTestSupport.rule(
            id: UInt64(5_000 + index),
            action: .filter(.deny),
            destination: .normalizedExactHostnameSet([
                try DomainName("host\(index).invalid.test"),
            ]),
            transport: index.isMultiple(of: 2) ? .udp : .tcp,
            profileID: index.isMultiple(of: 3) ? RuleTestSupport.uuid(77) : nil
        ))
    }
    rules.append(try RuleTestSupport.rule(
        id: 5_999,
        action: .filter(.allow),
        destination: .normalizedDomainSet([try DomainName("example.com")]),
        transport: .tcp
    ))
    let flow = try RuleTestSupport.flow()
    let context = RuleTestSupport.context()
    #expect(ReferenceRuleMatcher(rules: rules).decision(
        for: flow,
        context: context,
        mode: .alert
    ) == CompiledRuleMatcher(rules: rules).decision(
        for: flow,
        context: context,
        mode: .alert
    ))
}
