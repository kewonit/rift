import AbyssControl
import AbyssCore

enum ManualRuleOverrideConfirmation {
    static func message(draft: ManualRuleDraft, applicationLabel: String) -> String {
        let destination: String
        switch draft.destination {
        case .ipSet(let values):
            destination = boundedSummary(values.map(\.description), pluralNoun: "IP matches")
        case .exactHostnameSet(let values):
            destination = boundedSummary(values.map(\.ascii), pluralNoun: "exact hosts")
        case .domainSet, .endpointClass, .anyEndpoint:
            destination = "Invalid broad destination"
        }
        return "Application: \(bounded(applicationLabel))\nDestination: \(destination)\nThis allow exception outranks matching managed lists."
    }

    private static func boundedSummary(_ values: [String], pluralNoun: String) -> String {
        guard let first = values.first else { return "No destination" }
        let remainder = values.count - 1
        return remainder == 0
            ? bounded(first)
            : "\(bounded(first)) and \(remainder) more \(pluralNoun)"
    }

    private static func bounded(_ value: String) -> String {
        let prefix = value.prefix(96)
        return prefix.count == value.count ? String(prefix) : String(prefix) + "…"
    }
}
