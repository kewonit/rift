import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// What a rule made from the alert can cover.
extension ConnectionAlertView {
    typealias Lifetime = AlertLifetime
    typealias DestinationScope = AlertDestinationChoice

    enum RuleScope: String, CaseIterable, Identifiable {
        case currentProfile = "Current profile"
        case allProfiles = "All profiles"
        var id: String { rawValue }
    }

    /// The domain the connection's name was registered under, like
    /// `example.co.uk` for `www.example.co.uk`.
    var registeredDomain: String? {
        guard prompt.direction == .outgoing, let host = prompt.endpoint?.hostname else { return nil }
        return PublicSuffixList.shared.registrableDomain(of: host)?.ascii
    }

    /// The name "First time this app has connected to …" uses.
    var firstContactDomain: String? {
        guard prompt.direction == .outgoing else { return nil }
        return registeredDomain ?? prompt.endpoint?.hostname?.ascii
    }

    /// A developer can describe a whole domain, or any destination, for when
    /// the person chooses one of those in the alert.
    func policyChoice(lifetime: Lifetime, destination: DestinationScope) -> InternetAccessPolicyQuery.Choice {
        guard lifetime != .once else { return .thisConnection }
        switch destination {
        case .domain: return registeredDomain.map { .domain($0) } ?? .thisConnection
        case .any: return .anyDestination
        case .exact, .anyPort: return .thisConnection
        }
    }

    /// A domain choice appears only when there's a name to take it from.
    var destinationChoices: [DestinationScope] {
        DestinationScope.allCases.filter { $0 != .domain || registeredDomain != nil }
    }

    /// Other waiting connections from the same app, which a Once answer can
    /// cover too. A lasting rule needs no help: the filter checks every
    /// waiting connection again when the rules change.
    var sameAppWaiting: [PromptRequest] {
        guard let identity = prompt.appIdentity ?? prompt.processIdentity else { return [] }
        return others.filter { ($0.appIdentity ?? $0.processIdentity) == identity && $0.direction == prompt.direction }
    }

    /// Names the active profile, so it's clear where a new rule lands.
    func scopeTitle(_ scope: RuleScope) -> String {
        guard scope == .currentProfile, let name = currentProfileName else { return scope.rawValue }
        return "Current profile (\(DisplaySanitizer.plainText(name)))"
    }

    /// The last moment to answer: the filter's deadline, or a little before
    /// it when Rift has to answer Block for an older filter.
    var answerDeadline: Date {
        ConnectionAlertCountdown.outcome(for: prompt).answerDeadline(for: prompt)
    }

    /// The destination as it reads in a sentence about the new rule.
    func destinationPhrase(for scope: DestinationScope) -> String {
        switch scope {
        case .any: "any destination"
        case .domain: "\(registeredDomain ?? "this domain") and its subdomains"
        case .exact, .anyPort: DisplaySanitizer.plainText(ConnectionAlertFacts(prompt: prompt).destination)
        }
    }
}
