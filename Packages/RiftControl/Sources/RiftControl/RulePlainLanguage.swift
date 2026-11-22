import Foundation
import RiftCore

/// Describes rule changes in the words someone would use themselves.
public enum RulePlainLanguage {
    public static func change(
        action: FilterAction,
        application: String,
        destination: String,
        port: UInt16?,
        incoming: Bool = false,
        forOneHour: Bool = false,
        lasting: String? = nil,
        isPreview: Bool = false
    ) -> String {
        // The port and duration are optional phrases that each begin with a
        // space, so a sentence reads the same with or without them.
        // A port is an identifier, so it's never written with a thousands separator.
        let onPort = port.map { String(localized: " on port \(String($0))", bundle: .module) } ?? ""
        let phrase = lasting ?? (forOneHour ? String(localized: "one hour", bundle: .module) : nil)
        let duration = phrase.map {
            String(localized: " for \($0)", bundle: .module, comment: "How long a rule lasts, like “ for one hour”")
        } ?? ""
        if incoming {
            return switch (action == .deny, isPreview) {
            case (true, true):
                String(localized: "Incoming connections to \(application)\(onPort) will be blocked\(duration).", bundle: .module)
            case (true, false):
                String(localized: "Incoming connections to \(application)\(onPort) are now blocked\(duration).", bundle: .module)
            case (false, true):
                String(localized: "Incoming connections to \(application)\(onPort) will be allowed\(duration).", bundle: .module)
            case (false, false):
                String(localized: "Incoming connections to \(application)\(onPort) are now allowed\(duration).", bundle: .module)
            }
        }
        return switch (action == .deny, isPreview) {
        case (true, true):
            String(localized: "\(application) will be blocked from \(destination)\(onPort)\(duration).", bundle: .module)
        case (true, false):
            String(localized: "\(application) is now blocked from \(destination)\(onPort)\(duration).", bundle: .module)
        case (false, true):
            String(localized: "\(application) will be able to connect to \(destination)\(onPort)\(duration).", bundle: .module)
        case (false, false):
            String(localized: "\(application) can now connect to \(destination)\(onPort)\(duration).", bundle: .module)
        }
    }
}
