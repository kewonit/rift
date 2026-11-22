import AppKit
import RiftControl
import RiftCore
import Foundation

/// Rules read from a file, checked against the current configuration and
/// waiting for the person to confirm.
struct PendingRuleImport: Equatable {
    let payload: ConfigurationArchivePayload
    let plan: RuleImportPlan
    /// What else happens, such as rules skipped from a `.lsrules` file.
    let notices: [String]

    var summary: String { ([plan.summary] + notices).joined(separator: " ") }
}

extension ControlPlaneController {
    /// Reads rules exported from Rift, or a `.lsrules` rule group file, and
    /// works out what importing them would add.
    func previewRuleImport(_ data: Data) async throws -> PendingRuleImport {
        let payload: ConfigurationArchivePayload
        let notices: [String]
        if LSRulesFile.looksLikeRulesFile(data) {
            let file = try LSRulesFile.decode(data)
            let extendedRules = filterSupportsExtendedPolicy
            let conversion = await Task.detached(priority: .userInitiated) {
                LSRulesConverter.convert(
                    file, fileName: "Imported rules", lineageID: UUID(),
                    resolve: LSRulesIdentityResolver.resolve, extendedRules: extendedRules, now: Date()
                )
            }.value
            payload = conversion.payload
            notices = conversion.notices
        } else {
            payload = try ConfigurationArchiveCodec.decodeRules(data)
            notices = []
        }
        guard let draft = try await repository?.currentConfiguration() else {
            throw ArchiveControllerError.missingConfiguration
        }
        return PendingRuleImport(
            payload: payload,
            plan: try RuleImportPlan.make(payload, into: draft, now: Date()),
            notices: notices
        )
    }

    /// Adds the rules to the current ones. Returns the new rules' IDs.
    func importRules(_ payload: ConfigurationArchivePayload) async throws -> (ConfigurationMutationResult, Set<UUID>) {
        var added: Set<UUID> = []
        let result = try await mutateConfiguration(kind: "importRules") { draft in
            let plan = try RuleImportPlan.make(payload, into: draft, now: Date())
            added = Set(plan.rules.map(\.id))
            return plan.applied(to: draft)
        }
        return (result, added)
    }

    /// The rules in `ids` as a `.lsrules` file, named for their group when
    /// they all share one.
    func lsrulesExport(_ ids: Set<UUID>) async throws -> LSRulesWriter.Export {
        guard let draft = try await repository?.currentConfiguration() else {
            throw ArchiveControllerError.missingConfiguration
        }
        let rules = draft.rules.filter { ids.contains($0.id) }
        let groups = Set(rules.map(\.localGroupID))
        let group = groups.count == 1 ? groups.first.flatMap { id in draft.localGroups.first { $0.id == id } } : nil
        return try await Task.detached(priority: .userInitiated) {
            try LSRulesWriter.export(
                rules, name: group?.name ?? "Rift Rules", description: group?.note,
                path: LSRulesIdentityResolver.executablePath
            )
        }.value
    }
}

/// Finds the code identity of a process a `.lsrules` file names, on this Mac.
enum LSRulesIdentityResolver {
    @Sendable static func resolve(_ process: LSRulesFile.Process) -> ProcessIdentity? {
        switch process {
        case .any:
            return nil
        case .path(let path):
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) else { return nil }
            return try? StaticCodeIdentityResolver.identity(at: URL(fileURLWithPath: expanded))
        case .codeID(let team, let identifier):
            // The installed app tells Rift whether it's a Developer ID or App
            // Store app; otherwise assume Developer ID, as most apps are.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
               let installed = try? StaticCodeIdentityResolver.identity(at: url) {
                let code: SignedCodeIdentity? = switch installed {
                case .developerID(let value), .appStore(let value), .applePlatform(let value): value
                default: nil
                }
                if code?.teamIdentifier == team, code?.signingIdentifier == identifier { return installed }
            }
            guard let code = try? SignedCodeIdentity(teamIdentifier: team, signingIdentifier: identifier) else {
                return nil
            }
            return .developerID(code)
        }
    }

    /// Where an app that comes with macOS keeps its executable, for a
    /// `.lsrules` file, which names such apps by path. Only an installed app
    /// whose signature matches is used, so the path names the same code.
    @Sendable static func executablePath(_ identity: ProcessIdentity) -> String? {
        guard case .applePlatform(let code) = identity,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: code.signingIdentifier),
              let executable = Bundle(url: url)?.executableURL,
              (try? StaticCodeIdentityResolver.identity(at: url)) == identity else { return nil }
        return executable.standardizedFileURL.path
    }
}
