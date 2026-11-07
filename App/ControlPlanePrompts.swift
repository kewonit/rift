import RiftControl
import RiftCore
import RiftIPC
import Foundation

extension ControlPlaneController {
    func mergeIncomingPrompts(_ incoming: [PromptRequest], now: Date) {
        guard !incoming.isEmpty || !pendingPrompts.isEmpty else { return }
        let merged = PromptListMerge.merged(existing: pendingPrompts, incoming: incoming, now: now)
        if merged != pendingPrompts { pendingPrompts = merged }
    }

    func retainActivePrompts(_ nonces: Set<UUID>) {
        if pendingPrompts.contains(where: { !nonces.contains($0.nonce) }) {
            pendingPrompts.removeAll { !nonces.contains($0.nonce) }
        }
    }

    func reconcilePendingPrompts(with batch: RuntimeEventBatch) {
        guard !pendingPrompts.isEmpty else { return }
        guard let epoch = batch.providerEpoch else {
            pendingPrompts.removeAll()
            return
        }
        let resolvedFlowIDs = Set(batch.events.lazy
            .filter { $0.providerEpoch == epoch && $0.kind == .decision }
            .map { $0.flow.flowID })
        pendingPrompts.removeAll {
            $0.providerEpoch != epoch || resolvedFlowIDs.contains($0.flowID)
        }
    }

    func answerOnce(_ prompt: PromptRequest, action: FilterAction) async throws {
#if DEBUG
        if isUIFixture {
            if MonitorFixtureData.scenario == .alertDeliveryFailure {
                throw ControlPlaneSafetyError.stalePrompt
            }
            pendingPrompts.removeAll { $0.nonce == prompt.nonce }
            return
        }
#endif
        try await client.answerPrompt(PromptAnswer(
            nonce: prompt.nonce,
            providerEpoch: prompt.providerEpoch,
            lineageID: prompt.lineageID,
            generation: prompt.generation,
            action: action
        ))
        pendingPrompts.removeAll { $0.nonce == prompt.nonce }
    }

    func removePendingPrompt(_ nonce: UUID) { pendingPrompts.removeAll { $0.nonce == nonce } }
}
