import AbyssCore
import Foundation
import Security

struct ExtensionIdentity: Sendable, Equatable {
    let bundleIdentifier: String
    let shortVersion: String
    let buildVersion: String
}

struct InstalledExtensionObservation: Sendable {
    let identity: ExtensionIdentity
    let enabled: Bool
    let awaitingApproval: Bool
    let uninstalling: Bool
}

enum LifecycleHealthFailure: Error, Sendable {
    case activationPreflight(SystemExtensionActivationPreflightFailure)
    case invalidEmbeddedExtension
    case ambiguousInstalledExtension
    case installedExtensionMismatch
    case providerConfigurationMismatch
    case socketFilteringDisabled
    case packetFilteringClaimed

    var message: String {
        switch self {
        case .activationPreflight(let failure):
            failure.message
        case .invalidEmbeddedExtension:
            "This copy of Abyss does not contain the expected matching network filter. Replace it with a complete Abyss release."
        case .ambiguousInstalledExtension:
            "macOS reported more than one matching Abyss network filter. Resolve the duplicate installation before filtering."
        case .installedExtensionMismatch:
            "The installed network filter does not match this copy of Abyss. Update or reinstall it before filtering."
        case .providerConfigurationMismatch:
            "The saved macOS filter configuration does not target the exact Abyss filter. Remove and reinstall the filter configuration before filtering."
        case .socketFilteringDisabled:
            "The saved macOS filter configuration does not enable socket filtering. Remove and reinstall the filter configuration before filtering."
        case .packetFilteringClaimed:
            "The saved macOS filter configuration claims unsupported packet filtering. Remove and reinstall the filter configuration before filtering."
        }
    }
}

private extension SystemExtensionActivationPreflightFailure {
    var message: String {
        switch self {
        case .invalidHostBundle, .invalidEmbeddedBundle, .versionMismatch:
            "This copy of Abyss does not contain the expected matching network filter. Replace it with a complete Abyss release, then retry."
        case .invalidHostSignature, .invalidEmbeddedSignature, .invalidNestedCode,
                .signingTeamMismatch, .designatedIdentityMismatch:
            "Abyss could not verify the embedded network filter as part of this signed release. Replace this copy of Abyss, then retry."
        case .hostEntitlementsMismatch, .extensionEntitlementsMismatch:
            "This copy of Abyss is missing required network-filter authorization. Replace it with a correctly signed release, then retry."
        case .machServiceMismatch:
            "The app and embedded network filter have mismatched service configuration. Replace this copy of Abyss, then retry."
        }
    }
}

enum FilterActivationPreflight {
    static let hostIdentifier = "io.abyss.firewall"
    static let extensionIdentifier = "io.abyss.firewall.filter"
    static let appGroup = "group.io.abyss.firewall"
    static let filterDataProviderClass = "AbyssFilter.FilterDataProvider"
    static let embeddedExtensionPath =
        "Contents/Library/SystemExtensions/AbyssFilter.systemextension"

    static func validate() throws -> ExtensionIdentity {
        let app = Bundle.main
        let filter = try embeddedBundle(in: app)
        let facts = SystemExtensionActivationFacts(
            host: try componentFacts(
                bundle: app,
                url: app.bundleURL,
                expectedIdentifier: hostIdentifier,
                validateNestedCode: true
            ),
            embeddedExtension: try componentFacts(
                bundle: filter,
                url: filter.bundleURL,
                expectedIdentifier: extensionIdentifier,
                validateNestedCode: false
            )
        )
        do {
            try SystemExtensionActivationPreflight.validate(
                facts,
                expected: SystemExtensionActivationExpectations(
                    hostBundleIdentifier: hostIdentifier,
                    extensionBundleIdentifier: extensionIdentifier,
                    appGroup: appGroup,
                    filterDataProviderClass: filterDataProviderClass
                )
            )
        } catch let failure as SystemExtensionActivationPreflightFailure {
            throw LifecycleHealthFailure.activationPreflight(failure)
        }
        return try identity(of: filter)
    }

    static func embeddedIdentity() throws -> ExtensionIdentity {
        let app = Bundle.main
        let identity = try identity(of: embeddedBundle(in: app))
        guard let appShortVersion = app.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              let appBuildVersion = app.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              !appShortVersion.isEmpty,
              !appBuildVersion.isEmpty,
              identity.shortVersion == appShortVersion,
              identity.buildVersion == appBuildVersion else {
            throw LifecycleHealthFailure.invalidEmbeddedExtension
        }
        return identity
    }

    private static func embeddedBundle(in app: Bundle) throws -> Bundle {
        let url = app.bundleURL.appendingPathComponent(
            embeddedExtensionPath, isDirectory: true
        )
        guard let bundle = Bundle(url: url) else {
            throw LifecycleHealthFailure.invalidEmbeddedExtension
        }
        return bundle
    }

    private static func identity(of bundle: Bundle) throws -> ExtensionIdentity {
        guard let identifier = bundle.bundleIdentifier,
              let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              !shortVersion.isEmpty,
              let buildVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              !buildVersion.isEmpty,
              identifier == extensionIdentifier else {
            throw LifecycleHealthFailure.invalidEmbeddedExtension
        }
        return ExtensionIdentity(
            bundleIdentifier: identifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    private static func componentFacts(
        bundle: Bundle,
        url: URL,
        expectedIdentifier: String,
        validateNestedCode: Bool
    ) throws -> SystemExtensionComponentFacts {
        guard let identifier = bundle.bundleIdentifier,
              let shortVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let buildVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let packageType = bundle.object(
                forInfoDictionaryKey: "CFBundlePackageType"
              ) as? String else {
            throw LifecycleHealthFailure.invalidEmbeddedExtension
        }
        let signing = signingFacts(
            at: url,
            expectedIdentifier: expectedIdentifier,
            validateNestedCode: validateNestedCode
        )
        let entitlements = signing.entitlements
        let network = bundle.object(forInfoDictionaryKey: "NetworkExtension")
            as? [String: Any]
        let providerClasses = network?["NEProviderClasses"] as? [String: Any]
        return SystemExtensionComponentFacts(
            bundleIdentifier: identifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            packageType: packageType,
            signingIdentifier: signing.identifier,
            teamIdentifier: signing.teamIdentifier,
            signatureIsValid: signing.signatureIsValid,
            designatedIdentityIsValid: signing.designatedIdentityIsValid,
            nestedCodeIsValid: signing.nestedCodeIsValid,
            appSandboxEnabled: entitlements["com.apple.security.app-sandbox"] as? Bool == true,
            systemExtensionInstallEnabled:
                entitlements["com.apple.developer.system-extension.install"] as? Bool == true,
            networkExtensionCapabilities: stringSet(
                entitlements["com.apple.developer.networking.networkextension"]
            ),
            appGroups: stringSet(entitlements["com.apple.security.application-groups"]),
            configuredAppGroup: bundle.object(
                forInfoDictionaryKey: "AbyssAppGroupIdentifier"
            ) as? String,
            teamIdentifierPrefix: bundle.object(
                forInfoDictionaryKey: "AbyssTeamIdentifierPrefix"
            ) as? String,
            machServiceName: bundle.object(
                forInfoDictionaryKey: "AbyssMachServiceName"
            ) as? String ?? network?["NEMachServiceName"] as? String,
            filterDataProviderClass: providerClasses?[
                "com.apple.networkextension.filter-data"
            ] as? String
        )
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        Set(value as? [String] ?? [])
    }

    private struct SigningFacts {
        let identifier: String?
        let teamIdentifier: String?
        let signatureIsValid: Bool
        let designatedIdentityIsValid: Bool
        let nestedCodeIsValid: Bool
        let entitlements: [String: Any]

        static var invalid: SigningFacts {
            SigningFacts(
                identifier: nil,
                teamIdentifier: nil,
                signatureIsValid: false,
                designatedIdentityIsValid: false,
                nestedCodeIsValid: false,
                entitlements: [:]
            )
        }
    }

    private static func signingFacts(
        at url: URL,
        expectedIdentifier: String,
        validateNestedCode: Bool
    ) -> SigningFacts {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        ) == errSecSuccess, let code else { return .invalid }
        let baseFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
        )
        let signatureIsValid = SecStaticCodeCheckValidity(code, baseFlags, nil)
            == errSecSuccess
        guard signatureIsValid else { return .invalid }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [String: Any] else { return .invalid }
        let identifier = values[kSecCodeInfoIdentifier as String] as? String
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = values[kSecCodeInfoEntitlementsDict as String]
            as? [String: Any] ?? [:]
        let nestedFlags = SecCSFlags(
            rawValue: baseFlags.rawValue | kSecCSCheckNestedCode
        )
        return SigningFacts(
            identifier: identifier,
            teamIdentifier: team,
            signatureIsValid: true,
            designatedIdentityIsValid: team.map {
                designatedIdentityIsValid(
                    code,
                    identifier: expectedIdentifier,
                    teamIdentifier: $0,
                    flags: baseFlags
                )
            } ?? false,
            nestedCodeIsValid: !validateNestedCode ||
                SecStaticCodeCheckValidity(code, nestedFlags, nil) == errSecSuccess,
            entitlements: entitlements
        )
    }

    private static func designatedIdentityIsValid(
        _ code: SecStaticCode,
        identifier: String,
        teamIdentifier: String,
        flags: SecCSFlags
    ) -> Bool {
        let safe = CharacterSet.alphanumerics
        guard !teamIdentifier.isEmpty,
              teamIdentifier.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return false
        }
        let source = "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

func permitsReplacement(
    existing: ExtensionIdentity,
    incoming: ExtensionIdentity
) -> Bool {
    guard existing.bundleIdentifier == incoming.bundleIdentifier else { return false }
    let versionOrder = incoming.shortVersion.compare(
        existing.shortVersion,
        options: [.numeric, .caseInsensitive]
    )
    if versionOrder == .orderedAscending { return false }
    if versionOrder == .orderedDescending { return true }
    return incoming.buildVersion.compare(
        existing.buildVersion,
        options: [.numeric, .caseInsensitive]
    ) != .orderedAscending
}
