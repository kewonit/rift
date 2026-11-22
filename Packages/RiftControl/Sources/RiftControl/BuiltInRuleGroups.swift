import Foundation
import RiftCore

/// Rule groups Rift can add when the person asks; none is added at setup.
///
/// macOS Services allows Apple's own system services to reach Apple's
/// servers, so Ask and Block Unless Allowed don't interrupt iCloud, updates
/// or certificate checks. Each rule names one service by Apple's signature,
/// so another app can't use them. They're ordinary rules: they can be
/// edited, turned off with the group, or deleted.
public enum BuiltInRuleGroups {
    public static let macOSServicesName = "macOS Services"

    /// Apple's own domains, each with its subdomains.
    static let appleDomains = [
        "apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com",
        "mzstatic.com", "cdn-apple.com", "aaplimg.com", "me.com",
    ]

    /// Services that talk to Apple's servers.
    static let appleServices = [
        "com.apple.apsd", "com.apple.akd", "com.apple.cloudd", "com.apple.bird",
        "com.apple.cloudphotod", "com.apple.softwareupdated", "com.apple.mobileassetd",
        "com.apple.locationd", "com.apple.geod", "com.apple.parsecd", "com.apple.assistantd",
        "com.apple.identityservicesd", "com.apple.imagent", "com.apple.syspolicyd",
        "com.apple.storedownloadd", "com.apple.networkserviceproxy", "com.apple.icloud.searchpartyd",
        "com.apple.itunescloudd", "com.apple.ScreenTimeAgent", "com.apple.familycircled",
        "com.apple.tipsd", "com.apple.helpd", "com.apple.remindd", "com.apple.nsurlsessiond",
        "com.apple.trustd", "com.apple.timed",
    ]

    public static func macOSServices(lineageID: UUID, now: Date) throws -> (group: LocalRuleGroup, rules: [Rule]) {
        let group = LocalRuleGroup(
            id: UUID(), name: macOSServicesName,
            note: "Lets Apple’s own system services reach Apple’s servers. Added by Rift when you asked for it.",
            isEnabled: true, createdAt: now, modifiedAt: now
        )
        let domains = try DestinationCondition.normalizedDomainSet(appleDomains.map { try DomainName($0) })
        func rule(
            _ identifier: String, owner: OwnerCondition, destination: DestinationCondition,
            transport: ProtocolCondition = .anySupportedProtocol, port: PortRange? = nil, note: String
        ) throws -> Rule {
            try Rule(
                id: UUID(), lineageID: lineageID, revision: 1, action: .filter(.allow), priority: .normal,
                process: .exact(.applePlatform(SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: identifier))),
                destination: destination, transportProtocol: transport, port: port,
                direction: .outgoing, owner: owner, localGroupID: group.id,
                notes: note, createdAt: now, modifiedAt: now
            )
        }
        var rules: [Rule] = []
        for owner in [OwnerCondition.authorizedUser, .system] {
            for identifier in appleServices {
                rules.append(try rule(identifier, owner: owner, destination: domains, note: "Apple’s servers."))
            }
            // Certificate checks go to whichever authority issued a
            // certificate, over plain HTTP.
            rules.append(try rule(
                "com.apple.trustd", owner: owner, destination: .anyEndpoint, transport: .tcp,
                port: try PortRange(80, 80), note: "Certificate revocation checks."
            ))
            // The clock can be set from any network time server.
            rules.append(try rule(
                "com.apple.timed", owner: owner, destination: .anyEndpoint, transport: .udp,
                port: try PortRange(123, 123), note: "Network time."
            ))
        }
        return (group, rules)
    }
}
