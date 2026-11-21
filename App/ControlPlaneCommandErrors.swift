import Foundation

extension ControlPlaneController {
    enum RuleCommandError: Error {
        case generationConflict
        case missingConfiguration
        case unknownDefinition
        case unavailableIdentity
        case invalidOwnerScope
        case protectedAssignments
        case elevatedOverrideRequiresConfirmation
        case overriddenByRule(UUID?)
        case permanentRuleConflict(UUID)
        /// A rule for an incoming connection names this Mac's service, not
        /// the peer, so overriding a blocklist would let every listed address in.
        case incomingBlocklistOverride(Set<UUID>)
    }
}
