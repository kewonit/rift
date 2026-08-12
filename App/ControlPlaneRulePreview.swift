import AbyssControl

extension ControlPlaneController {
    func ruleWorkspaceSnapshot() async throws -> RuleWorkspaceSnapshot? {
#if DEBUG
        if isUIFixture { return MonitorFixtureData.ruleWorkspaceSnapshot }
#endif
        guard let snapshot = try await repository?.ruleWorkspaceSnapshot() else { return nil }
        let state = PolicyEnforcementPresentation.state(
            persistedState: snapshot.enforcementState,
            desiredTuple: snapshot.desiredTuple,
            handshake: lastHandshake
        )
        return snapshot.presentingEnforcementState(state)
    }

    func rulePreviewEnvironment() async throws -> RulePreviewEnvironment? {
        guard let configuration = try await repository?.currentConfiguration() else { return nil }
        return try await rulePreviewEnvironment(configuration: configuration)
    }

    func rulePreviewEnvironment(
        configuration: PolicyConfigurationDraft
    ) async throws -> RulePreviewEnvironment {
        let samples = try await monitorPage(limit: RuleImpactPreviewEvaluator.maximumSamples)
        return RulePreviewEnvironment(configuration: configuration, samples: samples)
    }
}
