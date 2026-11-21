import RiftControl
import RiftCore
import SwiftUI

/// Edit Rules…: changes the same things on several rules at once. Every
/// choice starts at No Change, so only what's picked is touched.
struct RuleBulkEditSheet: View {
    let rules: [Rule]
    let save: (RuleBulkEdit) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var action: ActionChoice = .unchanged
    @State private var transport: ProtocolChoice = .unchanged
    @State private var port: PortChoice = .unchanged
    @State private var portText = ""
    @State private var replacesNote = false
    @State private var note = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.m) {
            Text(rules.count == 1 ? "Edit 1 Rule" : "Edit \(rules.count) Rules").font(.headline)
            Form {
                Picker("Action", selection: $action) {
                    ForEach(ActionChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Protocol", selection: $transport) {
                    ForEach(ProtocolChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Port", selection: $port) {
                    ForEach(PortChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                if port == .specific {
                    TextField("Port or range", text: $portText, prompt: Text("443 or 8000-8080"))
                }
                Toggle("Replace notes", isOn: $replacesNote)
                if replacesNote {
                    TextField("Notes", text: $note, prompt: Text("Leave empty to clear notes"), axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            Text("Blocklist and protected rules aren’t changed. To undo, choose Edit › Undo Edit Rules (⌥⌘Z).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (try? edit())?.isEmpty != false)
            }
        }
        .padding(RiftDesign.Spacing.l)
        .frame(width: 420)
        .onChange(of: [action.rawValue, transport.rawValue, port.rawValue, portText, note]) { problem = nil }
    }

    private func edit() throws -> RuleBulkEdit {
        let portChange: RuleBulkEdit.PortChange?
        switch port {
        case .unchanged: portChange = nil
        case .any: portChange = .any
        case .specific: portChange = .range(try Self.parsePort(portText))
        }
        return RuleBulkEdit(
            action: action.value,
            transport: transport.value,
            port: portChange,
            note: replacesNote ? note.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    private func submit() async {
        let edit: RuleBulkEdit
        do {
            edit = try self.edit()
        } catch {
            problem = "Enter a port, like 443, or a range, like 8000-8080."
            return
        }
        // Check every rule first, so nothing is saved if one can't change.
        do {
            _ = try edit.applied(to: rules, ids: Set(rules.map(\.id)), now: Date())
        } catch RuleValidationError.elevatedPriorityRequiresAllow {
            problem = "A selected rule is a blocklist exception, which can only allow. Leave the action as it is, or deselect that rule."
            return
        } catch RuleValidationError.notesTooLong {
            problem = "The notes are too long."
            return
        } catch {
            problem = "Not every selected rule can take these changes. Nothing was changed."
            return
        }
        saving = true
        defer { saving = false }
        if await save(edit) { dismiss() }
    }

    private static func parsePort(_ input: String) throws -> PortRange {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let lower = UInt16(parts[0].trimmingCharacters(in: .whitespaces)),
              let upper = UInt16((parts.count == 2 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces))
        else { throw PortError.invalid }
        return try PortRange(lower, upper)
    }

    private enum PortError: Error { case invalid }

    enum ActionChoice: String, CaseIterable, Identifiable {
        case unchanged = "No Change"
        case allow = "Allow"
        case deny = "Block"
        case ask = "Ask"
        var id: String { rawValue }
        var value: RuleAction? {
            switch self {
            case .unchanged: nil
            case .allow: .filter(.allow)
            case .deny: .filter(.deny)
            case .ask: .filter(.ask)
            }
        }
    }

    enum ProtocolChoice: String, CaseIterable, Identifiable {
        case unchanged = "No Change"
        case any = "TCP or UDP"
        case tcp = "TCP"
        case udp = "UDP"
        var id: String { rawValue }
        var value: ProtocolCondition? {
            switch self {
            case .unchanged: nil
            case .any: .anySupportedProtocol
            case .tcp: .tcp
            case .udp: .udp
            }
        }
    }

    enum PortChoice: String, CaseIterable, Identifiable {
        case unchanged = "No Change"
        case any = "Any Port"
        case specific = "Port or Range"
        var id: String { rawValue }
    }
}
