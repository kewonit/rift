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
    var moreWaiting = 0
    @Bindable var controller: ControlPlaneController
    let artworkStore: ApplicationArtworkStore
    @Environment(\.controlActiveState) private var controlActiveState
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
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.l) {
            HStack(alignment: .top, spacing: RiftDesign.Spacing.m) {
                ApplicationIdentityIcon(
                    identity: presentationIdentity,
                    fallbackSystemName: "app.dashed",
                    size: 36,
                    artworkStore: artworkStore
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection request")
                        .font(.title2.weight(.semibold))
                    Text(ConnectionAlertPresentation.headline(
                        application: applicationName,
                        destination: DisplaySanitizer.plainText(destination),
                        direction: prompt.direction
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Label(identityTitle, systemImage: identitySymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Spacer()
                if let waiting = ConnectionAlertPresentation.moreWaitingLabel(moreWaiting) {
                    Text(waiting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            DisclosureGroup("Details", isExpanded: $showingDetails) {
                ConnectionAlertDetails(prompt: prompt)
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
            .disabled(!lastingChoiceAvailable)

            if let hint = ConnectionAlertPresentation.lastingChoiceHint(
                hasIdentity: prompt.appIdentity != nil || prompt.processIdentity != nil,
                hasEndpoint: prompt.endpoint != nil
            ) {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }

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
                if destinationScope == .exact {
                    Text("Applies to this destination on this port, for the same protocol and direction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            Text(pendingDecision == .deny ? "Blocking…" : "Allowing…")
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // The width goes on the label so each bezel fills its half.
                    HStack(spacing: RiftDesign.Spacing.m) {
                        Button { decide(.deny) } label: {
                            Label("Block", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .tint(Color(nsColor: .systemRed))
                        .keyboardShortcut("b", modifiers: .command)
                        .disabled(decisionDisabled(at: context.date))
                        Button { decide(.allow) } label: {
                            Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .tint(Color(nsColor: .systemGreen))
                        .keyboardShortcut("a", modifiers: .command)
                        .disabled(decisionDisabled(at: context.date))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    VStack(spacing: RiftDesign.Spacing.xs + 2) {
                        ProgressView(
                            value: max(0, prompt.deadline.timeIntervalSince(context.date)),
                            total: max(1, initialDeadlineInterval)
                        )
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(context.date >= prompt.deadline ? Color(nsColor: .systemOrange) : .secondary)
                        HStack {
                            if controlActiveState == .key { Text("⌘B Block · ⌘A Allow") }
                            Spacer()
                            Text(deadlineLabel(at: context.date))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(context.date >= prompt.deadline ? Color(nsColor: .systemOrange) : .secondary)
                    }
                }
            }
        }
        .padding(RiftDesign.Spacing.xl)
        .frame(width: 520)
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
        .task(id: prompt.nonce) {
            // The filter resolves the connection at the deadline. If that news
            // never arrives, clear the alert so it can't sit here with no way out.
            let wait = prompt.deadline.timeIntervalSinceNow + 2
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            controller.removePendingPrompt(prompt.nonce)
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
                    // The rule may not reach the filter before the deadline.
                    // Answering this connection too means your choice still
                    // applies to it.
                    if result.requiresAttention {
                        try? await controller.answerOnce(prompt, action: action)
                    }
                    let sentence = RulePlainLanguage.change(
                        action: action,
                        application: applicationName,
                        destination: destinationScope == .any
                            ? "any destination" : DisplaySanitizer.plainText(destination),
                        port: nil,
                        incoming: prompt.direction == .incoming
                    )
                    controller.actionResults.post(
                        result.requiresAttention ? "\(sentence) \(result.message)" : sentence,
                        tone: result.requiresAttention ? .pending : .success,
                        ruleIDs: controller.ruleChanges.plan?.affectedRuleIDs ?? [],
                        offersUndo: true
                    )
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
        guard remaining > 0 else { return "Timed out — connection allowed" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return minutes > 0
            ? "Allowing in \(minutes):\(String(format: "%02d", seconds))"
            : "Allowing in \(seconds)s"
    }

    private var canCreateRule: Bool {
        prompt.endpoint != nil && (prompt.appIdentity != nil || prompt.processIdentity != nil)
    }

    private var canCreateDurableRule: Bool {
        canCreateRule && activeProfileResolution.isResolved
    }

    private var lastingChoiceAvailable: Bool {
        ConnectionAlertPresentation.allowsLastingChoice(
            canCreateRule: canCreateDurableRule,
            needsSystemConfirmation: requiresSystemScopeConfirmation,
            systemConfirmed: systemScopeConfirmed
        )
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

    private var facts: ConnectionAlertFacts { ConnectionAlertFacts(prompt: prompt) }
    private var destination: String { facts.destination }
    private var identityTitle: String { facts.identityTitle }
    private var identitySymbol: String { facts.identitySymbol }
}
