import AppKit
import RiftControl
import RiftCore
import SwiftUI
import UniformTypeIdentifiers

struct ManualRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let initial: Rule?
    let identities: [RuleIdentityChoice]
    let groups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let previewEnvironment: RulePreviewEnvironment?
    let artworkStore: ApplicationArtworkStore
    let save: (ManualRuleDraft) async -> Bool
    @State private var action: EditorAction = .deny
    @State private var showingAdvanced = false
    @State private var chosenApps: [RuleIdentityChoice] = []
    @State private var chosenNames: [ProcessCondition: String] = [:]
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
        case hostOrAddress = "Specific sites or addresses"
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
        case deny = "Block"
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
        artworkStore: ApplicationArtworkStore,
        save: @escaping (ManualRuleDraft) async -> Bool
    ) {
        self.initial = initial
        self.identities = identities
        self.groups = groups
        self.profiles = profiles
        self.previewEnvironment = previewEnvironment
        self.artworkStore = artworkStore
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
            Section {
                Picker("Action", selection: $action) {
                    ForEach(EditorAction.allCases) { Text($0.rawValue).tag($0) }
                }
                if action == .hide {
                    Text("Matching connections won’t appear on the Map or in history. Past records stay.")
                        .foregroundStyle(.orange)
                }
                if action == .notify {
                    Text("Rift notifies you when this rule matches, up to a limit. It doesn’t change filtering.")
                        .foregroundStyle(.secondary)
                }
                if action == .allow {
                    Toggle("Allow even if a blocklist blocks it", isOn: $overrideBlocklists)
                }
                HStack {
                    Picker("App", selection: $process) {
                        ForEach(availableIdentities) { choice in
                            Text(displayName(choice)).tag(choice.process)
                        }
                    }
                    Button("Choose App…", action: chooseApp)
                }
                Picker("Destination", selection: $destinationKind) {
                    ForEach(visibleDestinationKinds) { Text($0.rawValue).tag($0) }
                }
                if destinationKind == .hostOrAddress {
                    TextField(
                        "Sites or IP addresses",
                        text: $destinationText,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .disabled(includesChildren)
                    Text(includesChildren
                        ? "This rule also matches subdomains, so these entries can’t be edited here."
                        : "Separate entries with commas or new lines. Sites match exactly and don’t include subdomains.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RuleEditorAdvancedSection(
                isExpanded: $showingAdvanced,
                owner: $owner,
                transport: $transport,
                direction: $direction,
                portText: $portText,
                profileID: $profileID,
                localGroupID: $localGroupID,
                temporary: $temporary,
                expiry: $expiry,
                isEnabled: $isEnabled,
                isReviewed: $isReviewed,
                note: $note,
                permitsSystemOwner: selectedIdentityPermitsSystemOwner,
                profiles: profiles,
                groups: groups
            )

            Section("Preview") {
                RuleImpactPreviewView(
                    preview: preview,
                    hasRetainedSamples: previewEnvironment?.samples.isEmpty == false
                )
            }

        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let validation {
                    Text(validation)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Changes apply to new connections and ones waiting for a decision.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            "Save blocklist exception?",
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
                    ?? "Selected app"
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
                validation = "Choose a specific app for a blocklist exception."
            case .elevatedPriorityRequiresExactDestination:
                validation = "Enter exact hostnames or IP addresses for a blocklist exception."
            default:
                validation = "Make the exception more specific, then save."
            }
        } catch DestinationEditorError.mixedTypes {
            validation = "Use either hostnames or IP addresses in one rule, not both."
        } catch DestinationEditorError.overLimit {
            validation = "There are too many entries. Split them into more than one rule."
        } catch {
            validation = "Enter a valid hostname, IP address, or IP range."
        }
    }

    private func performSave(_ draft: ManualRuleDraft) {
        saving = true
        Task {
            if await save(draft) {
                dismiss()
            } else {
                validation = "The rule wasn’t saved. Your rules may have changed, so check it and try again."
            }
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
        let known = identities + chosenApps
        guard let initial,
              !known.contains(where: { $0.process == initial.process }) else {
            return known
        }
        return known + [RuleIdentityChoice(
            process: initial.process,
            permitsSystemOwner: initial.owner == .system
        )]
    }

    /// Rare destinations stay out of the list until they're needed.
    private var visibleDestinationKinds: [DestinationKind] {
        DestinationKind.allCases.filter { kind in
            showingAdvanced || kind == destinationKind
                || kind == .hostOrAddress || kind == .localNetwork || kind == .any
        }
    }

    private func displayName(_ choice: RuleIdentityChoice) -> String {
        if let name = chosenNames[choice.process] { return name }
        if case .exact(let identity) = choice.process,
           let name = artworkStore.cachedArtworkIfAvailable(for: identity)?.displayName {
            return name
        }
        return choice.label
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let identity = try? await Task.detached(priority: .userInitiated) {
                try StaticCodeIdentityResolver.identity(at: url)
            }.value
            guard let identity else {
                validation = "Rift couldn’t verify that app, so it can’t make a rule for it."
                return
            }
            let condition = ProcessCondition.exact(identity)
            if !availableIdentities.contains(where: { $0.process == condition }) {
                chosenApps.append(RuleIdentityChoice(process: condition, permitsSystemOwner: false))
            }
            chosenNames[condition] = url.deletingPathExtension().lastPathComponent
            process = condition
            validation = nil
        }
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
                "Hostname rules work only for outgoing connections."
            case .expired:
                "Choose an expiration time in the future."
            case .noteTooLong:
                "This note is too long."
            case .port:
                "Enter a port, like 443, or a range, like 8000-8080."
            case .unavailableIdentity:
                "Choose an available app and owner."
            }
        }
    }
}
