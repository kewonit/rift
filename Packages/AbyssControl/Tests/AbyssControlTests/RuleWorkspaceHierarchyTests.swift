import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func hierarchyGroupsExactAndHelperRulesByFullApplicationIdentity() throws {
    let app = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "APPTEAM001",
        signingIdentifier: "com.example.browser"
    ))
    let helper = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "HELPTEAM01",
        signingIdentifier: "com.example.browser.helper"
    ))
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let helperID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let anyID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let rows = try [
        hierarchyRow(id: firstID, process: .exact(app)),
        hierarchyRow(id: anyID, process: .anyProcess),
        hierarchyRow(id: helperID, process: .appViaHelper(app: app, helper: helper)),
    ]

    let nodes = RuleWorkspaceHierarchy.nodes(rows: rows)
    #expect(nodes.count == 2)
    #expect(nodes[0].applicationIdentity == app)
    #expect(nodes[0].children?.compactMap(\.row?.id) == [firstID, helperID])
    #expect(nodes[0].children?.last?.subtitle?.contains("helper") == true)
    #expect(nodes[1].title == "Any application")
    #expect(nodes[1].children?.first?.row?.id == anyID)
}

@Test func hierarchyNeverCoalescesSameSigningIdentifierAcrossTeams() throws {
    let identifier = "com.example.shared"
    let first = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "FIRSTTEAM1",
        signingIdentifier: identifier
    ))
    let second = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "SECONDTEAM",
        signingIdentifier: identifier
    ))

    let nodes = RuleWorkspaceHierarchy.nodes(rows: try [
        hierarchyRow(id: UUID(), process: .exact(first)),
        hierarchyRow(id: UUID(), process: .exact(second)),
    ])

    #expect(nodes.count == 2)
    #expect(nodes[0].title == nodes[1].title)
    #expect(nodes.map(\.subtitle) == [
        DisplaySanitizer.plainText("Team FIRSTTEAM1"),
        DisplaySanitizer.plainText("Team SECONDTEAM"),
    ])
    #expect(nodes.map(\.applicationIdentity) == [first, second])
}

@Test func hierarchySelectionExpandsApplicationRowsWithoutLosingRuleIDs() throws {
    let app = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "APPTEAM001",
        signingIdentifier: "com.example.browser"
    ))
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    let nodes = RuleWorkspaceHierarchy.nodes(rows: try [
        hierarchyRow(id: firstID, process: .exact(app)),
        hierarchyRow(id: secondID, process: .exact(app)),
    ])
    let groupID = try #require(nodes.first?.id)

    #expect(RuleWorkspaceHierarchy.ruleIDs(for: [groupID], in: nodes) == [firstID, secondID])
    let fullSelection = RuleWorkspaceHierarchy.nodeIDs(for: [firstID, secondID], in: nodes)
    #expect(fullSelection.contains(groupID))
    #expect(fullSelection.contains(.rule(firstID)))
    #expect(fullSelection.contains(.rule(secondID)))

    let partialSelection = RuleWorkspaceHierarchy.nodeIDs(for: [firstID], in: nodes)
    #expect(!partialSelection.contains(groupID))
    #expect(partialSelection == [.rule(firstID)])
}

@Test func affectingApplicationKeepsExactHelperAndAnyProcessScopesOnly() throws {
    let selected = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "SELECTED01",
        signingIdentifier: "com.example.shared"
    ))
    let otherTeam = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "OTHERTEAM1",
        signingIdentifier: "com.example.shared"
    ))
    let helper = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "HELPER0001",
        signingIdentifier: "com.example.helper"
    ))
    let exactID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let helperID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
    let anyID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
    let nodes = RuleWorkspaceHierarchy.nodes(rows: try [
        hierarchyRow(id: exactID, process: .exact(selected)),
        hierarchyRow(id: otherID, process: .exact(otherTeam)),
        hierarchyRow(id: anyID, process: .anyProcess),
        hierarchyRow(id: helperID, process: .appViaHelper(app: selected, helper: helper)),
    ])

    let affecting = RuleWorkspaceHierarchy.nodes(affecting: selected, in: nodes)
    let affectingRuleIDs = Set(affecting.flatMap(\.ruleIDs))

    #expect(affecting.count == 2)
    #expect(affectingRuleIDs == [exactID, helperID, anyID])
    #expect(!affectingRuleIDs.contains(otherID))
}

private func hierarchyRow(id: UUID, process: ProcessCondition) throws -> RuleRowViewValue {
    let now = Date(timeIntervalSince1970: 1_000)
    let rule = try Rule(
        id: id,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
        revision: 1,
        action: .filter(.allow),
        priority: .normal,
        process: process,
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        owner: .authorizedUser,
        createdAt: now,
        modifiedAt: now
    )
    return RuleRowViewValue(
        rule: rule,
        state: .enforced,
        generation: 1,
        usage: RuleUsageValue(lowerBoundCount: 0, lastUsedAt: nil, coverage: .complete)
    )
}
