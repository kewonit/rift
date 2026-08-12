import AbyssCore
import AbyssFilterRuntime
import AbyssIPC
import Foundation
@preconcurrency import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let runtime = RuntimeEnvironment.policy
    private let epoch = ProviderEpochBox()
    private let consoleSession = ConsoleSessionTracker()
    private let interfaceRoutes = InterfaceRouteSnapshotStore()
    private let liveFlows = LiveFlowTracker(events: RuntimeEnvironment.events)
    private lazy var flowCoordinator = FlowResolutionCoordinator(
        provider: self,
        activePolicy: runtime.activePolicy,
        prompts: RuntimeEnvironment.prompts,
        events: RuntimeEnvironment.events,
        notifications: RuntimeEnvironment.notifications,
        reloads: RuntimeEnvironment.reloads,
        liveFlows: liveFlows
    )

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let completion = StartCompletion(completionHandler)
        flowCoordinator.providerStarted()
        let settingsApplier = ProviderSettingsApplier(self)
        Task { [runtime, epoch, settingsApplier] in
            let registration = await runtime.prepareProviderStart()
            epoch.store(registration)
            let settings = AbyssAllowAllFilterSettings()
            settingsApplier.apply(settings) { error in
                Task {
                    _ = await runtime.completeProviderStart(
                        epoch: registration,
                        settingsSucceeded: error == nil
                    )
                    completion.call(error)
                }
            }
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        flowCoordinator.providerStopped()
        liveFlows.providerStopped()
        let registration = epoch.take()
        let completion = StopCompletion(completionHandler)
        Task { [runtime] in
            await runtime.stopProvider(epoch: registration)
            completion.call()
        }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let policy = runtime.activePolicy.load() else {
            return reporting(.allow(), hidden: true)
        }
        let captured = FlowMetadataNormalizer.capture(
            flow,
            interfaceSnapshot: interfaceRoutes.load()
        )
        guard ConsoleSessionPolicy.permitsInteractivePolicy(
            authorizedUID: policy.payload.authorizedUID,
            currentConsoleUID: consoleSession.currentUID,
            flowOwner: captured.descriptor.owner
        ) else {
            let decision = policy.decision(
                for: captured.descriptor,
                now: captured.descriptor.observedAt
            )
            let action = ConsoleSessionPolicy.restrictedAction(for: decision)
            return reporting(action == .deny ? .drop() : .allow(), hidden: true)
        }
        return flowCoordinator.verdict(for: flow, metadata: captured, policy: policy)
    }

    override func handle(_ report: NEFilterReport) {
        liveFlows.handle(report)
    }

    private func reporting(
        _ verdict: NEFilterNewFlowVerdict,
        hidden: Bool
    ) -> NEFilterNewFlowVerdict {
        verdict.shouldReport = !hidden
        return verdict
    }
}

final class LiveFlowTracker: @unchecked Sendable {
    private let events: RuntimeEventRing
    private let reports = VisibleFlowReportTracker()

    init(events: RuntimeEventRing) {
        self.events = events
    }

    func retain(_ flow: NEFilterFlow, decision: RuntimeEventSeed) {
        if reports.retain(flowID: flow.identifier as UUID, decision: decision)
            == .capacityExceeded {
            events.recordAnonymousLoss()
        }
    }

    func handle(_ report: NEFilterReport) {
        guard let flow = report.flow else { return }
        switch report.event {
        case .flowClosed:
            guard let decision = reports.take(flowID: flow.identifier as UUID) else { return }
            events.append(lifecycleEvent(
                kind: .closed,
                decision: decision,
                report: report,
                flowEndReason: .networkExtensionReport
            ))
        case .statistics:
            guard let decision = reports.decision(flowID: flow.identifier as UUID) else { return }
            events.append(lifecycleEvent(
                kind: .statistics,
                decision: decision,
                report: report,
                flowEndReason: nil
            ))
        case .newFlow, .dataDecision:
            break
        @unknown default:
            break
        }
    }

    func providerStopped() {
        for decision in reports.takeAll() {
            events.append(RuntimeEventSeed(
                kind: .closed,
                occurredAt: Date(),
                flow: decision.flow,
                action: decision.action,
                reason: decision.reason,
                policy: decision.policy,
                winningRuleID: decision.winningRuleID,
                affectingRuleIDs: decision.affectingRuleIDs,
                explanation: decision.explanation,
                flowEndReason: .providerStopped,
                notificationRequested: decision.notificationRequested
            ))
        }
    }

    private func lifecycleEvent(
        kind: RuntimeEventKind,
        decision: RuntimeEventSeed,
        report: NEFilterReport,
        flowEndReason: RuntimeFlowEndReason?
    ) -> RuntimeEventSeed {
        RuntimeEventSeed(
            kind: kind,
            occurredAt: Date(),
            flow: decision.flow,
            action: decision.action,
            reason: decision.reason,
            policy: decision.policy,
            winningRuleID: decision.winningRuleID,
            affectingRuleIDs: decision.affectingRuleIDs,
            explanation: decision.explanation,
            bytesInbound: UInt64(report.bytesInboundCount),
            bytesOutbound: UInt64(report.bytesOutboundCount),
            flowEndReason: flowEndReason,
            notificationRequested: decision.notificationRequested
        )
    }
}

// NetworkExtension owns the provider's callback threading. This bridge exposes
// only apply(_:completionHandler:) and retains the provider until that one
// asynchronous operation finishes.
private final class ProviderSettingsApplier: @unchecked Sendable {
    private let provider: NEFilterDataProvider

    init(_ provider: NEFilterDataProvider) {
        self.provider = provider
    }

    func apply(_ settings: NEFilterSettings, completion: @escaping @Sendable (Error?) -> Void) {
        provider.apply(settings, completionHandler: completion)
    }
}

private final class ProviderEpochBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func store(_ value: UUID) {
        lock.withLock { self.value = value }
    }

    func take() -> UUID? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}

private final class StartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        let pending = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?(error)
    }
}

private final class StopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        let pending = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?()
    }
}
