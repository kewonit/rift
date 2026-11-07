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
    }
}
