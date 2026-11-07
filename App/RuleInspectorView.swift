import RiftControl
import RiftCore
import SwiftUI

struct RuleInspectorActions {
    let edit: () -> Void
    let setEnabled: (Bool) -> Void
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
        Form {
            Section("Rule") {
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
                    LabeledContent("Managed by", value: "Blocklist")
                }
                if row.rule.flags.contains(.protected) {
                    LabeledContent("Protection", value: "Protected")
                }
            }
            Section("Matches") {
                LabeledContent("Destination", value: destinationLabel)
                LabeledContent("Protocol", value: protocolLabel)
                LabeledContent("Port", value: portLabel)
                LabeledContent("Direction", value: row.rule.direction.rawValue.capitalized)
                LabeledContent("Owner", value: ownerLabel)
            }
            Section("App Identity") {
                identityDetails(row.rule.process)
            }
            Section("Source & Expiration") {
                LabeledContent("Source", value: sourceLabel)
                if let expiresAt = row.rule.expiresAt {
                    LabeledContent("Expires", value: expiresAt.formatted())
                } else {
                    LabeledContent("Expires", value: "Never")
                }
            }
            Section("Usage") {
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
                Section("Note") { Text(row.rule.notes) }
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
        .formStyle(.grouped)
        .navigationTitle("Rule Inspector")
    }

    private var priority: String {
        switch row.rule.priority {
        case .elevatedUser: "Blocklist exception"
        case .blocklistDeny: "Blocklist"
        case .normal: "Normal"
        }
    }

    private var usageCoverage: String {
        switch row.usage.coverage {
        case .complete: "Complete"
        case .partial, .gap: "Incomplete"
        }
    }

    private var reviewState: String {
        row.rule.reviewState == .reviewed ? "Reviewed" : "Needs review"
    }


    private var destinationLabel: String {
        switch row.rule.destination {
        case .ipSet(let values): values.map(\.description).joined(separator: ", ")
        case .exactHostnameSet(let values): values.map(\.ascii).joined(separator: ", ")
        case .domainSet(let values): values.map { "*." + $0.ascii }.joined(separator: ", ")
        case .endpointClass(let value): RuleWorkspacePresentation.endpointClass(value)
        case .anyEndpoint: "Any destination"
        }
    }

    private var protocolLabel: String {
        switch row.rule.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .anySupportedProtocol: "TCP or UDP"
        }
    }

    private var portLabel: String {
        guard let port = row.rule.port else { return "Any port" }
        return port.lowerBound == port.upperBound
            ? String(port.lowerBound) : "\(port.lowerBound)–\(port.upperBound)"
    }

    private var ownerLabel: String {
        switch row.rule.owner {
        case .authorizedUser: "Your account"
        case .specificUser(let uid): "User ID \(uid)"
        case .system: "System"
        }
    }

    private var sourceLabel: String {
        switch row.rule.source {
        case .manual: "Manual"
        case .imported: "Imported"
        case .feature(let identifier): "Rift feature · \(identifier)"
        case .blocklist(let sourceID):
            blocklists.first { $0.id == sourceID }?.name ?? "Removed blocklist"
        }
    }

    @ViewBuilder
    private func identityDetails(_ condition: ProcessCondition) -> some View {
        switch condition {
        case .anyProcess:
            LabeledContent("App", value: "Any app")
        case .exact(let identity):
            identityRows(identity, label: "App")
        case .appViaHelper(let app, let helper):
            identityRows(app, label: "App")
            identityRows(helper, label: "Helper process")
        }
    }

    @ViewBuilder
    private func identityRows(_ identity: ProcessIdentity, label: String) -> some View {
        LabeledContent(label, value: MonitorQuery.identityLabel(identity))
        switch identity {
        case .applePlatform(let signed):
            signedRows(signed, kind: "Apple")
        case .developerID(let signed):
            signedRows(signed, kind: "Developer ID")
        case .appStore(let signed):
            signedRows(signed, kind: "Mac App Store")
        case .otherSigner(let hash, let identifier):
            LabeledContent("Signature", value: "Other developer")
            LabeledContent("Signing ID", value: identifier)
            LabeledContent("Public-key hash", value: hash.description)
        case .adHoc(let hash):
            LabeledContent("Signature", value: "Ad hoc")
            LabeledContent("Code hash", value: hash.description)
        case .unsigned(let path, let hash):
            LabeledContent("Signature", value: "Unsigned")
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
        groups.first { $0.id == id }?.name ?? "Removed group"
    }

    private func profileName(_ id: UUID) -> String {
        profiles.first { $0.id == id }?.name ?? "Removed profile"
    }
}
