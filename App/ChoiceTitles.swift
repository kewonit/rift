import Foundation

// The words shown for the choices in pickers. The raw values only tell the
// choices apart, so they stay in English.

extension RiftTimelineMode {
    var title: String {
        switch self {
        case .traffic: String(localized: "Traffic")
        case .decisions: String(localized: "Decisions")
        }
    }
}

extension RuleBulkEditSheet.ActionChoice {
    var title: String {
        switch self {
        case .unchanged: String(localized: "No Change")
        case .allow: String(localized: "Allow")
        case .deny: String(localized: "Block")
        case .ask: String(localized: "Ask")
        }
    }
}

extension RuleBulkEditSheet.ProtocolChoice {
    var title: String {
        switch self {
        case .unchanged: String(localized: "No Change")
        case .any: String(localized: "TCP or UDP")
        case .tcp: "TCP"
        case .udp: "UDP"
        }
    }
}

extension RuleBulkEditSheet.PortChoice {
    var title: String {
        switch self {
        case .unchanged: String(localized: "No Change")
        case .any: String(localized: "Any Port")
        case .specific: String(localized: "Port or Range")
        }
    }
}

extension ManualRuleEditorView.DestinationKind {
    var title: String {
        switch self {
        case .hostOrAddress: String(localized: "Specific sites or addresses")
        case .broadcast: String(localized: "Broadcast")
        case .multicast: String(localized: "Multicast")
        case .bonjour: "Bonjour"
        case .localNetwork: String(localized: "Local network")
        case .any: String(localized: "Any destination")
        }
    }
}

extension ManualRuleEditorView.ProtocolChoice {
    var title: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .any: String(localized: "TCP or UDP")
        }
    }
}

extension ManualRuleEditorView.EditorAction {
    var title: String {
        switch self {
        case .allow: String(localized: "Allow")
        case .deny: String(localized: "Block")
        case .ask: String(localized: "Ask")
        case .notify: String(localized: "Notify")
        case .hide: String(localized: "Hide from history")
        }
    }
}
