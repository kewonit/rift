import RiftControl
import RiftCore
import SwiftUI

struct RuleInspectorActions {
    let edit: () -> Void
    let setEnabled: (Bool) -> Void
    let makePermanent: () -> Void
    let delete: () -> Void
}

struct RuleInspectorView: View {
    let row: RuleRowViewValue
    let groups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let blocklists: [BlocklistSource]
    let artworkStore: ApplicationArtworkStore
    /// Nil for rules that can't be changed here.
    var actions: RuleInspectorActions?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sections
            }
            .labeledContentStyle(RiftInspectorRowStyle())
            .padding(RiftDesign.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sections: some View {
        RiftInspectorSection("Rule") {
            HStack(spacing: 9) {
                if let identity = applicationIdentity(row.rule.process) {
                    ApplicationIdentityIcon(
                        identity: identity,
                        fallbackSystemName: "app.dashed",
                        size: 28,
                        artworkStore: artworkStore
                    )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.applicationLabel).font(.headline)
                    Text(row.conditionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let actions {
                HStack {
                    Button("Edit…", action: actions.edit)
                    Button(row.rule.isEnabled ? "Turn Off" : "Turn On") {
                        actions.setEnabled(!row.rule.isEnabled)
                    }
                    Spacer()
                    Button("Delete…", role: .destructive, action: actions.delete)
                }
            }
            LabeledContent("Action", value: row.actionLabel)
            LabeledContent("Review", value: reviewState)
            LabeledContent("Priority", value: priority)
            LabeledContent("Status", value: row.effectiveState.label)
            if let groupID = row.rule.localGroupID {
                LabeledContent("Group", value: groupName(groupID))
            }
            if let profileID = row.rule.profileID {
                LabeledContent("Profile", value: profileName(profileID))
            }
            if row.rule.flags.contains(.sourceManaged) {
                LabeledContent("Managed by", value: String(localized: "Blocklist"))
            }
            if row.rule.flags.contains(.protected) {
                LabeledContent("Protection", value: String(localized: "Protected"))
            }
        }
        RiftInspectorSection("Matches") {
            LabeledContent("Destination", value: destinationLabel)
            LabeledContent("Protocol", value: protocolLabel)
            LabeledContent("Port", value: portLabel)
            LabeledContent("Direction", value: directionLabel)
            LabeledContent("Owner", value: ownerLabel)
        }
        RiftInspectorSection("App Identity") {
            identityDetails(row.rule.process)
        }
        RiftInspectorSection("Source & Expiration") {
            LabeledContent("Source", value: sourceLabel)
            if let expiresAt = row.rule.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Expires", value: Self.expiryLabel(expiresAt, now: context.date))
                }
                if let actions {
                    Button("Make Permanent", action: actions.makePermanent)
                }
            } else {
                LabeledContent("Expires", value: String(localized: "Never"))
            }
        }
        RiftInspectorSection("Usage") {
            LabeledContent(
                "Times used",
                value: row.usage.coverage == .complete
                    ? String(row.usage.lowerBoundCount)
                    : "≥\(row.usage.lowerBoundCount)"
            )
            LabeledContent("Usage history", value: usageCoverage)
            if let lastUsedAt = row.usage.lastUsedAt {
                LabeledContent("Last used", value: lastUsedAt.formatted())
            }
        }
        if !row.rule.notes.isEmpty {
            RiftInspectorSection("Note") { Text(row.rule.notes) }
        }
        DisclosureGroup("Details") {
            LabeledContent("Revision", value: String(row.rule.revision))
            LabeledContent("Created", value: row.rule.createdAt.formatted())
            LabeledContent("Modified", value: row.rule.modifiedAt.formatted())
            if let groupID = row.rule.localGroupID {
                LabeledContent("Group ID", value: groupID.uuidString.lowercased())
            }
            if let profileID = row.rule.profileID {
                LabeledContent("Profile ID", value: profileID.uuidString.lowercased())
            }
        }
    }

    /// A countdown for the last hour, then the time it ends.
    static func expiryLabel(_ expiresAt: Date, now: Date) -> String {
        let remaining = Int(expiresAt.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return String(localized: "Ended \(expiresAt.formatted(date: .abbreviated, time: .shortened))") }
        guard remaining <= 3_600 else { return expiresAt.formatted() }
        let clock = "\(remaining / 60):\(String(format: "%02d", remaining % 60))"
        return String(localized: "In \(clock)", comment: "Time left on a rule, in minutes and seconds")
    }

    private var priority: String {
        switch row.rule.priority {
        case .elevatedUser: String(localized: "Blocklist exception")
        case .blocklistDeny: String(localized: "Blocklist")
        case .high: String(localized: "High")
        case .normal: String(localized: "Normal")
        }
    }

    private var usageCoverage: String {
        switch row.usage.coverage {
        case .complete: String(localized: "Complete")
        case .partial, .gap: String(localized: "Incomplete")
        }
    }

    private var reviewState: String {
        row.rule.reviewState == .reviewed ? String(localized: "Reviewed") : String(localized: "Needs review")
    }

    private var directionLabel: String {
        switch row.rule.direction {
        case .incoming: String(localized: "Incoming")
        case .outgoing: String(localized: "Outgoing")
        case .bidirectional: String(localized: "Both directions")
        }
    }


    private var destinationLabel: String {
        switch row.rule.destination {
        case .ipSet(let values): values.map(\.description).joined(separator: ", ")
        case .exactHostnameSet(let values): values.map(\.ascii).joined(separator: ", ")
        case .domainSet(let values): values.map { "*." + $0.ascii }.joined(separator: ", ")
        case .endpointClass(let value): RuleWorkspacePresentation.endpointClass(value)
        case .anyEndpoint: String(localized: "Any destination")
        }
    }

    private var protocolLabel: String {
        switch row.rule.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .anySupportedProtocol: String(localized: "TCP or UDP")
        }
    }

    private var portLabel: String {
        guard let port = row.rule.port else { return String(localized: "Any port") }
        return port.text(rangeSeparator: "–")
    }

    private var ownerLabel: String {
        // Blocklists apply to every account; see RuleApplicability.
        if row.rule.priority == .blocklistDeny { return String(localized: "Every account") }
        return switch row.rule.owner {
        case .authorizedUser: String(localized: "Your account")
        case .specificUser(let uid): String(localized: "User ID \(String(uid))")
        case .system: String(localized: "System")
        }
    }

    private var sourceLabel: String {
        switch row.rule.source {
        case .manual: String(localized: "Manual")
        case .imported: String(localized: "Imported")
        case .feature(let identifier): String(localized: "Rift feature · \(identifier)")
        case .blocklist(let sourceID):
            blocklists.first { $0.id == sourceID }?.name ?? String(localized: "Removed blocklist")
        }
    }

    @ViewBuilder
    private func identityDetails(_ condition: ProcessCondition) -> some View {
        switch condition {
        case .anyProcess:
            LabeledContent("App", value: String(localized: "Any app"))
        case .exact(let identity):
            identityRows(identity, label: "App")
        case .appViaHelper(let app, let helper):
            identityRows(app, label: "App")
            identityRows(helper, label: "Helper process")
        }
    }

    @ViewBuilder
    private func identityRows(_ identity: ProcessIdentity, label: LocalizedStringKey) -> some View {
        LabeledContent(label, value: MonitorQuery.identityLabel(identity))
        switch identity {
        case .applePlatform(let signed):
            signedRows(signed, kind: "Apple")
        case .developerID(let signed):
            signedRows(signed, kind: "Developer ID")
        case .appStore(let signed):
            signedRows(signed, kind: "Mac App Store")
        case .otherSigner(let hash, let identifier):
            LabeledContent("Signature", value: String(localized: "Other developer"))
            LabeledContent("Signing ID", value: identifier)
            LabeledContent("Public-key hash", value: hash.description)
        case .adHoc(let hash):
            LabeledContent("Signature", value: String(localized: "Ad hoc"))
            LabeledContent("Code hash", value: hash.description)
        case .unsigned(let path, let hash):
            LabeledContent("Signature", value: String(localized: "Unsigned"))
            LabeledContent("Path", value: path)
            LabeledContent("File hash", value: hash.description)
        }
    }

    @ViewBuilder
    private func signedRows(_ value: SignedCodeIdentity, kind: String) -> some View {
        LabeledContent("Signature", value: kind)
        LabeledContent("Signing ID", value: value.signingIdentifier)
        if let team = value.teamIdentifier {
            LabeledContent("Team ID", value: team)
        }
    }

    private func groupName(_ id: UUID) -> String {
        groups.first { $0.id == id }?.name ?? String(localized: "Removed group")
    }

    private func profileName(_ id: UUID) -> String {
        profiles.first { $0.id == id }?.name ?? String(localized: "Removed profile")
    }
}
