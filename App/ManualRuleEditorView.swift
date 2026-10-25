import RiftControl
import RiftCore
import SwiftUI

struct ManualRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let initial: Rule?
    let identities: [RuleIdentityChoice]
    let groups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let previewEnvironment: RulePreviewEnvironment?
    let save: (ManualRuleDraft) async -> Bool
    @State private var action: EditorAction = .allow
    @State private var process: ProcessCondition = .anyProcess
    @State private var owner: OwnerCondition = .authorizedUser
    @State private var destinationKind: DestinationKind = .hostOrAddress
    @State private var destinationText = ""
    @State private var includesChildren = false
    @State private var transport: ProtocolChoice = .any
    @State private var direction: DirectionCondition = .outgoing
    @State private var portText = ""
    @State private var temporary = false
    @State private var expiry = Date().addingTimeInterval(3_600)
    @State private var note = ""
    @State private var overrideBlocklists = false
    @State private var profileID: UUID?
    @State private var localGroupID: UUID?
    @State private var isEnabled = true
    @State private var isReviewed = true
    @State private var validation: String?
    @State private var saving = false
    @State private var pendingOverrideDraft: ManualRuleDraft?
    @State private var showingOverrideConfirmation = false
    @State private var preview: RuleImpactPreview?
    @State private var previewTask: Task<Void, Never>?

    enum DestinationKind: String, CaseIterable, Identifiable {
        case hostOrAddress = "Hosts or addresses"
        case broadcast = "Broadcast"
        case multicast = "Multicast"
        case bonjour = "Bonjour"
        case localNetwork = "Local network"
        case any = "Any destination"
        var id: String { rawValue }
    }

    enum ProtocolChoice: String, CaseIterable, Identifiable {
        case tcp = "TCP"
        case udp = "UDP"
        case any = "TCP or UDP"
        var id: String { rawValue }
        var value: ProtocolCondition {
            switch self { case .tcp: .tcp; case .udp: .udp; case .any: .anySupportedProtocol }
        }
    }

    enum EditorAction: String, CaseIterable, Identifiable {
        case allow = "Allow"
        case deny = "Deny"
        case ask = "Ask"
        case notify = "Notify"
        case hide = "Hide from history"
        var id: String { rawValue }
        var value: RuleAction {
            switch self {
            case .allow: .filter(.allow)
            case .deny: .filter(.deny)
            case .ask: .filter(.ask)
            case .notify: .notification(.notify)
            case .hide: .privacy(.hide)
            }
        }
    }

    init(
        initial: Rule? = nil,
        identities: [RuleIdentityChoice],
        groups: [LocalRuleGroup],
        profiles: [PolicyProfile],
        previewEnvironment: RulePreviewEnvironment?,
        save: @escaping (ManualRuleDraft) async -> Bool
    ) {
        self.initial = initial
        self.identities = identities
        self.groups = groups
        self.profiles = profiles
        self.previewEnvironment = previewEnvironment
        self.save = save
        if let initial {
            switch initial.action {
            case .filter(.allow): _action = State(initialValue: .allow)
            case .filter(.deny): _action = State(initialValue: .deny)
            case .filter(.ask): _action = State(initialValue: .ask)
            case .privacy: _action = State(initialValue: .hide)
            case .notification: _action = State(initialValue: .notify)
            }
            _process = State(initialValue: initial.process)
            _owner = State(initialValue: initial.owner)
            _destinationKind = State(initialValue: Self.destinationKind(initial.destination))
            _destinationText = State(initialValue: Self.destinationText(initial.destination))
            if case .domainSet = initial.destination { _includesChildren = State(initialValue: true) }
            switch initial.transportProtocol {
            case .tcp: _transport = State(initialValue: .tcp)
            case .udp: _transport = State(initialValue: .udp)
            case .anySupportedProtocol: _transport = State(initialValue: .any)
            }
            _direction = State(initialValue: initial.direction)
            _portText = State(initialValue: initial.port.map {
                $0.lowerBound == $0.upperBound
                    ? String($0.lowerBound) : "\($0.lowerBound)-\($0.upperBound)"
            } ?? "")
            _temporary = State(initialValue: initial.expiresAt != nil)
            _expiry = State(initialValue: initial.expiresAt ?? Date().addingTimeInterval(3_600))
            _note = State(initialValue: initial.notes)
            _overrideBlocklists = State(initialValue: initial.priority == .elevatedUser)
            _profileID = State(initialValue: initial.profileID)
            _localGroupID = State(initialValue: initial.localGroupID)
            _isEnabled = State(initialValue: initial.isEnabled)
            _isReviewed = State(initialValue: initial.reviewState == .reviewed)
        }
    }

    var body: some View {
        Form {
            Section("Action") {
                Picker("Action", selection: $action) {
                    ForEach(EditorAction.allCases) { Text($0.rawValue).tag($0) }
                }
                if action == .hide {
                    Text("New matches are omitted from Monitor and history. Existing records remain.")
                        .foregroundStyle(.orange)
                }
                if action == .notify {
                    Text("Notifications are rate-limited and do not change filtering.")
                        .foregroundStyle(.secondary)
                }
                if action == .allow {
                    Toggle("Override managed blocklist denies", isOn: $overrideBlocklists)
                }
            }

            Section("Match") {
                Picker("Application", selection: $process) {
                    ForEach(availableIdentities) { choice in
                        Text(choice.label).tag(choice.process)
                    }
                }
                Picker("Owner", selection: $owner) {
                    Text("Current policy owner").tag(OwnerCondition.authorizedUser)
                    Text("Observed system process").tag(OwnerCondition.system)
                        .disabled(!selectedIdentityPermitsSystemOwner)
                }
                if owner == .system {
                    Text("System scope applies across login sessions.")
                        .foregroundStyle(.orange)
                }
                Picker("Destination", selection: $destinationKind) {
                    ForEach(DestinationKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if destinationKind == .hostOrAddress {
                    TextField(
                        "Hosts, domains, IPs, CIDRs, or IP ranges",
                        text: $destinationText,
                        axis: .vertical
                    )
                    .lineLimit(3...7)
                    .disabled(includesChildren)
                    if includesChildren {
                        Text("Child-domain matching is preserved. Editing it requires public-suffix validation.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Hostnames match exactly. Child-domain matching requires public-suffix validation.")
                            .foregroundStyle(.secondary)
                    }
                    Text("\(remainingDestinationCapacity) destination entries available")
                        .foregroundStyle(.secondary)
                }
                Picker("Protocol", selection: $transport) {
                    ForEach(ProtocolChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Direction", selection: $direction) {
                    Text("Outgoing").tag(DirectionCondition.outgoing)
                    Text("Incoming").tag(DirectionCondition.incoming)
                    Text("Both").tag(DirectionCondition.bidirectional)
                }
                TextField("Port or range", text: $portText, prompt: Text("Any"))
            }

            Section("Scope") {
                Picker("Profile", selection: $profileID) {
                    Text("All profiles").tag(UUID?.none)
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                Picker("Local group", selection: $localGroupID) {
                    Text("No group").tag(UUID?.none)
                    ForEach(groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
            }

            Section("Options") {
                Toggle("Temporary", isOn: $temporary)
                if temporary { DatePicker("Expires", selection: $expiry, in: Date()...) }
                Toggle("Enabled", isOn: $isEnabled)
                Toggle("Reviewed", isOn: $isReviewed)
                TextField("Note", text: $note, axis: .vertical).lineLimit(2...4)
            }

            Section("Impact") {
                RuleImpactPreviewView(
                    preview: preview,
                    hasRetainedSamples: previewEnvironment?.samples.isEmpty == false
                )
            }

            if let validation {
                Text(validation).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Changes apply to new and pending connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: persist)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .onChange(of: process) { _, _ in
            if owner == .system && !selectedIdentityPermitsSystemOwner {
                owner = .authorizedUser
            }
        }
        .onChange(of: action) { _, value in
            if value != .allow { overrideBlocklists = false }
        }
        .onChange(of: previewDraft) { _, draft in schedulePreview(draft) }
        .task { schedulePreview(previewDraft) }
        .onDisappear { previewTask?.cancel() }
        .confirmationDialog(
            "Save Blocklist Exception?",
            isPresented: $showingOverrideConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save Exception") {
                guard let draft = pendingOverrideDraft else { return }
                pendingOverrideDraft = nil
                performSave(draft)
            }
            Button("Cancel", role: .cancel) { pendingOverrideDraft = nil }
        } message: {
            if let draft = pendingOverrideDraft {
                let label = availableIdentities.first { $0.process == draft.process }?.label
                    ?? "Selected application identity"
                Text(ManualRuleOverrideConfirmation.message(
                    draft: draft,
                    applicationLabel: label
                ))
            }
        }
    }

    private func persist() {
        do {
            let draft = try makeDraft()
            validation = nil
            if draft.priority == .elevatedUser {
                pendingOverrideDraft = draft
                showingOverrideConfirmation = true
            } else {
                performSave(draft)
            }
        } catch let error as EditorError {
            validation = error.message
        } catch let error as RuleValidationError {
            switch error {
            case .elevatedPriorityRequiresExactProcess:
                validation = "Choose one specific application or app-and-helper identity."
            case .elevatedPriorityRequiresExactDestination:
                validation = "Choose exact hostnames or an exact IP set for this exception."
            default:
                validation = "Narrow the exception before saving."
            }
        } catch {
            validation = "Enter a valid destination, address range, or domain."
        }
    }

    private func performSave(_ draft: ManualRuleDraft) {
        saving = true
        Task {
            if await save(draft) { dismiss() }
            saving = false
        }
    }

    private var previewDraft: ManualRuleDraft? { try? makeDraft() }

    private func makeDraft() throws -> ManualRuleDraft {
        let destination = try destinationCondition()
        if direction != .outgoing,
           case .domainSet = destination { throw EditorError.incomingDomain }
        if direction != .outgoing,
           case .exactHostnameSet = destination { throw EditorError.incomingDomain }
        let port = try parsePort(portText)
        guard !temporary || expiry > Date() else { throw EditorError.expired }
        guard note.unicodeScalars.count <= PolicyLimits.maximumNotesScalars else {
            throw EditorError.noteTooLong
        }
        guard availableIdentities.contains(where: { $0.process == process }),
              owner != .system || selectedIdentityPermitsSystemOwner else {
            throw EditorError.unavailableIdentity
        }
        let draft = ManualRuleDraft(
            action: action.value,
            priority: action == .allow && overrideBlocklists ? .elevatedUser : .normal,
            process: process,
            destination: destination,
            transport: transport.value,
            port: port,
            direction: direction,
            owner: owner,
            profileID: profileID,
            localGroupID: localGroupID,
            expiresAt: temporary ? expiry : nil,
            isEnabled: isEnabled,
            reviewState: isReviewed ? .reviewed : .unreviewed,
            note: note
        )
        try Rule.validatePriorityScope(
            action: draft.action,
            priority: draft.priority,
            process: draft.process,
            destination: draft.destination
        )
        return draft
    }

    private func schedulePreview(_ draft: ManualRuleDraft?) {
        previewTask?.cancel()
        guard let draft, let previewEnvironment else {
            preview = nil
            return
        }
        let editingID = initial?.id
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let value = await Task.detached(priority: .userInitiated) {
                try? RuleImpactPreviewEvaluator.evaluate(
                    draft: draft,
                    editingRuleID: editingID,
                    environment: previewEnvironment
                )
            }.value
            guard !Task.isCancelled else { return }
            preview = value
        }
    }

    private var availableIdentities: [RuleIdentityChoice] {
        guard let initial,
              !identities.contains(where: { $0.process == initial.process }) else {
            return identities
        }
        return identities + [RuleIdentityChoice(
            process: initial.process,
            permitsSystemOwner: initial.owner == .system
        )]
    }

    private var selectedIdentityPermitsSystemOwner: Bool {
        process != .anyProcess && availableIdentities.contains {
            $0.process == process && $0.permitsSystemOwner
        }
    }

    private var remainingDestinationCapacity: Int {
        let count = destinationText.split(whereSeparator: { $0 == "," || $0 == "\n" }).count
        return max(0, PolicyLimits.maximumDestinationMembers - count)
    }

    private func destinationCondition() throws -> DestinationCondition {
        switch destinationKind {
        case .hostOrAddress:
            if includesChildren, let initial, case .domainSet = initial.destination {
                return initial.destination
            }
            return try DestinationEditorParser.parse(
                destinationText,
                domainsIncludeChildren: false
            )
        case .broadcast: return .endpointClass(.broadcast)
        case .multicast: return .endpointClass(.multicast)
        case .bonjour: return .endpointClass(.bonjour)
        case .localNetwork: return .endpointClass(.localNetwork)
        case .any: return .anyEndpoint
        }
    }

    private func parsePort(_ input: String) throws -> PortRange? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let lower = UInt16(parts[0]),
              let upper = UInt16(parts.count == 2 ? parts[1] : parts[0]) else {
            throw EditorError.port
        }
        return try PortRange(lower, upper)
    }

    private static func destinationText(_ destination: DestinationCondition) -> String {
        switch destination {
        case .ipSet(let values): values.map(\.description).joined(separator: "\n")
        case .exactHostnameSet(let values), .domainSet(let values):
            values.map(\.ascii).joined(separator: "\n")
        case .endpointClass(let value): value.rawValue
        case .anyEndpoint: ""
        }
    }

    private static func destinationKind(_ destination: DestinationCondition) -> DestinationKind {
        switch destination {
        case .ipSet, .exactHostnameSet, .domainSet: .hostOrAddress
        case .endpointClass(.broadcast): .broadcast
        case .endpointClass(.multicast): .multicast
        case .endpointClass(.bonjour): .bonjour
        case .endpointClass(.localNetwork): .localNetwork
        case .endpointClass: .hostOrAddress
        case .anyEndpoint: .any
        }
    }

    private enum EditorError: Error {
        case incomingDomain, expired, noteTooLong, port, unavailableIdentity

        var message: String {
            switch self {
            case .incomingDomain:
                "Hostname and domain matches support outgoing connections only."
            case .expired:
                "Choose an expiry time in the future."
            case .noteTooLong:
                "Shorten the note before saving."
            case .port:
                "Enter one port or an ascending port range."
            case .unavailableIdentity:
                "Choose an available application and owner scope."
            }
        }
    }
}
