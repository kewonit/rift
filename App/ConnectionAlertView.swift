import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

struct ConnectionAlertView: View {
    private enum ActiveProfileResolution: Equatable {
        case loading
        case none
        case loaded(PolicyProfile)
        case failed

        var isResolved: Bool {
            switch self {
            case .none, .loaded: true
            case .loading, .failed: false
            }
        }

        var profile: PolicyProfile? {
            guard case .loaded(let profile) = self else { return nil }
            return profile
        }
    }

    enum RuleScope: String, CaseIterable, Identifiable {
        case currentProfile = "Current profile"
        case allProfiles = "All profiles"
        var id: String { rawValue }
    }

    enum Lifetime: String, CaseIterable, Identifiable {
        case once = "Once"
        case oneHour = "One hour"
        case permanent = "Always"

        var id: String { rawValue }
        var duration: TimeInterval? {
            switch self {
            case .once, .permanent: nil
            case .oneHour: 3_600
            }
        }
    }

    private enum DestinationScope: String, CaseIterable, Identifiable {
        case exact = "This destination"
        case any = "Any destination"
        var id: String { rawValue }
    }

    let prompt: PromptRequest
    @Bindable var controller: ControlPlaneController
    let artworkStore: ApplicationArtworkStore
    @AppStorage("alertDefaultLifetime") private var alertDefaultLifetime = Lifetime.once.rawValue
    @AppStorage("alertDefaultScope") private var alertDefaultScope = RuleScope.currentProfile.rawValue
    @State private var lifetime: Lifetime = .once
    @State private var destinationScope: DestinationScope = .exact
    @State private var showingDetails = false
    @State private var note = ""
    @State private var scope: RuleScope = .currentProfile
    @State private var activeProfileResolution: ActiveProfileResolution = .loading
    @State private var systemScopeConfirmed = false
    @State private var resolvedApplicationName: String?
    @State private var decisionMessage: String?
    @State private var decisionInProgress = false
    @State private var pendingDecision: FilterAction?
    @State private var durableRuleSaved = false
    @State private var decisionNeedsAttention = false
    @State private var initialDeadlineInterval: TimeInterval = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ApplicationIdentityIcon(
                    identity: presentationIdentity,
                    fallbackSystemName: "app.dashed",
                    size: 36,
                    artworkStore: artworkStore
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection request")
                        .font(.title2.weight(.semibold))
                    Text("\(applicationName) wants to connect to \(DisplaySanitizer.plainText(destination)).")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: identitySymbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help(identityTitle)
            }

            DisclosureGroup("Details", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        row("Destination", destination)
                        row("Identified by", destinationSource)
                        row("Direction", prompt.direction == .outgoing ? "Outgoing" : "Incoming")
                        row("Protocol", protocolLabel)
                        row("Owner", ownerLabel)
                    }
                    if let appIdentity = prompt.appIdentity {
                        LabeledContent(
                            "Application",
                            value: DisplaySanitizer.plainText(identityEvidence(for: appIdentity))
                        )
                    }
                    if let processIdentity = prompt.processIdentity,
                       processIdentity != prompt.appIdentity {
                        LabeledContent(
                            "Helper process",
                            value: DisplaySanitizer.plainText(identityEvidence(for: processIdentity))
                        )
                    }
                    Text("Rules version \(prompt.generation) • Alert ID \(prompt.nonce.uuidString.lowercased())")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.top, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if prompt.endpoint?.hostname == nil {
                Label(
                    "This connection uses only an IP address, so domain rules and domain blocklists can’t match it.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Picker("Apply this decision", selection: $lifetime) {
                ForEach(Lifetime.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!canCreateDurableRule)

            if requiresSystemScopeConfirmation {
                Toggle("Create a rule for this system process", isOn: $systemScopeConfirmed)
                    .onChange(of: systemScopeConfirmed) { _, confirmed in
                        if !confirmed { lifetime = .once }
                    }
            }

            switch activeProfileResolution {
            case .loading:
                Label("Checking active profile…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                HStack {
                    Label("Couldn’t check the active profile", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Try Again") {
                        Task { @MainActor in await resolveActiveProfile() }
                    }
                    .controlSize(.small)
                }
            case .none, .loaded:
                EmptyView()
            }

            if lifetime != .once {
                Picker("Destination", selection: $destinationScope) {
                    ForEach(DestinationScope.allCases) { Text($0.rawValue).tag($0) }
                }
                if destinationScope == .any {
                    Label(
                        "This rule will apply to all destinations for this app with the same protocol, direction, and owner.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if activeProfileResolution.profile != nil {
                    Picker("Apply to", selection: $scope) {
                        ForEach(RuleScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                if !noteValid {
                    Text("This note is too long.").font(.caption).foregroundStyle(.red)
                }
            }

            if let decisionMessage {
                Label(
                    decisionMessage,
                    systemImage: decisionNeedsAttention
                        ? "exclamationmark.circle" : "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(decisionNeedsAttention ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 10) {
                    if let pendingDecision {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(pendingDecision == .deny ? "Denying…" : "Allowing…")
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 10) {
                        Button("Deny") { decide(.deny) }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .keyboardShortcut("d", modifiers: .command)
                            .frame(maxWidth: .infinity)
                            .controlSize(.large)
                            .disabled(decisionDisabled(at: context.date))
                        Button("Allow") { decide(.allow) }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .keyboardShortcut("a", modifiers: .command)
                            .frame(maxWidth: .infinity)
                            .controlSize(.large)
                            .disabled(decisionDisabled(at: context.date))
                    }
                    VStack(spacing: 4) {
                        ProgressView(
                            value: max(0, prompt.deadline.timeIntervalSince(context.date)),
                            total: max(1, initialDeadlineInterval)
                        )
                        .tint(context.date >= prompt.deadline ? .orange : .secondary)
                        HStack {
                            Text("⌘D Deny  •  ⌘A Allow")
                            Spacer()
                            Text(deadlineLabel(at: context.date))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(context.date >= prompt.deadline ? .orange : .secondary)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .task {
            if alertDefaultLifetime == "Permanent" { alertDefaultLifetime = "Always" }
            initialDeadlineInterval = max(1, prompt.deadline.timeIntervalSinceNow)
            scope = RuleScope(rawValue: alertDefaultScope) ?? .currentProfile
            await resolveActiveProfile()
        }
        .task(id: presentationIdentity) {
            resolvedApplicationName = nil
            guard let presentationIdentity else { return }
            let name = await artworkStore.artwork(
                for: presentationIdentity
            )?.displayName
            guard !Task.isCancelled else { return }
            resolvedApplicationName = name
        }
        .onKeyPress(.escape) {
            PromptPanelController.shared.dismiss()
            return .handled
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(DisplaySanitizer.plainText(value)).textSelection(.enabled)
        }
    }

    private func decide(_ action: FilterAction) {
        let durableScopeConfirmed = !requiresSystemScopeConfirmation || systemScopeConfirmed
        let selected = canCreateDurableRule && durableScopeConfirmed ? lifetime : .once
        guard !decisionInProgress, !durableRuleSaved,
              Date() < prompt.deadline,
              selected == .once || noteValid else { return }
        let selectedProfileID: UUID?
        if selected != .once, scope == .currentProfile {
            guard let profile = activeProfileResolution.profile else {
                lifetime = .once
                decisionMessage = "The active profile changed. Choose where the rule applies, then try again."
                decisionNeedsAttention = true
                return
            }
            selectedProfileID = profile.id
        } else {
            selectedProfileID = nil
        }
        decisionInProgress = true
        pendingDecision = action
        decisionMessage = nil
        decisionNeedsAttention = false
        Task { @MainActor in
            defer {
                decisionInProgress = false
                pendingDecision = nil
            }
            if selected == .once {
                do {
                    try await controller.answerOnce(prompt, action: action)
                } catch {
                    decisionMessage = "Rift couldn’t send your answer. This alert is still open, so you can try again."
                    decisionNeedsAttention = true
                }
            } else {
                do {
                    let result = try await controller.answerWithRule(
                        prompt,
                        action: action,
                        duration: selected.duration,
                        profileID: selectedProfileID,
                        destinationScope: destinationScope == .exact
                            ? .exactObservedEndpoint : .anyEndpoint,
                        allowSystemOwner: systemScopeConfirmed,
                        note: note
                    )
                    durableRuleSaved = true
                    decisionMessage = result.message
                    decisionNeedsAttention = result.requiresAttention
                } catch {
                    decisionMessage = "The rule wasn’t saved. This alert is still open, so you can try again."
                    decisionNeedsAttention = true
                }
            }
        }
    }

    private var noteValid: Bool {
        lifetime == .once || note.unicodeScalars.count <= PolicyLimits.maximumNotesScalars
    }

    private func decisionDisabled(at date: Date) -> Bool {
        !noteValid || date >= prompt.deadline || decisionInProgress || durableRuleSaved
    }

    private func deadlineLabel(at date: Date) -> String {
        let remaining = max(0, Int(prompt.deadline.timeIntervalSince(date).rounded(.up)))
        return remaining == 0
            ? "Timed out — connection allowed"
            : "Allowing in \(remaining)s"
    }

    private var canCreateRule: Bool {
        prompt.endpoint != nil && (prompt.appIdentity != nil || prompt.processIdentity != nil)
    }

    private var canCreateDurableRule: Bool {
        canCreateRule && activeProfileResolution.isResolved
    }

    private var requiresSystemScopeConfirmation: Bool {
        if case .system = prompt.owner { return true }
        return false
    }

    @MainActor
    private func resolveActiveProfile() async {
        activeProfileResolution = .loading
        lifetime = .once
        do {
            let profile = try await controller.policyPresentation().profile
            guard !Task.isCancelled else { return }
            if let profile {
                activeProfileResolution = .loaded(profile)
            } else {
                activeProfileResolution = .none
                scope = .allProfiles
            }
            lifetime = canCreateRule && !requiresSystemScopeConfirmation
                ? (Lifetime(rawValue: alertDefaultLifetime) ?? .once)
                : .once
        } catch {
            guard !Task.isCancelled else { return }
            activeProfileResolution = .failed
            lifetime = .once
        }
    }

    private var applicationName: String {
        let value = resolvedApplicationName ?? MonitorQuery.identityLabel(presentationIdentity)
        let sanitized = DisplaySanitizer.plainText(value)
        return prompt.cohortCount > 1 ? "\(sanitized) (\(prompt.cohortCount) connections)" : sanitized
    }

    private var presentationIdentity: ProcessIdentity? {
        prompt.appIdentity ?? prompt.processIdentity
    }

    private var destination: String {
        guard let endpoint = prompt.endpoint else { return "Unavailable" }
        let host = endpoint.hostname?.ascii ?? endpoint.address.description
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    private var destinationSource: String {
        prompt.endpoint?.hostname == nil ? "IP address" : "Hostname"
    }

    private var protocolLabel: String {
        switch prompt.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .unsupported(let number): "Unsupported (\(number))"
        }
    }

    private var ownerLabel: String {
        switch prompt.owner {
        case .user: "Current user"
        case .system: "System process (affects all users)"
        case .unknown: "Unknown owner"
        }
    }

    private var identityTitle: String {
        switch prompt.appIdentity ?? prompt.processIdentity {
        case .applePlatform: "Apple software"
        case .developerID: "App from an identified developer"
        case .appStore: "Mac App Store app"
        case .otherSigner: "Signed app"
        case .adHoc: "Ad hoc signed app"
        case .unsigned: "Unsigned app"
        case nil: "Unknown app"
        }
    }

    private var identitySymbol: String {
        switch prompt.appIdentity ?? prompt.processIdentity {
        case .applePlatform, .developerID, .appStore: "checkmark.seal"
        case .otherSigner: "signature"
        case .adHoc, .unsigned, nil: "exclamationmark.triangle"
        }
    }

    private var identityEvidence: String {
        guard let identity = prompt.appIdentity ?? prompt.processIdentity else {
            return "Rift couldn’t identify this app, so you can’t create a lasting rule for it."
        }
        return identityEvidence(for: identity)
    }

    private func identityEvidence(for identity: ProcessIdentity) -> String {
        switch identity {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            return "\(value.teamIdentifier ?? "No Team ID") • \(value.signingIdentifier)"
        case .otherSigner(_, let identifier): return identifier
        case .adHoc: return "Identified only by this exact build of the app."
        case .unsigned(let path, _): return path
        }
    }
}
