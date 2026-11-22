import RiftCore
import RiftFilterRuntime
import RiftIPC
import Foundation
@preconcurrency import NetworkExtension

final class FlowResolutionCoordinator: @unchecked Sendable {
    struct Pending {
        let flow: NEFilterFlow
        var metadata: CapturedFlowMetadata
        var deadline: Date
        var cohortID: UUID?
        var privacyResolved: Bool
        /// The decision was Ask, so the connection is waiting for an answer.
        var awaitingAnswer: Bool
        var hidden: Bool
        var shouldNotify: Bool
    }
    struct Cohort {
        let key: PromptCohortKey
        let nonce: UUID
        var flowIDs: Set<UUID>
    }
    private static let maximumPendingFlows = 256
    let lock = NSLock()
    let resolver = IdentityResolver()
    let activePolicy: ActivePolicyReference
    let prompts: PromptQueue
    let events: RuntimeEventRing
    let notifications: EphemeralNotificationQueue
    private let reloads: PolicyReloadSignal
    let liveFlows: LiveFlowTracker
    weak var provider: NEFilterDataProvider?
    var pending: [UUID: Pending] = [:]
    var cohorts: [UUID: Cohort] = [:]
    var cohortIDsByKey: [PromptCohortKey: UUID] = [:]
    private var reloadObserverID: UUID?

    init(
        provider: NEFilterDataProvider,
        activePolicy: ActivePolicyReference,
        prompts: PromptQueue,
        events: RuntimeEventRing,
        notifications: EphemeralNotificationQueue,
        reloads: PolicyReloadSignal,
        liveFlows: LiveFlowTracker
    ) {
        self.provider = provider
        self.activePolicy = activePolicy
        self.prompts = prompts
        self.events = events
        self.notifications = notifications
        self.reloads = reloads
        self.liveFlows = liveFlows
        reloadObserverID = reloads.install { [weak self] policy in
            self?.policyChanged(policy)
        }
    }

    deinit {
        if let reloadObserverID {
            reloads.remove(reloadObserverID)
        }
    }
    func providerStarted() {
        resolver.clear()
    }

    func verdict(
        for flow: NEFilterFlow,
        metadata captured: CapturedFlowMetadata,
        policy: RuntimePolicy
    ) -> NEFilterNewFlowVerdict {
        if let resolved = resolver.cachedPair(
            app: captured.sourceAppAuditToken,
            process: captured.sourceProcessAuditToken,
            now: captured.descriptor.observedAt
        ) {
            let metadata = captured.withIdentities(resolved)
            let decision = policy.decision(for: metadata.descriptor, now: metadata.descriptor.observedAt)
            return immediateOrPrompt(flow: flow, metadata: metadata, decision: decision, policy: policy)
        }
        guard captured.sourceAppAuditToken != nil || captured.sourceProcessAuditToken != nil else {
            let decision = policy.decision(for: captured.descriptor, now: captured.descriptor.observedAt)
            return immediateOrPrompt(flow: flow, metadata: captured, decision: decision, policy: policy)
        }
        let deadline = deadline(for: captured.descriptor)
        guard register(flow: flow, metadata: captured, deadline: deadline) == .admitted else {
            return unresolvedIdentityAdmissionFallback(
                networkFlow: flow,
                metadata: captured,
                policy: policy
            )
        }
        resolver.resolve(
            app: captured.sourceAppAuditToken,
            process: captured.sourceProcessAuditToken,
            deadline: deadline
        ) { [weak self] identities in
            self?.identityCompleted(flowID: captured.descriptor.flowID, identities: identities)
        }
        scheduleDeadline(flowID: captured.descriptor.flowID, deadline: deadline)
        return .pause()
    }
    private func immediateOrPrompt(
        flow: NEFilterFlow,
        metadata: CapturedFlowMetadata,
        decision: Decision,
        policy: RuntimePolicy
    ) -> NEFilterNewFlowVerdict {
        guard decision.filter.action == .ask else {
            record(
                networkFlow: flow,
                metadata: metadata,
                action: decision.filter.action,
                reason: decision.filter.winningRuleID == nil
                    ? .unmatchedModeFallback : .concreteDecision,
                policy: policy.tuple,
                hidden: decision.privacy.action == .hidden,
                decision: decision.filter,
                shouldNotify: decision.notification.action == .notify
            )
            return verdict(decision)
        }
        let deadline = policy.promptDeadline(
            for: metadata.descriptor,
            askedAt: metadata.descriptor.observedAt
        )
        let registration = register(
            flow: flow,
            metadata: metadata,
            deadline: deadline,
            privacyResolved: true,
            awaitingAnswer: true
        )
        guard registration == .admitted else {
            return resolvedPromptFallback(
                networkFlow: flow,
                metadata: metadata,
                decision: decision,
                policy: policy
            )
        }
        guard enqueuePrompt(
            flowID: metadata.descriptor.flowID,
            metadata: metadata,
            decision: decision,
            policy: policy,
            deadline: deadline
        ) else {
            _ = take(flowID: metadata.descriptor.flowID)
            return resolvedPromptFallback(
                networkFlow: flow,
                metadata: metadata,
                decision: decision,
                policy: policy
            )
        }
        scheduleDeadline(flowID: metadata.descriptor.flowID, deadline: deadline)
        return .pause()
    }

    private func identityCompleted(flowID: UUID, identities: ResolvedIdentityPair) {
        guard var value = value(flowID: flowID), let provider else { return }
        if identities.resolutionFailed {
            guard let policy = activePolicy.load() else {
                resumeFallback(flowID: flowID, reason: .promptDeadlineFallback)
                return
            }
            guard let completed = take(flowID: flowID) else { return }
            provider.resumeFlow(
                completed.flow,
                with: unresolvedIdentityAdmissionFallback(
                    networkFlow: completed.flow,
                    metadata: completed.metadata.withIdentities(identities),
                    policy: policy,
                    identityResolutionFailed: true
                )
            )
            return
        }
        guard Date() < value.deadline, let policy = activePolicy.load() else {
            resumeFallback(flowID: flowID, reason: .promptDeadlineFallback)
            return
        }
        value.metadata = value.metadata.withIdentities(identities)
        value.privacyResolved = true
        let decision = policy.decision(for: value.metadata.descriptor, now: Date())
        value.hidden = decision.privacy.action == .hidden
        value.shouldNotify = decision.notification.action == .notify
        if decision.filter.action == .ask {
            // The wait for an answer starts now that there's an alert to
            // show. The timer set for the identity check ignores a flow whose
            // deadline moved later, so a moved deadline gets its own.
            value.awaitingAnswer = true
            let identityDeadline = value.deadline
            value.deadline = policy.promptDeadline(for: value.metadata.descriptor, askedAt: Date())
            update(value, flowID: flowID)
            if value.deadline != identityDeadline {
                scheduleDeadline(flowID: flowID, deadline: value.deadline)
            }
            if !enqueuePrompt(
                flowID: flowID,
                metadata: value.metadata,
                decision: decision,
                policy: policy,
                deadline: value.deadline
            ) {
                resumeFallback(flowID: flowID, reason: .promptUnavailableFallback)
            }
            return
        }
        update(value, flowID: flowID)
        guard let completed = take(flowID: flowID) else { return }
        record(
            networkFlow: completed.flow,
            metadata: completed.metadata,
            action: decision.filter.action,
            reason: decision.filter.winningRuleID == nil
                ? .unmatchedModeFallback : .concreteDecision,
            policy: policy.tuple,
            hidden: decision.privacy.action == .hidden,
            decision: decision.filter,
            shouldNotify: decision.notification.action == .notify
        )
        provider.resumeFlow(completed.flow, with: verdict(decision))
    }

    func enqueuePrompt(
        flowID: UUID,
        metadata: CapturedFlowMetadata,
        decision: Decision,
        policy: RuntimePolicy,
        deadline: Date
    ) -> Bool {
        do {
            let displayFlow = decision.privacy.action == .hidden
                ? metadata.descriptor.redactedForPrivacy()
                : metadata.descriptor
            let key = PromptCohortKey(
                lineageID: policy.payload.lineageID,
                generation: policy.payload.generation,
                flow: metadata.descriptor
            )
            return try lock.withLock {
                guard var value = pending[flowID] else { return false }
                value.hidden = decision.privacy.action == .hidden
                value.shouldNotify = decision.notification.action == .notify
                if let cohortID = cohortIDsByKey[key], var cohort = cohorts[cohortID] {
                    guard prompts.updateCohort(
                        cohort.nonce,
                        deadline: deadline,
                        count: UInt16(cohort.flowIDs.count + 1)
                    ) else { return false }
                    cohort.flowIDs.insert(flowID)
                    cohorts[cohortID] = cohort
                    value.cohortID = cohortID
                    pending[flowID] = value
                    return true
                }
                let cohortID = UUID()
                let nonce = try prompts.enqueue(
                    PromptSeed(
                        lineageID: policy.payload.lineageID,
                        generation: policy.payload.generation,
                        flow: displayFlow,
                        winningRuleID: decision.filter.winningRuleID,
                        affectingRuleIDs: decision.filter.affectingRuleIDs,
                        unansweredAction: policy.unansweredAction,
                        processes: decision.privacy.action == .hidden
                            ? nil : metadata.processDetails()
                    ),
                    deadline: deadline
                ) { [weak self] resolution in
                    self?.resolve(cohortID: cohortID, resolution: resolution)
                }
                cohorts[cohortID] = Cohort(key: key, nonce: nonce, flowIDs: [flowID])
                cohortIDsByKey[key] = cohortID
                value.cohortID = cohortID
                value.hidden = decision.privacy.action == .hidden
                value.shouldNotify = decision.notification.action == .notify
                pending[flowID] = value
                return true
            }
        } catch {
            return false
        }
    }

    private func resolve(cohortID: UUID, resolution: PromptResolution) {
        let values = lock.withLock { () -> [Pending] in
            guard let cohort = cohorts.removeValue(forKey: cohortID) else { return [] }
            cohortIDsByKey.removeValue(forKey: cohort.key)
            return cohort.flowIDs.compactMap { pending.removeValue(forKey: $0) }
        }
        guard let provider else { return }
        let (action, reason): (FilterAction, RuntimeEventReason) = switch resolution {
        case .answered(let action): (action, .concreteDecision)
        case .unavailableFallback: (unansweredAction(), .promptUnavailableFallback)
        case .deadlineFallback: (unansweredAction(), .promptDeadlineFallback)
        }
        let result: NEFilterNewFlowVerdict = action == .deny ? .drop() : .allow()
        for value in values {
            record(
                networkFlow: value.flow,
                metadata: value.metadata,
                action: action,
                reason: reason,
                policy: activePolicy.load()?.tuple,
                hidden: value.hidden,
                shouldNotify: value.shouldNotify
            )
            provider.resumeFlow(value.flow, with: reporting(result, hidden: value.hidden))
        }
    }

    func register(
        flow: NEFilterFlow,
        metadata: CapturedFlowMetadata,
        deadline: Date,
        privacyResolved: Bool = false,
        awaitingAnswer: Bool = false
    ) -> PendingFlowAdmissionResult {
        lock.withLock {
            let result = PendingFlowAdmissionPolicy.classify(
                currentCount: pending.count,
                containsFlowID: pending[metadata.descriptor.flowID] != nil,
                capacity: Self.maximumPendingFlows
            )
            guard result == .admitted else { return result }
            pending[metadata.descriptor.flowID] = Pending(
                flow: flow,
                metadata: metadata,
                deadline: deadline,
                cohortID: nil,
                privacyResolved: privacyResolved,
                awaitingAnswer: awaitingAnswer,
                hidden: false,
                shouldNotify: false
            )
            return .admitted
        }
    }

    func value(flowID: UUID) -> Pending? {
        lock.withLock { pending[flowID] }
    }

    private func update(_ value: Pending, flowID: UUID) {
        lock.withLock {
            guard pending[flowID] != nil else { return }
            pending[flowID] = value
        }
    }

    func take(flowID: UUID) -> Pending? {
        let result = lock.withLock { () -> (Pending?, UUID?) in
            guard let value = pending.removeValue(forKey: flowID) else { return (nil, nil) }
            guard let cohortID = value.cohortID, var cohort = cohorts[cohortID] else {
                return (value, nil)
            }
            cohort.flowIDs.remove(flowID)
            if cohort.flowIDs.isEmpty {
                cohorts.removeValue(forKey: cohortID)
                cohortIDsByKey.removeValue(forKey: cohort.key)
                return (value, cohort.nonce)
            }
            cohorts[cohortID] = cohort
            return (value, nil)
        }
        result.1.map(prompts.cancel)
        return result.0
    }
}
