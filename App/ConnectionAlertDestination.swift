import RiftControl
import RiftCore
import SwiftUI

/// What a rule made from the alert can cover.
extension ConnectionAlertView {
    /// The domain the connection's name was registered under, like
    /// `example.co.uk` for `www.example.co.uk`.
    var registeredDomain: String? {
        guard prompt.direction == .outgoing, let host = prompt.endpoint?.hostname else { return nil }
        return PublicSuffixList.shared.registrableDomain(of: host)?.ascii
    }

    /// A domain choice appears only when there's a name to take it from.
    var destinationChoices: [DestinationScope] {
        DestinationScope.allCases.filter { $0 != .domain || registeredDomain != nil }
    }

    /// The last moment to answer: the filter's deadline, or a little before
    /// it when Rift answers Block for unanswered connections.
    var answerDeadline: Date {
        ConnectionAlertCountdown.blocksUnanswered
            ? prompt.deadline.addingTimeInterval(-ConnectionAlertCountdown.blockLead) : prompt.deadline
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
