import RiftCore
import RiftFilterRuntime
import RiftIPC
import Foundation
@preconcurrency import NetworkExtension

final class FlowResolutionCoordinator: @unchecked Sendable {
    private struct Pending {
        let flow: NEFilterFlow
        var metadata: CapturedFlowMetadata
        let deadline: Date
        var cohortID: UUID?
        var privacyResolved: Bool
        var hidden: Bool
        var shouldNotify: Bool
    }
    private struct Cohort {
        let key: PromptCohortKey
        let nonce: UUID
        var flowIDs: Set<UUID>
    }
    private static let maximumPendingFlows = 256
    private static let maximumDeadlineNonceRetries = 8
    private static let tcpDeadline: TimeInterval = 30
    private static let udpDeadline: TimeInterval = 8
    private let lock = NSLock()
    private let resolver = IdentityResolver()
    private let activePolicy: ActivePolicyReference
    private let prompts: PromptQueue
    let events: RuntimeEventRing
    let notifications: EphemeralNotificationQueue
    private let reloads: PolicyReloadSignal
    let liveFlows: LiveFlowTracker
    private weak var provider: NEFilterDataProvider?
    private var pending: [UUID: Pending] = [:]
    private var cohorts: [UUID: Cohort] = [:]
    private var cohortIDsByKey: [PromptCohortKey: UUID] = [:]
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
    func providerStopped() {
        let (values, nonces) = lock.withLock {
            let values = Array(pending.values)
            let nonces = cohorts.values.map(\.nonce)
            pending.removeAll(keepingCapacity: true)
            cohorts.removeAll(keepingCapacity: true)
            cohortIDsByKey.removeAll(keepingCapacity: true)
            return (values, nonces)
        }
        nonces.forEach(prompts.cancel)
        guard let provider else { return }
        for value in values {
            if value.privacyResolved {
                record(
                    networkFlow: value.flow,
                    flow: value.metadata.descriptor,
                    action: .allow,
                    reason: .promptUnavailableFallback,
                    policy: activePolicy.load()?.tuple,
                    hidden: value.hidden,
                    shouldNotify: value.shouldNotify
                )
            }
            provider.resumeFlow(
                value.flow,
                with: reporting(.allow(), hidden: !value.privacyResolved || value.hidden)
            )
        }
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
                flow: metadata.descriptor,
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
        let deadline = deadline(for: metadata.descriptor)
        let registration = register(
            flow: flow,
            metadata: metadata,
            deadline: deadline,
            privacyResolved: true
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
        update(value, flowID: flowID)
        if decision.filter.action == .ask {
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
        guard let completed = take(flowID: flowID) else { return }
        record(
            networkFlow: completed.flow,
            flow: completed.metadata.descriptor,
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

    private func enqueuePrompt(
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
                        affectingRuleIDs: decision.filter.affectingRuleIDs
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
        case .unavailableFallback: (.allow, .promptUnavailableFallback)
        case .deadlineFallback: (.allow, .promptDeadlineFallback)
        }
        let result: NEFilterNewFlowVerdict = action == .deny ? .drop() : .allow()
        for value in values {
            record(
                networkFlow: value.flow,
                flow: value.metadata.descriptor,
                action: action,
                reason: reason,
                policy: activePolicy.load()?.tuple,
                hidden: value.hidden,
                shouldNotify: value.shouldNotify
            )
            provider.resumeFlow(value.flow, with: reporting(result, hidden: value.hidden))
        }
    }

    private func scheduleDeadline(flowID: UUID, deadline: Date) {
        let interval = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.deadlineReached(flowID: flowID, deadline: deadline)
        }
    }

    private func deadlineReached(flowID: UUID, deadline: Date) {
        let now = Date()
        guard now >= deadline else {
            scheduleDeadline(flowID: flowID, deadline: deadline)
            return
        }
        for _ in 0..<Self.maximumDeadlineNonceRetries {
            let nonce = lock.withLock {
                pending[flowID]?.cohortID.flatMap { cohorts[$0]?.nonce }
            }
            guard let nonce else {
                resumeFallback(flowID: flowID, reason: .promptDeadlineFallback)
                return
            }
            if prompts.expire(nonce, now: now) { return }
            let currentNonce = lock.withLock {
                pending[flowID]?.cohortID.flatMap { cohorts[$0]?.nonce }
            }
            if currentNonce == nonce { return }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(10)
        ) { [weak self] in
            self?.deadlineReached(flowID: flowID, deadline: deadline)
        }
    }

    private func resumeFallback(
        flowID: UUID,
        reason: RuntimeEventReason = .promptUnavailableFallback
    ) {
        guard let value = take(flowID: flowID), let provider else { return }
        if value.privacyResolved {
            record(
                networkFlow: value.flow,
                flow: value.metadata.descriptor,
                action: .allow,
                reason: reason,
                policy: activePolicy.load()?.tuple,
                hidden: value.hidden,
                shouldNotify: value.shouldNotify
            )
        }
        provider.resumeFlow(
            value.flow,
            with: reporting(.allow(), hidden: !value.privacyResolved || value.hidden)
        )
    }

    private func register(
        flow: NEFilterFlow,
        metadata: CapturedFlowMetadata,
        deadline: Date,
        privacyResolved: Bool = false
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
                hidden: false,
                shouldNotify: false
            )
            return .admitted
        }
    }

    private func value(flowID: UUID) -> Pending? {
        lock.withLock { pending[flowID] }
    }

    private func update(_ value: Pending, flowID: UUID) {
        lock.withLock {
            guard pending[flowID] != nil else { return }
            pending[flowID] = value
        }
    }

    private func take(flowID: UUID) -> Pending? {
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

    private func policyChanged(_ policy: RuntimePolicy?) {
        let (flowIDs, nonces) = lock.withLock { () -> ([UUID], [UUID]) in
            let nonces = cohorts.values.map(\.nonce)
            cohorts.removeAll(keepingCapacity: true)
            cohortIDsByKey.removeAll(keepingCapacity: true)
            for flowID in pending.keys {
                pending[flowID]?.cohortID = nil
            }
            return (Array(pending.keys), nonces)
        }
        nonces.forEach(prompts.cancel)
        guard let policy, let provider else {
            flowIDs.forEach { resumeFallback(flowID: $0) }
            return
        }
        for flowID in flowIDs {
            guard let value = value(flowID: flowID) else { continue }
            guard value.privacyResolved else { continue }
            guard Date() < value.deadline else {
                resumeFallback(flowID: flowID, reason: .promptDeadlineFallback)
                continue
            }
            let decision = policy.decision(for: value.metadata.descriptor, now: Date())
            if decision.filter.action == .ask {
                if !enqueuePrompt(
                    flowID: flowID,
                    metadata: value.metadata,
                    decision: decision,
                    policy: policy,
                    deadline: value.deadline
                ) {
                    resumeFallback(flowID: flowID, reason: .promptUnavailableFallback)
                }
            } else if let completed = take(flowID: flowID) {
                record(
                    networkFlow: completed.flow,
                    flow: completed.metadata.descriptor,
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
        }
    }

    private func deadline(for flow: FlowDescriptor) -> Date {
        flow.observedAt.addingTimeInterval(
            flow.transportProtocol == .udp ? Self.udpDeadline : Self.tcpDeadline
        )
    }

}
