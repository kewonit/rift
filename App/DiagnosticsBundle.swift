import RiftControl
import RiftCore
import Foundation
import OSLog

struct DiagnosticsExportOptions: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let recentActivity = DiagnosticsExportOptions(rawValue: 1 << 0)
    static let ruleSummaries = DiagnosticsExportOptions(rawValue: 1 << 1)
    static let appLogExcerpts = DiagnosticsExportOptions(rawValue: 1 << 2)
}

struct DiagnosticsBundlePreview: Sendable, Hashable {
    let defaultSections: [String]
    let optionalSections: [String]
}

extension ControlPlaneController {
    func redactedDiagnosticsData() async throws -> Data {
        try await diagnosticsBundleData(options: [])
    }

    func diagnosticsPreview(
        options: DiagnosticsExportOptions
    ) async throws -> DiagnosticsBundlePreview {
        let configuration = try? await repository?.currentConfiguration()
        let activityCount = (try? await monitorPage(limit: 50).count) ?? 0
        var optional: [String] = []
        if options.contains(.recentActivity) {
            optional.append("Up to \(activityCount) visible activities, freshly pseudonymized")
        }
        if options.contains(.ruleSummaries) {
            optional.append("Up to \(min(configuration?.rules.count ?? 0, 200)) rule summaries, freshly pseudonymized")
        }
        if options.contains(.appLogExcerpts) {
            optional.append("Up to 200 current-process Rift log entries from the last 15 minutes")
        }
        return DiagnosticsBundlePreview(
            defaultSections: [
                "App, extension, OS, and arm64 version state",
                "Provider readiness and generation consistency",
                "Database, retention, prompt, and non-hidden drop counters",
            ],
            optionalSections: optional
        )
    }

    func diagnosticsBundleData(options: DiagnosticsExportOptions) async throws -> Data {
        let pseudonymizer = DiagnosticsPseudonymizer()
        let summary = await redactedDiagnosticsSummary()
        let sensitive = try await sensitiveDiagnostics(
            options: options, pseudonymizer: pseudonymizer
        )
        let bundle = DiagnosticsBundle(
            schemaVersion: 2,
            generatedAt: Date(),
            pseudonymizationNotice: sensitive == nil ? nil
                : "Optional values are linkable only within this bundle. They are pseudonymous, not anonymous; the fresh export key is not retained.",
            summary: summary,
            optionalSections: sensitive
        )
        return try CanonicalPolicyJSON.encoder().encode(bundle)
    }

    private func sensitiveDiagnostics(
        options: DiagnosticsExportOptions,
        pseudonymizer: DiagnosticsPseudonymizer
    ) async throws -> DiagnosticsSensitiveSections? {
        guard !options.isEmpty else { return nil }
        let activity: [DiagnosticsActivity]
        if options.contains(.recentActivity) {
            activity = (try? await monitorPage(limit: 50))?.map { row in
                DiagnosticsActivity(
                    application: pseudonymizer.token(for: MonitorQuery.applicationLabel(row)),
                    endpoint: pseudonymizer.token(for: MonitorQuery.endpointLabel(row)),
                    occurredAt: row.event.occurredAt,
                    action: row.event.action.rawValue,
                    reason: row.event.reason.rawValue,
                    transport: MonitorQuery.protocolLabel(row)
                )
            } ?? []
        } else { activity = [] }
        let rules: [DiagnosticsRuleSummary]
        if options.contains(.ruleSummaries),
           let configuration = try? await repository?.currentConfiguration() {
            rules = configuration.rules.prefix(200).map { rule in
                DiagnosticsRuleSummary(
                    id: pseudonymizer.token(for: rule.id.uuidString),
                    process: pseudonymizer.token(for: processDescription(rule.process)),
                    destination: pseudonymizer.token(for: destinationDescription(rule.destination)),
                    action: actionDescription(rule.action),
                    enabled: rule.isEnabled,
                    priority: rule.priority.rawValue
                )
            }
        } else { rules = [] }
        let logs = options.contains(.appLogExcerpts) ? appLogExcerpts() : nil
        return DiagnosticsSensitiveSections(
            recentActivity: activity,
            ruleSummaries: rules,
            appLogExcerpts: logs
        )
    }

    private func appLogExcerpts() -> DiagnosticsLogSection {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(
                date: Date().addingTimeInterval(-15 * 60)
            )
            let predicate = NSPredicate(format: "subsystem == %@", "io.rift.firewall")
            let entries = try store.getEntries(at: position, matching: predicate)
                .compactMap { $0 as? OSLogEntryLog }
                .prefix(200)
                .map {
                    DiagnosticsLogEntry(
                        date: $0.date,
                        category: DisplaySanitizer.plainText($0.category, maximumScalars: 64),
                        level: String(describing: $0.level),
                        message: DisplaySanitizer.plainText($0.composedMessage, maximumScalars: 512)
                    )
                }
            return DiagnosticsLogSection(status: "available", entries: Array(entries))
        } catch {
            return DiagnosticsLogSection(
                status: "unavailable:\(String(describing: type(of: error)))",
                entries: []
            )
        }
    }

    private func processDescription(_ value: ProcessCondition) -> String {
        switch value {
        case .anyProcess: "any-process"
        case .exact(let identity): String(describing: identity)
        case .appViaHelper(let app, let helper): "\(app)-via-\(helper)"
        }
    }

    private func destinationDescription(_ value: DestinationCondition) -> String {
        switch value {
        case .ipSet(let values): values.map(\.description).joined(separator: ",")
        case .exactHostnameSet(let values): values.map(\.ascii).joined(separator: ",")
        case .domainSet(let values): values.map(\.ascii).joined(separator: ",")
        case .endpointClass(let value): value.rawValue
        case .anyEndpoint: "any-endpoint"
        }
    }

    private func actionDescription(_ value: RuleAction) -> String {
        switch value {
        case .filter(let action): action.rawValue
        case .notification: "notify"
        case .privacy: "hide"
        }
    }
}

private struct DiagnosticsBundle: Codable {
    let schemaVersion: UInt16
    let generatedAt: Date
    let pseudonymizationNotice: String?
    let summary: RedactedDiagnostics
    let optionalSections: DiagnosticsSensitiveSections?
}

private struct DiagnosticsSensitiveSections: Codable {
    let recentActivity: [DiagnosticsActivity]
    let ruleSummaries: [DiagnosticsRuleSummary]
    let appLogExcerpts: DiagnosticsLogSection?
}

private struct DiagnosticsActivity: Codable {
    let application: String
    let endpoint: String
    let occurredAt: Date
    let action: String
    let reason: String
    let transport: String
}

private struct DiagnosticsRuleSummary: Codable {
    let id: String
    let process: String
    let destination: String
    let action: String
    let enabled: Bool
    let priority: String
}

private struct DiagnosticsLogSection: Codable {
    let status: String
    let entries: [DiagnosticsLogEntry]
}

private struct DiagnosticsLogEntry: Codable {
    let date: Date
    let category: String
    let level: String
    let message: String
}
