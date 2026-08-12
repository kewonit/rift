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
        case permanent = "Permanent"

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
    @State private var keyboardArmed = false
    @State private var note = ""
    @State private var scope: RuleScope = .currentProfile
    @State private var activeProfileResolution: ActiveProfileResolution = .loading
    @State private var systemScopeConfirmed = false
    @State private var resolvedApplicationName: String?
    @State private var decisionMessage: String?
    @State private var decisionInProgress = false
    @State private var durableRuleSaved = false
    @State private var decisionNeedsAttention = false

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
                    Text(DisplaySanitizer.plainText(resolvedApplicationName ?? identityTitle))
                        .font(.title2.weight(.semibold))
                    Text(DisplaySanitizer.plainText(alertSubtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: identitySymbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help(identityTitle)
            }

            GroupBox("Connection") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    row("Destination", destination)
                    row("Source", destinationSource)
                    row("Direction", prompt.direction == .outgoing ? "Outgoing" : "Incoming")
                    row("Protocol", protocolLabel)
                    row("Owner", ownerLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if prompt.endpoint?.hostname == nil {
                Label(
                    "This is an IP-only connection. Domain rules and domain blocklists cannot decide it.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Picker("Remember", selection: $lifetime) {
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
                    Label("Profile status unavailable", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") {
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
                        "This rule will apply to every destination for this app, protocol, direction, and owner.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if activeProfileResolution.profile != nil {
                    Picker("Scope", selection: $scope) {
                        ForEach(RuleScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                if !noteValid {
                    Text("The note is too long.").font(.caption).foregroundStyle(.red)
                }
            }

            DisclosureGroup("Technical details", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    if let appIdentity = prompt.appIdentity {
                        LabeledContent(
                            "Application",
                            value: DisplaySanitizer.plainText(identityEvidence(for: appIdentity))
                        )
                    }
                    if let processIdentity = prompt.processIdentity,
                       processIdentity != prompt.appIdentity {
                        LabeledContent(
                            "Helper",
                            value: DisplaySanitizer.plainText(identityEvidence(for: processIdentity))
                        )
                    }
                    Text("Policy generation \(prompt.generation) • prompt \(prompt.nonce.uuidString.lowercased())")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.top, 5)
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
                HStack {
                    Button("Deny") { decide(.deny) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(
                            !noteValid || context.date >= prompt.deadline
                                || decisionInProgress || durableRuleSaved
                        )
                    Button("Allow") { decide(.allow) }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !noteValid || context.date >= prompt.deadline
                                || decisionInProgress || durableRuleSaved
                        )
                    Spacer()
                    Text(deadlineLabel(at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(context.date >= prompt.deadline ? .orange : .secondary)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .task {
            scope = RuleScope(rawValue: alertDefaultScope) ?? .currentProfile
            await resolveActiveProfile()
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            keyboardArmed = true
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
        .onKeyPress(.return) {
            guard keyboardArmed, Date() < prompt.deadline else { return .ignored }
            decide(.allow)
            return .handled
        }
        .onKeyPress(.escape) {
            guard keyboardArmed else { return .ignored }
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
                decisionMessage = "The active profile changed. Choose the rule scope again."
                decisionNeedsAttention = true
                return
            }
            selectedProfileID = profile.id
        } else {
            selectedProfileID = nil
        }
        decisionInProgress = true
        decisionMessage = nil
        decisionNeedsAttention = false
        Task { @MainActor in
            defer { decisionInProgress = false }
            if selected == .once {
                do {
                    try await controller.answerOnce(prompt, action: action)
                } catch {
                    decisionMessage = "The answer could not be delivered. This prompt remains open."
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
                    decisionMessage = "The rule was not saved. Rift did not dismiss this prompt."
                    decisionNeedsAttention = true
                }
            }
        }
    }

    private var noteValid: Bool {
        lifetime == .once || note.unicodeScalars.count <= PolicyLimits.maximumNotesScalars
    }

    private func deadlineLabel(at date: Date) -> String {
        let remaining = max(0, Int(prompt.deadline.timeIntervalSince(date).rounded(.up)))
        return remaining == 0
            ? "Timed out — allow fallback used"
            : "\(remaining)s until allow fallback"
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

    private var alertSubtitle: String {
        guard prompt.cohortCount > 1 else { return identityEvidence }
        return "\(identityEvidence) • \(prompt.cohortCount) connections"
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
        prompt.endpoint?.hostname == nil ? "Socket address" : "Observed hostname"
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
        case .system: "System process — broader scope warning"
        case .unknown: "Unknown owner"
        }
    }

    private var identityTitle: String {
        switch prompt.appIdentity ?? prompt.processIdentity {
        case .applePlatform: "Apple platform process"
        case .developerID: "Developer ID application"
        case .appStore: "Mac App Store application"
        case .otherSigner: "Signed application"
        case .adHoc: "Ad-hoc signed application"
        case .unsigned: "Unsigned application"
        case nil: "Unknown application"
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
            return "No stable signing identity was available. Permanent rules are disabled."
        }
        return identityEvidence(for: identity)
    }

    private func identityEvidence(for identity: ProcessIdentity) -> String {
        switch identity {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            return "\(value.teamIdentifier ?? "No Team ID") • \(value.signingIdentifier)"
        case .otherSigner(_, let identifier): return identifier
        case .adHoc: return "Identity is tied to this code directory hash."
        case .unsigned(let path, _): return path
        }
    }
}
