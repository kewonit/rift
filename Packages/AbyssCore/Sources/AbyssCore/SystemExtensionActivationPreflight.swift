import Foundation

public struct SystemExtensionComponentFacts: Sendable, Equatable {
    public let bundleIdentifier: String
    public let shortVersion: String
    public let buildVersion: String
    public let packageType: String
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let signatureIsValid: Bool
    public let designatedIdentityIsValid: Bool
    public let nestedCodeIsValid: Bool
    public let appSandboxEnabled: Bool
    public let systemExtensionInstallEnabled: Bool
    public let networkExtensionCapabilities: Set<String>
    public let appGroups: Set<String>
    public let configuredAppGroup: String?
    public let teamIdentifierPrefix: String?
    public let machServiceName: String?
    public let filterDataProviderClass: String?

    public init(
        bundleIdentifier: String,
        shortVersion: String,
        buildVersion: String,
        packageType: String,
        signingIdentifier: String?,
        teamIdentifier: String?,
        signatureIsValid: Bool,
        designatedIdentityIsValid: Bool,
        nestedCodeIsValid: Bool,
        appSandboxEnabled: Bool,
        systemExtensionInstallEnabled: Bool,
        networkExtensionCapabilities: Set<String>,
        appGroups: Set<String>,
        configuredAppGroup: String?,
        teamIdentifierPrefix: String?,
        machServiceName: String?,
        filterDataProviderClass: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.packageType = packageType
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.signatureIsValid = signatureIsValid
        self.designatedIdentityIsValid = designatedIdentityIsValid
        self.nestedCodeIsValid = nestedCodeIsValid
        self.appSandboxEnabled = appSandboxEnabled
        self.systemExtensionInstallEnabled = systemExtensionInstallEnabled
        self.networkExtensionCapabilities = networkExtensionCapabilities
        self.appGroups = appGroups
        self.configuredAppGroup = configuredAppGroup
        self.teamIdentifierPrefix = teamIdentifierPrefix
        self.machServiceName = machServiceName
        self.filterDataProviderClass = filterDataProviderClass
    }
}

public struct SystemExtensionActivationFacts: Sendable, Equatable {
    public let host: SystemExtensionComponentFacts
    public let embeddedExtension: SystemExtensionComponentFacts

    public init(
        host: SystemExtensionComponentFacts,
        embeddedExtension: SystemExtensionComponentFacts
    ) {
        self.host = host
        self.embeddedExtension = embeddedExtension
    }
}

public struct SystemExtensionActivationExpectations: Sendable, Equatable {
    public let hostBundleIdentifier: String
    public let extensionBundleIdentifier: String
    public let appGroup: String
    public let filterDataProviderClass: String

    public init(
        hostBundleIdentifier: String,
        extensionBundleIdentifier: String,
        appGroup: String,
        filterDataProviderClass: String
    ) {
        self.hostBundleIdentifier = hostBundleIdentifier
        self.extensionBundleIdentifier = extensionBundleIdentifier
        self.appGroup = appGroup
        self.filterDataProviderClass = filterDataProviderClass
    }
}

public enum SystemExtensionActivationPreflightFailure: String, Error, Sendable, Equatable {
    case invalidHostBundle
    case invalidEmbeddedBundle
    case versionMismatch
    case invalidHostSignature
    case invalidEmbeddedSignature
    case invalidNestedCode
    case signingTeamMismatch
    case designatedIdentityMismatch
    case hostEntitlementsMismatch
    case extensionEntitlementsMismatch
    case machServiceMismatch
}

public enum SystemExtensionActivationPreflight {
    private static let supportedCapabilities: Set<String> = [
        "content-filter-provider",
        "content-filter-provider-systemextension",
    ]

    public static func validate(
        _ facts: SystemExtensionActivationFacts,
        expected: SystemExtensionActivationExpectations
    ) throws {
        let host = facts.host
        let filter = facts.embeddedExtension
        guard host.bundleIdentifier == expected.hostBundleIdentifier,
              host.packageType == "APPL" else {
            throw SystemExtensionActivationPreflightFailure.invalidHostBundle
        }
        guard filter.bundleIdentifier == expected.extensionBundleIdentifier,
              filter.packageType == "SYSX",
              filter.filterDataProviderClass == expected.filterDataProviderClass else {
            throw SystemExtensionActivationPreflightFailure.invalidEmbeddedBundle
        }
        guard !host.shortVersion.isEmpty, !host.buildVersion.isEmpty,
              host.shortVersion == filter.shortVersion,
              host.buildVersion == filter.buildVersion else {
            throw SystemExtensionActivationPreflightFailure.versionMismatch
        }
        guard host.signatureIsValid else {
            throw SystemExtensionActivationPreflightFailure.invalidHostSignature
        }
        guard filter.signatureIsValid else {
            throw SystemExtensionActivationPreflightFailure.invalidEmbeddedSignature
        }
        guard host.nestedCodeIsValid else {
            throw SystemExtensionActivationPreflightFailure.invalidNestedCode
        }
        guard let team = host.teamIdentifier,
              teamIdentifierIsSafe(team),
              filter.teamIdentifier == team else {
            throw SystemExtensionActivationPreflightFailure.signingTeamMismatch
        }
        guard host.signingIdentifier == expected.hostBundleIdentifier,
              filter.signingIdentifier == expected.extensionBundleIdentifier,
              host.designatedIdentityIsValid,
              filter.designatedIdentityIsValid else {
            throw SystemExtensionActivationPreflightFailure.designatedIdentityMismatch
        }
        guard validNetworkEntitlements(host, expectedAppGroup: expected.appGroup),
              host.systemExtensionInstallEnabled else {
            throw SystemExtensionActivationPreflightFailure.hostEntitlementsMismatch
        }
        guard validNetworkEntitlements(filter, expectedAppGroup: expected.appGroup),
              !filter.systemExtensionInstallEnabled,
              filter.networkExtensionCapabilities == host.networkExtensionCapabilities else {
            throw SystemExtensionActivationPreflightFailure.extensionEntitlementsMismatch
        }
        let prefix = team + "."
        let service = prefix + expected.appGroup + ".control"
        guard host.configuredAppGroup == expected.appGroup,
              filter.configuredAppGroup == expected.appGroup,
              host.teamIdentifierPrefix == prefix,
              filter.teamIdentifierPrefix == prefix,
              host.machServiceName == service,
              filter.machServiceName == service else {
            throw SystemExtensionActivationPreflightFailure.machServiceMismatch
        }
    }

    private static func validNetworkEntitlements(
        _ facts: SystemExtensionComponentFacts,
        expectedAppGroup: String
    ) -> Bool {
        facts.appSandboxEnabled &&
            facts.networkExtensionCapabilities.count == 1 &&
            facts.networkExtensionCapabilities.isSubset(of: supportedCapabilities) &&
            facts.appGroups == [expectedAppGroup]
    }

    private static func teamIdentifierIsSafe(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}
