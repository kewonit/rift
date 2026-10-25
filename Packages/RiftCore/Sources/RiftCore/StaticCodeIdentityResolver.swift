import CryptoKit
import Foundation
import Security

public enum StaticCodeIdentityResolverError: Error, Sendable {
    case codeLookupFailed(OSStatus)
    case invalidSigningInformation
    case fileTooLarge
    case unsafeExecutable
    case executableChanged
    case cancelled
    case executableReadFailed(Int32)
}

public enum StaticCodeIdentityResolver {
    public static let maximumUnsignedExecutableBytes = SecureExecutableHasher.maximumBytes

    private static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    private static let appStoreRequirement =
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"

    public static func identity(
        at url: URL,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> ProcessIdentity {
        guard !shouldCancel() else { throw StaticCodeIdentityResolverError.cancelled }
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw StaticCodeIdentityResolverError.codeLookupFailed(createStatus)
        }
        let strictNoNetwork = SecCSFlags(rawValue: (1 << 4) | (1 << 9) | (1 << 29))
        let validity = SecStaticCodeCheckValidity(staticCode, strictNoNetwork, nil)
        guard validity == errSecSuccess || validity == errSecCSUnsigned else {
            throw StaticCodeIdentityResolverError.codeLookupFailed(validity)
        }
        guard !shouldCancel() else { throw StaticCodeIdentityResolverError.cancelled }
        let information = try signingInformation(for: staticCode)
        return try identity(
            code: nil,
            staticCode: staticCode,
            information: information,
            shouldCancel: shouldCancel
        )
    }

    public static func identity(
        code: SecCode?,
        staticCode: SecStaticCode,
        information: [String: Any],
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> ProcessIdentity {
        guard !shouldCancel() else { throw StaticCodeIdentityResolverError.cancelled }
        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        if let code {
            let noNetwork = SecCSFlags(rawValue: 1 << 29)
            let dynamicValidity = SecCodeCheckValidity(code, noNetwork, nil)
            guard dynamicValidity == errSecSuccess ||
                    (identifier == nil && dynamicValidity == errSecCSUnsigned) else {
                throw StaticCodeIdentityResolverError.codeLookupFailed(dynamicValidity)
            }
        }
        let strictNoNetwork = SecCSFlags(rawValue: (1 << 4) | (1 << 9) | (1 << 29))
        let staticValidity = SecStaticCodeCheckValidity(staticCode, strictNoNetwork, nil)
        if identifier == nil {
            guard staticValidity == errSecCSUnsigned else {
                throw StaticCodeIdentityResolverError.codeLookupFailed(staticValidity)
            }
            return try unsignedIdentity(information, shouldCancel: shouldCancel)
        }
        guard staticValidity == errSecSuccess, let identifier else {
            throw StaticCodeIdentityResolverError.codeLookupFailed(staticValidity)
        }
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & 0x0002 != 0 {
            guard let cdHash = information[kSecCodeInfoUnique as String] as? Data else {
                throw StaticCodeIdentityResolverError.invalidSigningInformation
            }
            return .adHoc(cdHash: try digest(cdHash, count: 20))
        }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        if information[kSecCodeInfoPlatformIdentifier as String] != nil {
            return .applePlatform(try SignedCodeIdentity(
                teamIdentifier: team,
                signingIdentifier: identifier
            ))
        }
        let signerKind = signedCodeKind(
            hasTeamIdentifier: team != nil,
            satisfiesDeveloperID: satisfies(staticCode, requirement: developerIDRequirement),
            satisfiesAppStore: satisfies(staticCode, requirement: appStoreRequirement)
        )
        if signerKind == .developerID || signerKind == .appStore {
            let signed = try SignedCodeIdentity(teamIdentifier: team, signingIdentifier: identifier)
            return signerKind == .developerID ? .developerID(signed) : .appStore(signed)
        }
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let key = SecCertificateCopyKey(leaf) else {
            throw StaticCodeIdentityResolverError.invalidSigningInformation
        }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw StaticCodeIdentityResolverError.invalidSigningInformation
        }
        return .otherSigner(
            publicKeyHash: try digest(Data(SHA256.hash(data: external)), count: 32),
            signingIdentifier: identifier
        )
    }

    static func signedCodeKind(
        hasTeamIdentifier: Bool,
        satisfiesDeveloperID: Bool,
        satisfiesAppStore: Bool
    ) -> StaticCodeSignerKind {
        guard hasTeamIdentifier else { return .other }
        switch (satisfiesDeveloperID, satisfiesAppStore) {
        case (true, false): return .developerID
        case (false, true): return .appStore
        default: return .other
        }
    }

    private static func satisfies(_ code: SecStaticCode, requirement source: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let noNetwork = SecCSFlags(rawValue: 1 << 29)
        return SecStaticCodeCheckValidity(code, noNetwork, requirement) == errSecSuccess
    }

    private static func signingInformation(
        for staticCode: SecStaticCode
    ) throws -> [String: Any] {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: 1 << 1),
            &information
        )
        guard status == errSecSuccess, let values = information as? [String: Any] else {
            throw StaticCodeIdentityResolverError.codeLookupFailed(status)
        }
        return values
    }

    private static func unsignedIdentity(
        _ information: [String: Any],
        shouldCancel: @Sendable () -> Bool
    ) throws -> ProcessIdentity {
        guard let url = information[kSecCodeInfoMainExecutable as String] as? URL else {
            throw StaticCodeIdentityResolverError.invalidSigningInformation
        }
        let hash: CodeDigest
        do {
            hash = try SecureExecutableHasher.hash(at: url, shouldCancel: shouldCancel)
        } catch let error as SecureExecutableHashError {
            switch error {
            case .fileTooLarge:
                throw StaticCodeIdentityResolverError.fileTooLarge
            case .fileChanged:
                throw StaticCodeIdentityResolverError.executableChanged
            case .cancelled:
                throw StaticCodeIdentityResolverError.cancelled
            case .metadataFailed(let code), .openFailed(let code), .readFailed(let code):
                throw StaticCodeIdentityResolverError.executableReadFailed(code)
            case .invalidLimits, .notFileURL, .pathIsNotAbsolute, .symbolicLink,
                    .notRegularFile, .notExecutable, .unsafePermissions,
                    .nonLocalFileSystem:
                throw StaticCodeIdentityResolverError.unsafeExecutable
            }
        }
        return try .unsigned(path: url.standardizedFileURL.path, fileHash: hash)
    }

    private static func digest(_ data: Data, count: Int) throws -> CodeDigest {
        try CodeDigest(hex: data.map { String(format: "%02x", $0) }.joined(), expectedByteCount: count)
    }
}

enum StaticCodeSignerKind: Equatable {
    case developerID
    case appStore
    case other
}
