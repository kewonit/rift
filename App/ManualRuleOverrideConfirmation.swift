import Foundation
import RiftControl
import RiftCore

enum ManualRuleOverrideConfirmation {
    static func message(draft: ManualRuleDraft, applicationLabel: String) -> String {
        let destination: String
        switch draft.destination {
        case .ipSet(let values):
            destination = boundedSummary(values.map(\.description), hosts: false)
        case .exactHostnameSet(let values):
            destination = boundedSummary(values.map(\.ascii), hosts: true)
        case .domainSet, .endpointClass, .anyEndpoint:
            destination = String(localized: "Too broad for an exception")
        }
        return String(localized: "App: \(bounded(applicationLabel))\nDestination: \(destination)\nThis exception allows these connections even if a blocklist denies them.")
    }

    private static func boundedSummary(_ values: [String], hosts: Bool) -> String {
        guard let first = values.first else { return String(localized: "No destination") }
        let remainder = values.count - 1
        guard remainder > 0 else { return bounded(first) }
        return hosts
            ? String(localized: "\(bounded(first)) and \(remainder) more hosts")
            : String(localized: "\(bounded(first)) and \(remainder) more IP addresses")
    }

    private static func bounded(_ value: String) -> String {
        let prefix = value.prefix(96)
        return prefix.count == value.count ? String(prefix) : String(prefix) + "…"
    }
}
