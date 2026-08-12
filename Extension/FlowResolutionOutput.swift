import AbyssCore
import AbyssFilterRuntime
import AbyssIPC
import Foundation
@preconcurrency import NetworkExtension

extension FlowResolutionCoordinator {
    func unresolvedIdentityAdmissionFallback(
        networkFlow: NEFilterFlow,
        metadata: CapturedFlowMetadata,
        policy: RuntimePolicy,
        identityResolutionFailed: Bool = false
    ) -> NEFilterNewFlowVerdict {
        let decision = policy.decision(
            for: metadata.descriptor,
            now: metadata.descriptor.observedAt
        )
        let fallback = IdentityResolutionAdmissionPolicy.fallback(
            for: decision,
            identityResolutionFailed: identityResolutionFailed
        )
        if fallback.permitsMetadataRecord {
            record(
                networkFlow: networkFlow,
                flow: metadata.descriptor,
                action: fallback.action,
                reason: fallback.reason,
                policy: policy.tuple,
                hidden: false,
                decision: decision.filter,
                shouldNotify: decision.notification.action == .notify
            )
        }
        let verdict: NEFilterNewFlowVerdict = fallback.action == .deny ? .drop() : .allow()
        return reporting(verdict, hidden: !fallback.shouldReport)
    }

    func resolvedPromptFallback(
        networkFlow: NEFilterFlow,
        metadata: CapturedFlowMetadata,
        decision: Decision,
        policy: RuntimePolicy
    ) -> NEFilterNewFlowVerdict {
        record(
            networkFlow: networkFlow,
            flow: metadata.descriptor,
            action: .allow,
            reason: .promptUnavailableFallback,
            policy: policy.tuple,
            hidden: decision.privacy.action == .hidden,
            decision: decision.filter,
            shouldNotify: decision.notification.action == .notify
        )
        return reporting(.allow(), hidden: decision.privacy.action == .hidden)
    }

    func verdict(_ decision: Decision) -> NEFilterNewFlowVerdict {
        let result: NEFilterNewFlowVerdict
        switch decision.filter.action {
        case .allow, .ask: result = .allow()
        case .deny: result = .drop()
        }
        return reporting(result, hidden: decision.privacy.action == .hidden)
    }

    func reporting(_ verdict: NEFilterNewFlowVerdict, hidden: Bool) -> NEFilterNewFlowVerdict {
        verdict.shouldReport = !hidden
        return verdict
    }

    func record(
        networkFlow: NEFilterFlow,
        flow: FlowDescriptor,
        action: FilterAction,
        reason: RuntimeEventReason,
        policy: PolicyTuple?,
        hidden: Bool,
        decision: CategoryDecision<FilterAction>? = nil,
        shouldNotify: Bool = false
    ) {
        if shouldNotify {
            notifications.append(EphemeralNotificationEvent(
                occurredAt: Date(),
                flow: flow,
                action: action,
                reason: reason
            ))
        }
        guard !hidden else { return }
        let seed = RuntimeEventSeed(
            occurredAt: Date(),
            flow: flow,
            action: action,
            reason: reason,
            policy: policy,
            winningRuleID: decision?.winningRuleID,
            affectingRuleIDs: decision?.affectingRuleIDs ?? [],
            explanation: decision?.explanation.map {
                [$0.priority.rawValue, $0.destination, $0.port, $0.transportProtocol,
                 $0.process, $0.owner, $0.direction, $0.action].joined(separator: " • ")
            },
            notificationRequested: shouldNotify
        )
        events.append(seed)
        liveFlows.retain(networkFlow, decision: seed)
    }
}
