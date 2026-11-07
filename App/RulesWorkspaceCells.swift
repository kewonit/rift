import RiftControl
import RiftCore
import SwiftUI

extension RulesWorkspaceTable {
    func rows(_ node: RuleWorkspaceNode) -> [RuleRowViewValue] {
        if let row = node.row { return [row] }
        return node.children?.compactMap(\.row) ?? []
    }

    func canToggle(_ node: RuleWorkspaceNode) -> Bool {
        let values = rows(node)
        return !isPreview && !values.isEmpty && values.allSatisfy {
            !$0.rule.flags.contains(.protected) && !$0.rule.flags.contains(.sourceManaged)
        }
    }

    func enabledSymbol(_ node: RuleWorkspaceNode) -> String {
        let values = rows(node).map(\.rule.isEnabled)
        if values.allSatisfy({ $0 }) { return "checkmark.circle.fill" }
        if values.allSatisfy({ !$0 }) { return "circle" }
        return "minus.circle.fill"
    }

    func enabledColor(_ node: RuleWorkspaceNode) -> Color {
        switch enabledSymbol(node) {
        case "checkmark.circle.fill", "circle": .secondary
        default: Color(nsColor: .systemOrange)
        }
    }

    func enabledLabel(_ node: RuleWorkspaceNode) -> String {
        switch enabledSymbol(node) {
        case "checkmark.circle.fill": "On"
        case "circle": "Off"
        default: "Some on"
        }
    }

    func action(_ node: RuleWorkspaceNode) -> String {
        node.row?.actionLabel ?? ruleCountLabel(node.ruleIDs.count)
    }

    func scope(_ node: RuleWorkspaceNode) -> String {
        uniform(rows(node).map(scope))
    }

    func scope(_ row: RuleRowViewValue) -> String {
        let profile = row.rule.profileID.flatMap { id in
            model.profiles.first { $0.id == id }?.name
        } ?? "All profiles"
        let group = row.rule.localGroupID.flatMap { id in
            model.groups.first { $0.id == id }?.name
        }
        return DisplaySanitizer.plainText(group.map { "\(profile) • \($0)" } ?? profile)
    }

    func source(_ node: RuleWorkspaceNode) -> String {
        uniform(rows(node).map(source))
    }

    func source(_ row: RuleRowViewValue) -> String {
        if row.rule.flags.contains(.protected) { return "Protected" }
        switch row.rule.priority {
        case .elevatedUser: return "Exception"
        case .blocklistDeny: return "Blocklist"
        case .normal: return "Manual"
        }
    }

    func usage(_ node: RuleWorkspaceNode) -> String {
        let values = rows(node)
        var total = 0
        for row in values {
            let next = total.addingReportingOverflow(row.usage.lowerBoundCount)
            guard !next.overflow else { return "—" }
            total = next.partialValue
        }
        return values.allSatisfy { $0.usage.coverage == .complete } ? String(total) : "≥\(total)"
    }

    func usageHelp(_ node: RuleWorkspaceNode) -> String {
        let values = rows(node)
        if values.allSatisfy({ $0.usage.coverage == .complete }) {
            return "How many times this rule was used in saved history."
        }
        return "At least this many. Some history is missing."
    }

    func state(_ node: RuleWorkspaceNode) -> String {
        uniform(rows(node).map(\.effectiveState.label))
    }

    func ruleCountLabel(_ count: Int) -> String {
        count == 1 ? "1 rule" : "\(count) rules"
    }

    func uniform(_ values: [String]) -> String {
        guard let first = values.first else { return "—" }
        return values.dropFirst().allSatisfy { $0 == first } ? first : "Mixed"
    }
}

func applicationIdentity(_ condition: ProcessCondition) -> ProcessIdentity? {
    switch condition {
    case .exact(let identity): identity
    case .appViaHelper(let app, _): app
    case .anyProcess: nil
    }
}

extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
