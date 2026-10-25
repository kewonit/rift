#if DEBUG
import RiftControl
import RiftCore
import RiftIPC
import Foundation

enum MonitorFixtureData {
    enum Scenario: String {
        case live
        case empty
        case burst
        case denied
        case unresolved
        case missingOrigin = "missing-origin"
        case rulesFailure = "rules-failure"
        case healthSetup = "health-setup"
        case alertDeliveryFailure = "alert-delivery-failure"
    }

    static let canary = "RIFT_UI_FIXTURE_ONLY_7F4C2A91"
    static let referenceNow = Date(timeIntervalSince1970: 1_786_444_800)
    private static let previewProfileID = UUID(uuid: (
        0x20, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1
    ))
    private static let previewGroupID = UUID(uuid: (
        0x20, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 2
    ))
    private static let previewBlocklistID = UUID(uuid: (
        0x20, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 3
    ))

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-fixture")
    }

    static var usesStatusMenuPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-fixture-status-menu")
    }

    static var scenario: Scenario {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-state"),
              arguments.indices.contains(flag + 1) else { return .live }
        return Scenario(rawValue: arguments[flag + 1].lowercased()) ?? .live
    }

    static func signalVisualReadiness() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-ready-file"),
              arguments.indices.contains(flag + 1) else { return }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        guard url.deletingLastPathComponent().path == "/private/tmp",
              url.lastPathComponent.hasPrefix("rift-ui-ready-") else {
            reportReadinessFailure("refused an unsafe destination")
            return
        }
        let payload = Data("ready\n".utf8)
        if (try? Data(contentsOf: url)) == payload { return }
        do {
            try payload.write(to: url, options: .withoutOverwriting)
        } catch {
            reportReadinessFailure(error.localizedDescription)
        }
    }

    private static func reportReadinessFailure(_ message: String) {
        FileHandle.standardError.write(Data("Rift fixture readiness: \(message)\n".utf8))
    }

    private static let baseRows: [MonitorEventRow] = (try? makeRows()) ?? []
    static var rows: [MonitorEventRow] {
        switch scenario {
        case .empty: []
        case .denied:
            baseRows.filter {
                $0.event.reason == .concreteDecision && $0.event.action == .deny
            }
        case .unresolved:
            baseRows.filter { $0.event.reason != .concreteDecision }
        case .live, .burst, .missingOrigin, .rulesFailure, .healthSetup, .alertDeliveryFailure:
            baseRows
        }
    }
    static let rules: [Rule] = (try? makeRules()) ?? []

    static let ruleWorkspaceSnapshot: RuleWorkspaceSnapshot = {
        let lineage = rules.first?.lineageID
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        let profile = PolicyProfile(
            id: previewProfileID,
            name: "Work",
            symbolName: "briefcase",
            operationModeOverride: .alert,
            createdAt: referenceNow.addingTimeInterval(-604_800),
            modifiedAt: referenceNow.addingTimeInterval(-86_400)
        )
        let group = LocalRuleGroup(
            id: previewGroupID,
            name: "Browsers",
            note: "Interactive clients",
            isEnabled: true,
            createdAt: referenceNow.addingTimeInterval(-604_800),
            modifiedAt: referenceNow.addingTimeInterval(-43_200)
        )
        let blocklist = BlocklistSource(
            id: previewBlocklistID,
            name: "Local Test List",
            importedAt: referenceNow.addingTimeInterval(-10_800),
            entryCount: 1,
            domainEntryCount: 1,
            addressEntryCount: 0,
            contentHash: Data(repeating: 0x2A, count: 32),
            status: .active
        )
        let configuration = PolicyConfigurationDraft(
            lineageID: lineage,
            authorizedUID: 501,
            operationMode: .alert,
            baseOperationMode: .silentAllow,
            activeProfileID: previewProfileID,
            enabledLocalGroupIDs: [previewGroupID],
            rules: rules,
            localGroups: [group],
            profiles: [profile],
            blocklists: [blocklist]
        )
        let usage = Dictionary(uniqueKeysWithValues: rules.enumerated().map { index, rule in
            (rule.id, RuleUsageValue(
                lowerBoundCount: (index + 1) * 7,
                lastUsedAt: referenceNow.addingTimeInterval(TimeInterval(-index * 900)),
                coverage: index % 3 == 0 ? .partial : .complete
            ))
        })
        return RuleWorkspaceSnapshot(
            configuration: configuration,
            enforcementState: .enforced,
            desiredTuple: PolicyTuple(
                lineageID: lineage,
                generation: 7,
                hash: Data(repeating: 7, count: 32)
            ),
            generation: 7,
            usage: usage
        )
    }()

    static func ruleRows(filter: RuleListFilter, search: String) -> [RuleRowViewValue] {
        ruleWorkspaceSnapshot.rows(filter: filter, search: search)
    }

    static func decisionBuckets(
        from start: Date,
        to end: Date,
        width: TimeInterval,
        anchor: Date? = nil
    ) -> [DecisionBucket] {
        guard width >= 60 else { return [] }
        var values: [Date: DecisionBucket] = [:]
        for row in rows where row.event.occurredAt >= start && row.event.occurredAt < end {
            let event = row.event
            guard let key = DecisionBucketGrid.bucketStart(
                for: event.occurredAt,
                anchor: anchor,
                width: width
            ) else { continue }
            let current = values[key]
                ?? DecisionBucket(start: key, allowed: 0, denied: 0, unresolved: 0)
            let unresolved = event.reason != .concreteDecision
            values[key] = DecisionBucket(
                start: key,
                allowed: current.allowed + (unresolved || event.action == .deny ? 0 : 1),
                denied: current.denied + (!unresolved && event.action == .deny ? 1 : 0),
                unresolved: current.unresolved + (unresolved ? 1 : 0)
            )
        }
        return values.values.sorted { $0.start < $1.start }
    }

    private static func makeRows() throws -> [MonitorEventRow] {
        let provider = try requiredUUID("612E26C2-C04B-42EA-90E9-78BD0567799C")
        let appNames = [
            "Safari", "Google Chrome", "Mail", "Music", "App Store", "FaceTime",
            "Maps", "Calendar", "Messages", "Notes", "Photos", "Terminal",
            "Preview", "Weather", "Xcode", "Books", "Podcasts", "TV",
        ]
        return try (0..<54).map { index in
            let appName = appNames[index % appNames.count]
            let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
                teamIdentifier: "RIFTPREVIEW",
                signingIdentifier: appName
            ))
            let host = try DomainName("node-\(index + 1).rift.test")
            let address = try IPAddress(address(for: index))
            let endpoint = Endpoint(
                address: address,
                port: index % 7 == 0 ? 993 : 443,
                hostname: host,
                hostnameCoverage: .observed,
                classes: [],
                interfaceSnapshotGeneration: 1
            )
            let occurredAt = referenceNow.addingTimeInterval(-fixtureAge(for: index))
            let flow = FlowDescriptor(
                flowID: try requiredUUID(String(
                    format: "00000000-0000-4000-8000-%012d", index + 1
                )),
                observedAt: occurredAt,
                sourceAppIdentity: identity,
                sourceProcessIdentity: identity,
                owner: .user(uid: 501),
                direction: index % 11 == 0 ? .incoming : .outgoing,
                transportProtocol: index % 5 == 0 ? .udp : .tcp,
                localEndpoint: nil,
                remoteEndpoint: endpoint,
                observedHostname: host,
                metadataConfidence: [.appIdentity, .endpoint, .observedHostname, .owner]
            )
            let unresolved = index % 13 == 0
            let missingBytes = index % 10 == 0
            return MonitorEventRow(
                event: RuntimeEvent(
                    providerEpoch: provider,
                    sequence: UInt64(index + 1),
                    occurredAt: occurredAt,
                    flow: flow,
                    action: index % 6 == 0 ? .deny : .allow,
                    reason: unresolved ? .unmatchedModeFallback : .concreteDecision,
                    policy: nil
                ),
                coverage: missingBytes ? .partial : .complete,
                closedAt: missingBytes ? nil : occurredAt.addingTimeInterval(75),
                bytesInbound: missingBytes ? nil : UInt64(42_000 * (index + 1)),
                bytesOutbound: missingBytes ? nil : UInt64(11_000 * (index + 1)),
                flowEndReason: missingBytes ? nil : .networkExtensionReport
            )
        }
    }

    private static func makeRules() throws -> [Rule] {
        let lineage = try requiredUUID("A4F31042-EA13-4D42-B307-AB1D70160322")
        let specifications: [(String, String, FilterAction, UInt16, Bool)] = [
            ("Safari", "media.rift.test", .allow, 443, true),
            ("Calendar", "sync.rift.test", .allow, 443, true),
            ("Messages", "presence.rift.test", .deny, 443, true),
            ("Google Chrome", "storage.rift.test", .allow, 443, false),
            ("Mail", "mail.rift.test", .ask, 993, true),
            ("Music", "audio.rift.test", .deny, 443, true),
        ]
        let manualRules = try specifications.enumerated().map { index, value in
            let (appName, hostname, action, port, enabled) = value
            let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
                teamIdentifier: "RIFTPREVIEW",
                signingIdentifier: appName
            ))
            let createdAt = referenceNow.addingTimeInterval(TimeInterval(-(index + 1) * 86_400))
            return try Rule(
                id: requiredUUID(String(
                    format: "10000000-0000-4000-8000-%012d", index + 1
                )),
                lineageID: lineage,
                revision: UInt64(index + 1),
                action: .filter(action),
                priority: .normal,
                process: .exact(identity),
                destination: .exactHostnameSet([try DomainName(hostname)]),
                transportProtocol: .tcp,
                port: try PortRange(port, port),
                direction: .outgoing,
                owner: .authorizedUser,
                profileID: index < 2 ? previewProfileID : nil,
                localGroupID: index == 0 || index == 2 ? previewGroupID : nil,
                expiresAt: index == 4 ? referenceNow.addingTimeInterval(86_400) : nil,
                isEnabled: enabled,
                reviewState: index == 2 ? .unreviewed : .reviewed,
                notes: index == 2 ? "Review after testing" : "",
                createdAt: createdAt,
                modifiedAt: createdAt.addingTimeInterval(3_600)
            )
        }
        let blocklistRule = try Rule(
            id: requiredUUID("10000000-0000-4000-8000-000000000007"),
            lineageID: lineage,
            revision: 7,
            action: .filter(.deny),
            priority: .blocklistDeny,
            process: .anyProcess,
            destination: .normalizedExactHostnameSet([try DomainName("tracker.rift.test")]),
            transportProtocol: .anySupportedProtocol,
            port: nil,
            direction: .bidirectional,
            owner: .authorizedUser,
            flags: [.sourceManaged],
            source: .blocklist(sourceID: previewBlocklistID),
            createdAt: referenceNow.addingTimeInterval(-10_800),
            modifiedAt: referenceNow.addingTimeInterval(-10_800)
        )
        return manualRules + [blocklistRule]
    }

    /// Preview countries for the documentation-only addresses fixture rows use.
    static func countryCode(for address: IPAddress) -> String? {
        let countries = ["US", "DE", "JP", "GB", "SG", "IE", "FR", "BR", "AU", "NL", "IN", "CA"]
        guard address.family == .ipv4, let last = address.bytes.last else { return nil }
        return countries[Int(last) % countries.count]
    }

    private static func address(for index: Int) -> String {
        switch index % 3 {
        case 0: "192.0.2.\(index + 1)"
        case 1: "198.51.100.\(index + 1)"
        default: "203.0.113.\(index + 1)"
        }
    }

    private static func fixtureAge(for index: Int) -> TimeInterval {
        if index < 12 { return TimeInterval(index * 45) }
        if index < 24 { return 600 + TimeInterval(index - 11) * 1_800 }
        if index < 36 { return 22_200 + TimeInterval(index - 23) * 21_600 }
        return 281_400 + TimeInterval(index - 35) * 129_600
    }

    private static func requiredUUID(_ value: String) throws -> UUID {
        guard let result = UUID(uuidString: value) else { throw FixtureError.invalidUUID }
        return result
    }

    private enum FixtureError: Error {
        case invalidUUID
    }
}
#endif
