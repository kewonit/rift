import RiftControl
import RiftCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct RuleWorkspaceDragPayload: Hashable, Sendable {
    let token: UUID

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(token.uuidString.utf8)
        provider.suggestedName = token.uuidString
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.riftRuleWorkspaceDragToken.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

@MainActor
final class RuleWorkspaceDragRegistry {
    private struct Entry {
        let ruleIDs: Set<UUID>
        let generation: UInt64
        let expiresAt: Date
    }

    static let shared = RuleWorkspaceDragRegistry()
    private var entries: [UUID: Entry] = [:]
    private let lifetime: TimeInterval = 120
    private let maximumEntries = 32

    func issue(ruleIDs: Set<UUID>, generation: UInt64, now: Date = Date())
        -> RuleWorkspaceDragPayload {
        purge(now: now)
        if entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        let token = UUID()
        entries[token] = Entry(
            ruleIDs: ruleIDs,
            generation: generation,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        return RuleWorkspaceDragPayload(token: token)
    }

    func consume(
        _ payloads: [RuleWorkspaceDragPayload],
        generation: UInt64,
        now: Date = Date()
    ) -> Set<UUID>? {
        purge(now: now)
        let tokens = payloads.map(\.token)
        guard !tokens.isEmpty, Set(tokens).count == tokens.count else { return nil }
        let selected = tokens.compactMap { entries[$0] }
        guard selected.count == tokens.count,
              selected.allSatisfy({ $0.generation == generation }) else { return nil }
        var result: Set<UUID> = []
        selected.forEach { result.formUnion($0.ruleIDs) }
        guard !result.isEmpty else { return nil }
        tokens.forEach { entries.removeValue(forKey: $0) }
        return result
    }

    private func purge(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

struct RuleWorkspaceDropRequest: Identifiable {
    let id = UUID()
    let ruleIDs: Set<UUID>
    let target: RuleWorkspaceDropTarget
    let targetName: String
    let operation: RuleWorkspaceDropOperation
    let affectedCount: Int
    let skippedCount: Int
    let unchangedCount: Int
    let newRuleIDs: [UUID]

    var resultRuleIDs: Set<UUID> {
        operation == .copy ? Set(newRuleIDs) : ruleIDs
    }

    var title: String { "\(verb) \(countLabel) to “\(displayName)”?" }
    var actionTitle: String { "\(verb) \(countLabel)" }

    var message: String {
        let preservedScope = target.isGroup
            ? "Profile assignments stay unchanged."
            : "Group assignments stay unchanged."
        var parts = operation == .copy
            ? ["Copies receive new rule identities.", preservedScope]
            : [preservedScope]
        if unchangedCount > 0 {
            parts.append(unchangedMessage)
        }
        if skippedCount > 0 {
            parts.append(skippedMessage)
        }
        parts.append("Existing connections keep their current decision.")
        return parts.joined(separator: " ")
    }

    private var verb: String { operation == .copy ? "Copy" : "Move" }
    private var countLabel: String {
        affectedCount == 1 ? "1 Rule" : "\(affectedCount) Rules"
    }
    private var displayName: String {
        let sanitized = DisplaySanitizer.plainText(targetName)
        return sanitized.isEmpty ? (target.isGroup ? "Group" : "Profile") : sanitized
    }
    private var unchangedMessage: String {
        unchangedCount == 1
            ? "1 rule is already assigned and will stay unchanged."
            : "\(unchangedCount) rules are already assigned and will stay unchanged."
    }
    private var skippedMessage: String {
        skippedCount == 1
            ? "1 protected or managed rule will be skipped."
            : "\(skippedCount) protected or managed rules will be skipped."
    }
}

extension RuleWorkspaceDropTarget {
    var isGroup: Bool {
        if case .localGroup = self { return true }
        return false
    }
}

private extension UTType {
    static let riftRuleWorkspaceDragToken = UTType(
        exportedAs: "io.rift.firewall.rule-workspace-drag-token",
        conformingTo: .data
    )
}

private struct RuleWorkspaceDropTargetModifier: ViewModifier {
    @Bindable var model: RulesWorkspaceController
    let target: RuleWorkspaceDropTarget
    let selection: RulesSidebarSelection
    @Binding var pendingDrop: RuleWorkspaceDropRequest?
    @Binding var activeSelection: RulesSidebarSelection?

    func body(content: Content) -> some View {
        let isTargeted = Binding(
            get: { activeSelection == selection },
            set: { active in
                if active {
                    activeSelection = selection
                } else if activeSelection == selection {
                    activeSelection = nil
                }
            }
        )
        content
            .listRowBackground(
                activeSelection == selection ? Color.accentColor.opacity(0.14) : Color.clear
            )
            .help("Drop selected rules here. Hold Option while dropping to copy.")
            .onDrop(
                of: [.riftRuleWorkspaceDragToken],
                isTargeted: isTargeted
            ) { providers in
                guard providers.count == 1,
                      providers[0].hasItemConformingToTypeIdentifier(
                          UTType.riftRuleWorkspaceDragToken.identifier
                      ),
                      let tokenValue = providers[0].suggestedName,
                      let token = UUID(uuidString: tokenValue) else {
                    return false
                }
                guard let ruleIDs = RuleWorkspaceDragRegistry.shared.consume(
                    [RuleWorkspaceDragPayload(token: token)],
                    generation: model.generation
                ) else {
                    return false
                }
                let operation: RuleWorkspaceDropOperation = NSEvent.modifierFlags.contains(.option)
                    ? .copy
                    : .move
                guard let request = model.prepareRuleDrop(
                    ruleIDs: ruleIDs,
                    target: target,
                    operation: operation
                ) else {
                    return false
                }
                pendingDrop = request
                return true
            }
    }
}

extension View {
    func ruleWorkspaceDropTarget(
        model: RulesWorkspaceController,
        target: RuleWorkspaceDropTarget,
        selection: RulesSidebarSelection,
        pendingDrop: Binding<RuleWorkspaceDropRequest?>,
        activeSelection: Binding<RulesSidebarSelection?>
    ) -> some View {
        modifier(RuleWorkspaceDropTargetModifier(
            model: model,
            target: target,
            selection: selection,
            pendingDrop: pendingDrop,
            activeSelection: activeSelection
        ))
    }
}
