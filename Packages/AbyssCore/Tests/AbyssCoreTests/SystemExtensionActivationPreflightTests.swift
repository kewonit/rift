import Foundation
import Testing
@testable import AbyssCore

@Test func validSystemExtensionActivationFactsPass() throws {
    try SystemExtensionActivationPreflight.validate(
        activationFacts(), expected: activationExpectations
    )
}

@Test func activationPreflightRejectsIdentityAndVersionMismatches() {
    expectFailure(.invalidEmbeddedBundle, facts: activationFacts(
        filter: component(role: .filter, bundleIdentifier: "io.example.wrong")
    ))
    expectFailure(.versionMismatch, facts: activationFacts(
        filter: component(role: .filter, buildVersion: "2")
    ))
    expectFailure(.designatedIdentityMismatch, facts: activationFacts(
        filter: component(role: .filter, designatedIdentityIsValid: false)
    ))
}

@Test func activationPreflightRejectsInvalidOrForeignSignatures() {
    expectFailure(.invalidHostSignature, facts: activationFacts(
        host: component(role: .host, signatureIsValid: false)
    ))
    expectFailure(.invalidEmbeddedSignature, facts: activationFacts(
        filter: component(role: .filter, signatureIsValid: false)
    ))
    expectFailure(.invalidNestedCode, facts: activationFacts(
        host: component(role: .host, nestedCodeIsValid: false)
    ))
    expectFailure(.signingTeamMismatch, facts: activationFacts(
        filter: component(role: .filter, teamIdentifier: "OTHERTEAM1")
    ))
}

@Test func activationPreflightRejectsMissingRequiredEntitlements() {
    expectFailure(.hostEntitlementsMismatch, facts: activationFacts(
        host: component(role: .host, systemExtensionInstallEnabled: false)
    ))
    expectFailure(.extensionEntitlementsMismatch, facts: activationFacts(
        filter: component(role: .filter, networkExtensionCapabilities: [])
    ))
    expectFailure(.extensionEntitlementsMismatch, facts: activationFacts(
        filter: component(role: .filter, systemExtensionInstallEnabled: true)
    ))
}

@Test func activationPreflightRejectsAppGroupAndMachServiceMismatches() {
    expectFailure(.hostEntitlementsMismatch, facts: activationFacts(
        host: component(role: .host, appGroups: ["group.io.example.wrong"])
    ))
    expectFailure(.machServiceMismatch, facts: activationFacts(
        filter: component(role: .filter, machServiceName: "WRONG.service")
    ))
    expectFailure(.machServiceMismatch, facts: activationFacts(
        host: component(role: .host, teamIdentifierPrefix: "WRONG.")
    ))
}

private enum ComponentRole { case host, filter }

private let activationExpectations = SystemExtensionActivationExpectations(
    hostBundleIdentifier: "io.abyss.firewall",
    extensionBundleIdentifier: "io.abyss.firewall.filter",
    appGroup: "group.io.abyss.firewall",
    filterDataProviderClass: "AbyssFilter.FilterDataProvider"
)

private func activationFacts(
    host: SystemExtensionComponentFacts = component(role: .host),
    filter: SystemExtensionComponentFacts = component(role: .filter)
) -> SystemExtensionActivationFacts {
    SystemExtensionActivationFacts(host: host, embeddedExtension: filter)
}

private func component(
    role: ComponentRole,
    bundleIdentifier: String? = nil,
    buildVersion: String = "1",
    teamIdentifier: String? = "ABYSS12345",
    signatureIsValid: Bool = true,
    designatedIdentityIsValid: Bool = true,
    nestedCodeIsValid: Bool = true,
    systemExtensionInstallEnabled: Bool? = nil,
    networkExtensionCapabilities: Set<String> = ["content-filter-provider-systemextension"],
    appGroups: Set<String> = ["group.io.abyss.firewall"],
    teamIdentifierPrefix: String? = "ABYSS12345.",
    machServiceName: String? = "ABYSS12345.group.io.abyss.firewall.control"
) -> SystemExtensionComponentFacts {
    let isHost = role == .host
    let identifier = bundleIdentifier ?? (isHost ? "io.abyss.firewall" : "io.abyss.firewall.filter")
    return SystemExtensionComponentFacts(
        bundleIdentifier: identifier,
        shortVersion: "1.0",
        buildVersion: buildVersion,
        packageType: isHost ? "APPL" : "SYSX",
        signingIdentifier: identifier,
        teamIdentifier: teamIdentifier,
        signatureIsValid: signatureIsValid,
        designatedIdentityIsValid: designatedIdentityIsValid,
        nestedCodeIsValid: nestedCodeIsValid,
        appSandboxEnabled: true,
        systemExtensionInstallEnabled: systemExtensionInstallEnabled ?? isHost,
        networkExtensionCapabilities: networkExtensionCapabilities,
        appGroups: appGroups,
        configuredAppGroup: "group.io.abyss.firewall",
        teamIdentifierPrefix: teamIdentifierPrefix,
        machServiceName: machServiceName,
        filterDataProviderClass: isHost ? nil : "AbyssFilter.FilterDataProvider"
    )
}

private func expectFailure(
    _ expected: SystemExtensionActivationPreflightFailure,
    facts: SystemExtensionActivationFacts
) {
    do {
        try SystemExtensionActivationPreflight.validate(facts, expected: activationExpectations)
        Issue.record("Expected \(expected.rawValue)")
    } catch let failure as SystemExtensionActivationPreflightFailure {
        #expect(failure == expected)
    } catch {
        Issue.record("Unexpected error type")
    }
}
