import RiftCore
import RiftFilterRuntime
import Foundation
@preconcurrency import NetworkExtension

/// Flows the interactive policy can't handle: before login, while another
/// account is at the console, or another account's or an unknown owner's flow.
/// Nobody can answer an alert, and these flows stay out of reports.
extension FlowResolutionCoordinator {
    func restrictedVerdict(
        for flow: NEFilterFlow,
        metadata captured: CapturedFlowMetadata,
        policy: RuntimePolicy
    ) -> NEFilterNewFlowVerdict {
        // App rules can only match the authorized account's and root's flows,
        // so only those wait for their app identity, as they do at the console.
        guard ConsoleSessionPolicy.appliesAccountPolicy(
            to: captured.descriptor.owner,
            authorizedUID: policy.payload.authorizedUID
        ), captured.sourceAppAuditToken != nil || captured.sourceProcessAuditToken != nil else {
            return restrictedVerdict(captured.descriptor, policy: policy, now: captured.descriptor.observedAt)
        }
        if let resolved = resolver.cachedPair(
            app: captured.sourceAppAuditToken,
            process: captured.sourceProcessAuditToken,
            now: captured.descriptor.observedAt
        ) {
            let descriptor = captured.withIdentities(resolved).descriptor
            return restrictedVerdict(descriptor, policy: policy, now: descriptor.observedAt)
        }
        let deadline = deadline(for: captured.descriptor)
        guard register(flow: flow, metadata: captured, deadline: deadline) == .admitted else {
            return restrictedVerdict(captured.descriptor, policy: policy, now: captured.descriptor.observedAt)
        }
        let flowID = captured.descriptor.flowID
        resolver.resolve(
            app: captured.sourceAppAuditToken,
            process: captured.sourceProcessAuditToken,
            deadline: deadline
        ) { [weak self] identities in
            self?.restrictedIdentityCompleted(flowID: flowID, identities: identities)
        }
        // A flow still waiting at its deadline is allowed, as at the console.
        scheduleDeadline(flowID: flowID, deadline: deadline)
        return .pause()
    }

    private func restrictedIdentityCompleted(flowID: UUID, identities: ResolvedIdentityPair) {
        guard let completed = take(flowID: flowID), let provider else { return }
        guard let policy = activePolicy.load() else {
            provider.resumeFlow(completed.flow, with: reporting(.allow(), hidden: true))
            return
        }
        let descriptor = completed.metadata.withIdentities(identities).descriptor
        provider.resumeFlow(
            completed.flow,
            with: restrictedVerdict(descriptor, policy: policy, now: Date())
        )
    }

    private func restrictedVerdict(
        _ descriptor: FlowDescriptor,
        policy: RuntimePolicy,
        now: Date
    ) -> NEFilterNewFlowVerdict {
        let decision = policy.decision(for: descriptor, now: now)
        let action = ConsoleSessionPolicy.restrictedAction(
            for: decision,
            flowOwner: descriptor.owner,
            authorizedUID: policy.payload.authorizedUID
        )
        return reporting(action == .deny ? .drop() : .allow(), hidden: true)
    }
}
