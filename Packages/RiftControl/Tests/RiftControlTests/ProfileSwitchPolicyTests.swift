import Foundation
import RiftControl
import RiftCore
import Testing

private let modes: [OperationMode] = [.filterOff, .silentAllow, .alert, .silentDeny]

@Test func unattendedSwitchesMayKeepTheCurrentMode() {
    for mode in modes {
        #expect(mode.permitsUnattendedSwitch(to: mode))
    }
}

@Test func unattendedSwitchesMayOnlyStrengthenWithoutConfirmation() {
    #expect(OperationMode.filterOff.permitsUnattendedSwitch(to: .silentAllow))
    #expect(OperationMode.filterOff.permitsUnattendedSwitch(to: .alert))
    #expect(OperationMode.silentAllow.permitsUnattendedSwitch(to: .alert))
}

@Test func unattendedSwitchesNeverWeakenProtection() {
    #expect(!OperationMode.alert.permitsUnattendedSwitch(to: .silentAllow))
    #expect(!OperationMode.silentDeny.permitsUnattendedSwitch(to: .alert))
    #expect(!OperationMode.silentDeny.permitsUnattendedSwitch(to: .silentAllow))
    for mode in modes where mode != .filterOff {
        #expect(!mode.permitsUnattendedSwitch(to: .filterOff))
    }
}

@Test func unattendedSwitchesNeverMakeAChangeRiftWouldConfirm() {
    for mode in modes where mode != .silentDeny {
        #expect(!mode.permitsUnattendedSwitch(to: .silentDeny))
    }
}

@Test func activatingAProfileUsesItsOverrideOrTheBaseMode() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let paused = PolicyProfile(
        id: UUID(), name: "Paused", symbolName: "person.crop.circle",
        operationModeOverride: .filterOff, createdAt: now, modifiedAt: now
    )
    let inherits = PolicyProfile(
        id: UUID(), name: "Inherits", symbolName: "person.crop.circle",
        operationModeOverride: nil, createdAt: now, modifiedAt: now
    )
    let draft = PolicyConfigurationDraft(
        lineageID: UUID(), authorizedUID: 501,
        operationMode: .alert, baseOperationMode: .alert,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: [],
        profiles: [paused, inherits]
    )
    #expect(draft.operationMode(activatingProfile: paused.id) == .filterOff)
    #expect(draft.operationMode(activatingProfile: inherits.id) == .alert)
    #expect(draft.operationMode(activatingProfile: nil) == .alert)
}

private let switchNow = Date(timeIntervalSince1970: 1_700_000_000)
private let switchLineage = UUID()

private func profile(_ name: String, mode: OperationMode? = nil) -> PolicyProfile {
    PolicyProfile(
        id: UUID(), name: name, symbolName: "person.crop.circle",
        operationModeOverride: mode, createdAt: switchNow, modifiedAt: switchNow
    )
}

private func profileRule(_ action: RuleAction, in profile: PolicyProfile) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: switchLineage, revision: 1, action: action, priority: .normal,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, profileID: profile.id,
        createdAt: switchNow, modifiedAt: switchNow
    )
}

private func draft(
    active: PolicyProfile?,
    profiles: [PolicyProfile],
    rules: [Rule]
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: switchLineage, authorizedUID: 501,
        operationMode: active?.operationModeOverride ?? .alert, baseOperationMode: .alert,
        activeProfileID: active?.id, enabledLocalGroupIDs: [], rules: rules, profiles: profiles
    )
}

@Test func unattendedSwitchesNeverTurnOffAProfilesBlocks() throws {
    let office = profile("Office")
    let config = draft(active: office, profiles: [office], rules: [
        try profileRule(.filter(.deny), in: office),
    ])
    #expect(!config.permitsUnattendedProfileSwitch(to: nil))
}

@Test func unattendedSwitchesNeverTurnOnAProfilesAllows() throws {
    let home = profile("Home")
    let config = draft(active: nil, profiles: [home], rules: [
        try profileRule(.filter(.allow), in: home),
    ])
    #expect(!config.permitsUnattendedProfileSwitch(to: home.id))
}

@Test func unattendedSwitchesMayTightenRules() throws {
    let strict = profile("Strict")
    let loose = profile("Loose")
    let config = draft(active: loose, profiles: [strict, loose], rules: [
        try profileRule(.filter(.allow), in: loose),
        try profileRule(.filter(.deny), in: strict),
        try profileRule(.notification(.notify), in: strict),
    ])
    #expect(config.permitsUnattendedProfileSwitch(to: strict.id))
    #expect(config.permitsUnattendedProfileSwitch(to: loose.id))
}

@Test func unattendedSwitchesStillCheckTheMode() {
    let paused = profile("Paused", mode: .filterOff)
    let config = draft(active: nil, profiles: [paused], rules: [])
    #expect(!config.permitsUnattendedProfileSwitch(to: paused.id))
}

@Test func unattendedSwitchesIgnoreRulesThatWouldntApply() throws {
    let office = profile("Office")
    let expired = try Rule(
        id: UUID(), lineageID: switchLineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, profileID: office.id,
        expiresAt: switchNow.addingTimeInterval(-60), createdAt: switchNow, modifiedAt: switchNow
    )
    let groupOff = try Rule(
        id: UUID(), lineageID: switchLineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, profileID: office.id,
        localGroupID: UUID(), createdAt: switchNow, modifiedAt: switchNow
    )
    let config = draft(active: office, profiles: [office], rules: [expired, groupOff])
    #expect(config.permitsUnattendedProfileSwitch(to: nil, now: switchNow))
}
