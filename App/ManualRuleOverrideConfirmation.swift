import RiftControl
import RiftCore

enum ManualRuleOverrideConfirmation {
    static func message(draft: ManualRuleDraft, applicationLabel: String) -> String {
        let destination: String
        switch draft.destination {
        case .ipSet(let values):
            destination = boundedSummary(values.map(\.description), noun: ("IP address", "IP addresses"))
        case .exactHostnameSet(let values):
            destination = boundedSummary(values.map(\.ascii), noun: ("host", "hosts"))
        case .domainSet, .endpointClass, .anyEndpoint:
            destination = "Too broad for an exception"
        }
        return "App: \(bounded(applicationLabel))\nDestination: \(destination)\nThis exception allows these connections even if a blocklist denies them."
    }

    private static func boundedSummary(_ values: [String], noun: (one: String, many: String)) -> String {
        guard let first = values.first else { return "No destination" }
        let remainder = values.count - 1
        return remainder == 0
            ? bounded(first)
            : "\(bounded(first)) and \(remainder) more \(remainder == 1 ? noun.one : noun.many)"
    }

    private static func bounded(_ value: String) -> String {
        let prefix = value.prefix(96)
        return prefix.count == value.count ? String(prefix) : String(prefix) + "…"
    }
}
