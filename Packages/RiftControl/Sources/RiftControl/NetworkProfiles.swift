import Foundation
import RiftCore

/// The network the Mac is on, as Rift tells networks apart: a Wi-Fi network
/// by its name when the person lets Rift read it, otherwise by the kind of
/// connection and the router's address.
public struct NetworkIdentity: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case wifi
        case wired
        case other
    }

    public let kind: Kind
    public let wifiName: String?
    public let router: String?

    public init(kind: Kind, wifiName: String?, router: String?) {
        self.kind = kind
        // Control and direction characters are dropped, so a network's name
        // can't rearrange the text around it.
        let name = wifiName.map { String($0.withoutControlCharacters.prefix(64)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.wifiName = kind == .wifi ? name : nil
        self.router = router.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
    }

    /// What a remembered network is stored under, or nil when there's
    /// nothing to recognize it by.
    public var key: String? {
        if let wifiName { return "wifi-name:" + wifiName }
        guard let router else { return nil }
        return kind.rawValue + "-router:" + router
    }

    /// The network's name in the person's language. A Wi-Fi name is shown as it is.
    public var displayName: String {
        if let wifiName { return wifiName }
        return switch (kind, router) {
        case (.wifi, let router?): String(localized: "Wi-Fi with router \(router)", bundle: .module)
        case (.wired, let router?): String(localized: "Ethernet with router \(router)", bundle: .module)
        case (.other, let router?): String(localized: "Network with router \(router)", bundle: .module)
        case (.wifi, nil): String(localized: "Wi-Fi", bundle: .module)
        case (.wired, nil): String(localized: "Ethernet", bundle: .module)
        case (.other, nil): String(localized: "Network", bundle: .module)
        }
    }

    /// The name a remembered network is saved with. It stays in English, so
    /// what's saved doesn't depend on the language Rift ran in.
    public var storedName: String {
        if let wifiName { return wifiName }
        let kindName = switch kind {
        case .wifi: "Wi-Fi"
        case .wired: "Ethernet"
        case .other: "Network"
        }
        return router.map { "\(kindName) with router \($0)" } ?? kindName
    }

    /// The name to show for a remembered network, worked out again from the
    /// key it's saved under, or nil when the key isn't one Rift made.
    public static func displayName(forKey key: String) -> String? {
        if key.hasPrefix("wifi-name:") { return String(key.dropFirst("wifi-name:".count)) }
        guard let separator = key.range(of: "-router:"),
              let kind = Kind(rawValue: String(key[..<separator.lowerBound])) else { return nil }
        let router = String(key[separator.upperBound...])
        return NetworkIdentity(kind: kind, wifiName: nil, router: router).displayName
    }
}

/// What to do on a network.
public enum NetworkProfileChoice: Sendable, Hashable, Codable {
    case leaveAsIs
    case noProfile
    case profile(UUID)

    /// The profile to switch to, or nil to leave the profile alone.
    public var target: UUID?? {
        switch self {
        case .leaveAsIs: nil
        case .noProfile: .some(nil)
        case .profile(let id): .some(id)
        }
    }
}

public struct RememberedNetwork: Sendable, Hashable, Codable, Identifiable {
    public let key: String
    public var name: String
    public var choice: NetworkProfileChoice
    public var lastSeenAt: Date
    /// The person allowed switching to this network's profile even when it's
    /// less strict than the current one. Nil, the default, means no; it's
    /// optional so networks saved before it existed read the same way.
    public var allowsLessStrictSwitch: Bool?

    public var id: String { key }

    public init(
        key: String,
        name: String,
        choice: NetworkProfileChoice,
        lastSeenAt: Date,
        allowsLessStrictSwitch: Bool? = nil
    ) {
        self.key = key
        self.name = name
        self.choice = choice
        self.lastSeenAt = lastSeenAt
        self.allowsLessStrictSwitch = allowsLessStrictSwitch
    }
}

public enum NetworkProfileDecision {
    /// The profile to switch to on `network`, or nil to leave it alone. A
    /// remembered network uses its own choice, a new one the choice for
    /// other networks. A choice naming a profile that no longer exists
    /// leaves the profile alone.
    public static func target(
        on network: NetworkIdentity,
        remembered: [String: RememberedNetwork],
        otherNetworks: NetworkProfileChoice,
        profiles: Set<UUID>
    ) -> UUID?? {
        guard let key = network.key else { return nil }
        let choice = remembered[key]?.choice ?? otherNetworks
        guard let target = choice.target else { return nil }
        if let id = target, !profiles.contains(id) { return nil }
        return target
    }
}

extension String {
    /// Without line breaks, other control characters, or characters that
    /// change text direction, for names that come from outside Rift.
    var withoutControlCharacters: String {
        String(String.UnicodeScalarView(unicodeScalars.filter {
            !$0.properties.isBidiControl && $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
                && $0.value != 0x2028 && $0.value != 0x2029
        }))
    }
}
