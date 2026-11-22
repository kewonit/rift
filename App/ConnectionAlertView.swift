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

    let prompt: PromptRequest
    var moreWaiting = 0
    var others: [PromptRequest] = []
    var choose: (UUID) -> Void = { _ in }
    var minimize: (() -> Void)?
    @Bindable var controller: ControlPlaneController
    let artworkStore: ApplicationArtworkStore
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(AlertDefaults.lifetimeKey) private var alertDefaultLifetime = AlertDefaults.lastUsed
    @AppStorage(AlertDefaults.scopeKey) private var alertDefaultScope = RuleScope.currentProfile.rawValue
    @AppStorage(AlertDefaults.destinationKey) private var alertDefaultDestination = AlertDefaults.lastUsed
    @AppStorage(AlertDefaults.lastLifetimeKey) private var alertLastLifetime = ""
    @AppStorage(AlertDefaults.lastDestinationKey) private var alertLastDestination = ""
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
    @State private var presentedAt = Date()
    @State private var answersSameApp = false
    @State private var developerPolicy: InternetAccessPolicy?
    @State private var confirmingBlock = false
    @FocusState private var noteFocused: Bool

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
                    Text(deliberateAllow ? "Check this connection" : "Connection request")
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
                VStack(alignment: .trailing, spacing: RiftDesign.Spacing.xs) {
                    // Once answered, the alert stays put, so it can't be answered again.
                    if let minimize, !decisionInProgress, !durableRuleSaved {
                        Button("Minimize", systemImage: "arrow.down.right.and.arrow.up.left", action: minimize)
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help(ConnectionAlertCountdown.outcome(for: prompt).blocks
                                ? "Minimize. The connection keeps waiting and is blocked when time runs out."
                                : "Minimize. The connection keeps waiting and is allowed when time runs out.")
                    }
                    if others.isEmpty, let waiting = ConnectionAlertPresentation.moreWaitingLabel(moreWaiting) {
                        Text(waiting).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ConnectionAlertWaitingMenu(others: others, choose: choose)
                        .disabled(decisionInProgress || durableRuleSaved)
                }
            }

            ConnectionAlertWarningList(warnings: ConnectionAlertWarnings.warnings(for: prompt))
            ConnectionAlertFirstContact(prompt: prompt, domain: firstContactDomain, controller: controller)

            DisclosureGroup("Details", isExpanded: $showingDetails) {
                ConnectionAlertDetails(prompt: prompt, controller: controller, developer: developerExplanation)
            }

            if prompt.endpoint?.hostname == nil {
                Label(
                    "This connection uses only an IP address, so domain rules and domain blocklists can’t match it.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Picker("Remember", selection: $lifetime) {
                ForEach(Lifetime.allCases) { Text($0.menuTitle).tag($0) }
            }
            .fixedSize()
            .disabled(!lastingChoiceAvailable)
            .help(ConnectionAlertKeys.help)

            if let hint = ConnectionAlertPresentation.lastingChoiceHint(
                hasIdentity: prompt.appIdentity != nil || prompt.processIdentity != nil,
                hasEndpoint: prompt.endpoint != nil
            ) {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }

            if lifetime == .once, !sameAppWaiting.isEmpty {
                let count = sameAppWaiting.count
                Toggle("Also answer \(count) other waiting \(count == 1 ? "connection" : "connections") from this app", isOn: $answersSameApp)
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
                ConnectionAlertRuleOptions(
                    destinationScope: $destinationScope, scope: $scope, note: $note,
                    noteFocused: $noteFocused, choices: destinationChoices,
                    registeredDomain: registeredDomain, showsScope: activeProfileResolution.profile != nil,
                    scopeTitle: scopeTitle, noteValid: noteValid
                )
            }

            if confirmingBlock, !blockConsequences.isEmpty {
                ConnectionAlertBlockConsequences(consequences: blockConsequences)
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
                            Label(confirmingBlock ? "Block Anyway" : blockConsequences.isEmpty ? "Block" : "Block…",
                                  systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(Color(nsColor: .systemRed))
                        .disabled(decisionDisabled(at: context.date))
                        Button { decide(.allow) } label: {
                            Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .tint(Color(nsColor: .systemGreen))
                        .disabled(decisionDisabled(at: context.date))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .background {
                        ConnectionAlertKeys(
                            allow: { decideFromKeyboard(.allow) },
                            block: { decideFromKeyboard(.deny) },
                            returnAllows: !deliberateAllow,
                            noteFocused: noteFocused,
                            lifetime: lastingChoiceAvailable ? $lifetime : nil,
                            toggleDetails: { showingDetails.toggle() }
                        )
                        .disabled(decisionDisabled(at: context.date))
                    }
                    VStack(spacing: RiftDesign.Spacing.xs + 2) {
                        ProgressView(
                            value: max(0, prompt.deadline.timeIntervalSince(context.date)),
                            total: max(1, initialDeadlineInterval)
                        )
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(context.date >= prompt.deadline ? Color(nsColor: .systemOrange) : .secondary)
                        HStack {
                            if controlActiveState == .key {
                                Text(keyHint)
                            }
                            Spacer()
                            Text(deadlineLabel(at: context.date))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(context.date >= prompt.deadline ? Color(nsColor: .systemOrange) : .secondary)
                    }
                    .modifier(ConnectionAlertCountdownElement(prompt: prompt, now: context.date, keys: controlActiveState == .key ? keyHint : nil))
                }
            }
        }
        .padding(RiftDesign.Spacing.xl)
        .frame(width: 520)
        // Its own height, so a taller window can't open gaps between the controls.
        .fixedSize(horizontal: false, vertical: true)
        // A warned alert looks different, so it isn't answered from habit.
        .modifier(ConnectionAlertWarnedTint(warned: deliberateAllow))
        .modifier(ConnectionAlertAnnouncements(prompt: prompt, answered: decisionInProgress || durableRuleSaved, problem: decisionNeedsAttention && !durableRuleSaved ? decisionMessage : nil))
        .task {
            initialDeadlineInterval = max(1, prompt.deadline.timeIntervalSinceNow)
            presentedAt = Date()
            scope = RuleScope(rawValue: alertDefaultScope) ?? .currentProfile
            destinationScope = AlertDefaults.destination(
                preset: alertDefaultDestination,
                lastUsed: alertLastDestination,
                domainAvailable: registeredDomain != nil
            )
            await resolveActiveProfile()
        }
        .task(id: presentationIdentity) {
            resolvedApplicationName = nil
            developerPolicy = nil
            guard let presentationIdentity else { return }
            let name = await artworkStore.artwork(
                for: presentationIdentity
            )?.displayName
            guard !Task.isCancelled else { return }
            resolvedApplicationName = name
            let policy = await DeveloperPolicyStore.shared.policy(for: presentationIdentity, artworkStore: artworkStore)
            guard !Task.isCancelled else { return }
            developerPolicy = policy
        }
        .task(id: prompt.nonce) {
            confirmingBlock = false
            ConnectionAlertSpeech.announceOpening(ConnectionAlertPresentation.headline(
                application: applicationName,
                destination: DisplaySanitizer.plainText(destination),
                direction: prompt.direction
            ), prompt: prompt)
            // The filter resolves the connection at the deadline. If that news
            // never arrives, clear the alert so it can't sit here with no way out.
            let wait = prompt.deadline.timeIntervalSinceNow + 2
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            controller.removePendingPrompt(prompt.nonce)
        }
    }

    /// Keys pressed in the first second are ignored, so typing that was meant
    /// for another window can't answer an alert that just appeared.
    private func decideFromKeyboard(_ action: FilterAction) {
        guard Date().timeIntervalSince(presentedAt) >= 1 else { return }
        decide(action)
    }

    private func decide(_ action: FilterAction) {
        let durableScopeConfirmed = !requiresSystemScopeConfirmation || systemScopeConfirmed
        let selected = canCreateDurableRule && durableScopeConfirmed ? lifetime : .once
        guard !decisionInProgress, !durableRuleSaved,
              Date() < answerDeadline,
              selected == .once || noteValid else { return }
        // When the developer says what blocking breaks, the first Block shows
        // it and the second blocks.
        if action == .deny, !confirmingBlock, !blockConsequences.isEmpty {
            confirmingBlock = true
            return
        }
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
        // While this answer is on its way, Rift doesn't answer Block for it.
        PromptPanelController.shared.answering.insert(prompt.nonce)
        Task { @MainActor in
            defer {
                decisionInProgress = false
                pendingDecision = nil
                if decisionNeedsAttention, !durableRuleSaved {
                    PromptPanelController.shared.answering.remove(prompt.nonce)
                }
            }
            if selected == .once {
                do {
                    try await controller.answerOnce(prompt, action: action)
                    if answersSameApp {
                        for other in sameAppWaiting { try? await controller.answerOnce(other, action: action) }
                    }
                    // Once counts as a choice only when a lasting one was on offer.
                    if lifetime == .once, lastingChoiceAvailable { alertLastLifetime = Lifetime.once.rawValue }
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
                        destinationScope: destinationScope.ruleScope,
                        allowSystemOwner: systemScopeConfirmed,
                        note: note
                    )
                    durableRuleSaved = true
                    rememberLastChoice(selected)
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
                        destination: destinationPhrase(for: destinationScope),
                        port: nil,
                        incoming: prompt.direction == .incoming,
                        lasting: selected.duration.map { _ in selected.rawValue.lowercased() }
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

    /// Feeds the "Last used" presets. An answer to an alert that couldn't
    /// offer a domain leaves the destination preference alone.
    private func rememberLastChoice(_ selected: Lifetime) {
        alertLastLifetime = selected.rawValue
        if AlertDefaults.remembersDestination(destinationScope, domainAvailable: registeredDomain != nil) {
            alertLastDestination = destinationScope.rawValue
        }
    }

    /// What the app's developer says about this connection and the choice
    /// being made, or nil when the app ships no policy.
    private var developerExplanation: DeveloperExplanation? {
        developerPolicy?.explanation(for: InternetAccessPolicyQuery(
            prompt: prompt, choice: policyChoice(lifetime: lifetime, destination: destinationScope)
        ))
    }

    private var blockConsequences: [String] { developerExplanation?.denyConsequences ?? [] }

    /// With a warning showing, Return doesn't allow.
    private var deliberateAllow: Bool { ConnectionAlertWarnings.requiresDeliberateAllow(for: prompt) }

    private var keyHint: String {
        if noteFocused { return "⌘B Block · ⌘A Allow" }
        return deliberateAllow ? "Esc Block · ⌘A Allow" : "Esc Block · Return Allow"
    }

    private var noteValid: Bool {
        lifetime == .once || note.unicodeScalars.count <= PolicyLimits.maximumNotesScalars
    }

    private func decisionDisabled(at date: Date) -> Bool {
        !noteValid || date >= answerDeadline || decisionInProgress || durableRuleSaved
    }

    private func deadlineLabel(at date: Date) -> String {
        ConnectionAlertCountdown.label(for: prompt, now: date)
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
                ? AlertDefaults.lifetime(preset: alertDefaultLifetime, lastUsed: alertLastLifetime)
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

    var currentProfileName: String? { activeProfileResolution.profile?.name }
    private var facts: ConnectionAlertFacts { ConnectionAlertFacts(prompt: prompt) }
    private var destination: String { facts.destination }
    private var identityTitle: String { facts.identityTitle }
    private var identitySymbol: String { facts.identitySymbol }
}
