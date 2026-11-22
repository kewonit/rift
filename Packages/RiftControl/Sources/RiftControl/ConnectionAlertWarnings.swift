import Foundation
import RiftCore
import RiftIPC

/// A reason to look twice before answering an alert. Each one comes from facts
/// Rift already has, so none of them needs a lookup or a network request.
public enum ConnectionAlertWarning: Sendable, Hashable {
    case unsigned(helper: Bool)
    case selfSigned(helper: Bool)
    case unrecognizedCertificate(helper: Bool)
    case translocated
    case internationalName

    /// Each sentence is whole, for the app and for its helper, so it can be
    /// translated without joining pieces.
    public var message: String {
        switch self {
        case .unsigned(false):
            String(localized: "This app isn’t signed, so Rift can’t tell who made it. A rule for it stops working if the file changes.", bundle: .module)
        case .unsigned(true):
            String(localized: "The helper that made this connection isn’t signed, so Rift can’t tell who made it. A rule for it stops working if the file changes.", bundle: .module)
        case .selfSigned(false):
            String(localized: "This app is signed only by itself, so Rift can’t tell who made it. A rule for it stops working when it’s rebuilt or updated.", bundle: .module)
        case .selfSigned(true):
            String(localized: "The helper that made this connection is signed only by itself, so Rift can’t tell who made it. A rule for it stops working when it’s rebuilt or updated.", bundle: .module)
        case .unrecognizedCertificate(false):
            String(localized: "This app is signed with a certificate Apple didn’t issue, so Rift can’t confirm who made it.", bundle: .module)
        case .unrecognizedCertificate(true):
            String(localized: "The helper that made this connection is signed with a certificate Apple didn’t issue, so Rift can’t confirm who made it.", bundle: .module)
        case .translocated:
            String(localized: "macOS is running this app from a temporary copy, because it was opened where it was downloaded. Move it to Applications and open it again, or a rule for it won’t match next time.", bundle: .module)
        case .internationalName:
            String(localized: "This name uses international letters, shown in their xn-- form. Check it isn’t imitating a name you know.", bundle: .module)
        }
    }
}

public enum ConnectionAlertWarnings {
    /// Whether allowing should take a deliberate click or ⌘A instead of
    /// Return. Any warning is a reason to read the alert first.
    public static func requiresDeliberateAllow(for prompt: PromptRequest) -> Bool {
        !warnings(for: prompt).isEmpty
    }

    /// Warnings for one alert, most serious first.
    public static func warnings(for prompt: PromptRequest) -> [ConnectionAlertWarning] {
        var result: [ConnectionAlertWarning] = []
        if let app = prompt.appIdentity ?? prompt.processIdentity,
           let warning = warning(for: app, helper: false) {
            result.append(warning)
        }
        if let app = prompt.appIdentity, let helper = prompt.processIdentity, helper != app,
           let warning = warning(for: helper, helper: true) {
            result.append(warning)
        }
        if [prompt.appIdentity, prompt.processIdentity].contains(where: isTranslocated) {
            result.append(.translocated)
        }
        if let hostname = prompt.endpoint?.hostname, hasInternationalLabel(hostname) {
            result.append(.internationalName)
        }
        return result
    }

    private static func warning(
        for identity: ProcessIdentity,
        helper: Bool
    ) -> ConnectionAlertWarning? {
        switch identity {
        case .applePlatform, .developerID, .appStore: nil
        case .otherSigner: .unrecognizedCertificate(helper: helper)
        case .adHoc: .selfSigned(helper: helper)
        case .unsigned: .unsigned(helper: helper)
        }
    }

    /// Gatekeeper runs quarantined apps from a randomized read-only path.
    /// Only unsigned code carries its path, so only it can be recognized.
    private static func isTranslocated(_ identity: ProcessIdentity?) -> Bool {
        guard case .unsigned(let path, _) = identity else { return false }
        return path.hasPrefix("/private/var/folders/") && path.contains("/AppTranslocation/")
    }

    private static func hasInternationalLabel(_ name: DomainName) -> Bool {
        name.ascii.split(separator: ".").contains { $0.hasPrefix("xn--") }
    }
}
