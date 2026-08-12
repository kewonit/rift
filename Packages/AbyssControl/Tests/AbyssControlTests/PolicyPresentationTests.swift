import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func policyPresentationKeepsBaseAndEffectiveModesDistinct() throws {
    let profileID = try #require(UUID(uuidString: "4c0a97a1-bc92-4ad7-80bc-3ff6b6801190"))
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let profile = PolicyProfile(
        id: profileID,
        name: "Work",
        symbolName: nil,
        operationModeOverride: .silentDeny,
        createdAt: timestamp,
        modifiedAt: timestamp
    )
    let configuration = PolicyConfigurationDraft(
        lineageID: try #require(UUID(uuidString: "b60169f0-4b93-49f6-a943-8aa949ab3845")),
        authorizedUID: 501,
        operationMode: .silentDeny,
        baseOperationMode: .silentAllow,
        activeProfileID: profileID,
        enabledLocalGroupIDs: [],
        rules: [],
        profiles: [profile]
    )

    let presentation = PolicyPresentation(configuration: configuration)

    #expect(presentation.baseMode == .silentAllow)
    #expect(presentation.effectiveMode == .silentDeny)
    #expect(presentation.profile == profile)
}

@Test func policyPresentationUsesStoredModesWithoutAnActiveProfile() throws {
    let configuration = PolicyConfigurationDraft(
        lineageID: try #require(UUID(uuidString: "16a05658-40f3-4e12-9216-16bb56929170")),
        authorizedUID: 501,
        operationMode: .alert,
        baseOperationMode: .alert,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    )

    let presentation = PolicyPresentation(configuration: configuration)

    #expect(presentation.baseMode == .alert)
    #expect(presentation.effectiveMode == .alert)
    #expect(presentation.profile == nil)
}
