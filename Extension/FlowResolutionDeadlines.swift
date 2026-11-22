import RiftCore
import RiftFilterRuntime
import RiftIPC
import Foundation
@preconcurrency import NetworkExtension

/// How a waiting connection ends without an answer: its deadline passes, the
/// policy changes under it, or the filter stops.
extension FlowResolutionCoordinator {
    private static let maximumDeadlineNonceRetries = 8

    /// What a connection that needed an answer and got none receives. The
    /// active policy decides; with no policy there is nothing to enforce, so
    /// it's allowed like every other connection.
    func unansweredAction() -> FilterAction {
        activePolicy.load()?.unansweredAction ?? .allow
    }

    /// How long a connection may wait while the filter works out which app
    /// it belongs to. The wait for an answer is the policy's, set when the
    /// alert is asked for.
    func deadline(for flow: FlowDescriptor) -> Date {
        flow.observedAt.addingTimeInterval(
            flow.transportProtocol == .udp
                ? UnansweredAlertPolicy.legacyUDPWait
                : UnansweredAlertPolicy.legacyTCPWait
        )
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
        let unanswered = unansweredAction()
        for value in values {
            let action: FilterAction = value.awaitingAnswer ? unanswered : .allow
            if value.privacyResolved {
                record(
                    networkFlow: value.flow,
                    metadata: value.metadata,
                    action: action,
                    reason: .promptUnavailableFallback,
                    policy: activePolicy.load()?.tuple,
                    hidden: value.hidden,
                    shouldNotify: value.shouldNotify
                )
            }
            provider.resumeFlow(
                value.flow,
                with: reporting(
                    action == .deny ? .drop() : .allow(),
                    hidden: !value.privacyResolved || value.hidden
                )
            )
        }
    }

    func scheduleDeadline(flowID: UUID, deadline: Date) {
        let interval = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.deadlineReached(flowID: flowID, deadline: deadline)
        }
    }

    private func deadlineReached(flowID: UUID, deadline: Date) {
        // A flow whose deadline moved later has a newer timer. This one must
        // not end it early.
        guard let current = lock.withLock({ pending[flowID]?.deadline }),
              current <= deadline else { return }
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

    /// Ends a wait nobody can finish. A connection that was waiting for an
    /// answer gets the policy's unanswered action. One still waiting for its
    /// app identity is allowed, as it always was.
    func resumeFallback(
        flowID: UUID,
        reason: RuntimeEventReason = .promptUnavailableFallback
    ) {
        guard let value = take(flowID: flowID), let provider else { return }
        let action: FilterAction = value.awaitingAnswer ? unansweredAction() : .allow
        if value.privacyResolved {
            record(
                networkFlow: value.flow,
                metadata: value.metadata,
                action: action,
                reason: reason,
                policy: activePolicy.load()?.tuple,
                hidden: value.hidden,
                shouldNotify: value.shouldNotify
            )
        }
        provider.resumeFlow(
            value.flow,
            with: reporting(
                action == .deny ? .drop() : .allow(),
                hidden: !value.privacyResolved || value.hidden
            )
        )
    }

    func policyChanged(_ policy: RuntimePolicy?) {
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
        }
    }
}
