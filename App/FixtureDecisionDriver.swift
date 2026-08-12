#if DEBUG
import AbyssCore
import AbyssIPC
import Foundation

extension ControlPlaneController {
    func startFixtureDriverIfRequested() async -> Bool {
        guard ProcessInfo.processInfo.environment["ABYSS_FIXTURE_DRIVER"] == "1" else { return false }
        let configuredLineage = ProcessInfo.processInfo.environment["ABYSS_FIXTURE_LINEAGE_ID"]
            .flatMap(UUID.init(uuidString:))
        let lineage = configuredLineage
            ?? lastHandshake?.active?.lineageID
            ?? lastHandshake?.persisted?.lineageID
            ?? UUID(uuidString: "7B5308B7-409D-4746-AE51-F61186233E48")!
        guard (try? await client.claimController(lineageID: lineage)) != nil else { return true }
        fixtureTask?.cancel()
        fixtureTask = Task { [client] in
            while !Task.isCancelled {
                do {
                    for prompt in try await client.drainPrompts() {
                        let action: FilterAction = prompt.endpoint?.port == 9 ? .deny : .allow
                        try await client.answerPrompt(PromptAnswer(
                            nonce: prompt.nonce,
                            providerEpoch: prompt.providerEpoch,
                            lineageID: prompt.lineageID,
                            generation: prompt.generation,
                            action: action
                        ))
                    }
                } catch { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return true
    }
}
#endif
