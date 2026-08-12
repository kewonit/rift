import AbyssIPC
import Foundation

public enum InitialPolicyLineageResolution: Sendable, Equatable {
    case resume(UUID)
    case unclaimed
}

public enum ControlPlaneSafetyError: Error, Sendable, Equatable {
    case localConfigurationMissing
    case stalePrompt
}

public enum ControlPlaneSafety {
    public static func initialLineageResolution(
        handshake: HandshakeState
    ) throws -> InitialPolicyLineageResolution {
        guard handshake.acceptedGenerationHighWater == 0,
              handshake.persisted == nil,
              handshake.active == nil else {
            throw ControlPlaneSafetyError.localConfigurationMissing
        }
        if let boundLineageID = handshake.boundLineageID {
            return .resume(boundLineageID)
        }
        return .unclaimed
    }

    public static func validateDurablePrompt(
        _ prompt: PromptRequest,
        pendingPrompts: [PromptRequest],
        handshake: HandshakeState,
        desiredPolicy: PolicyTuple,
        configuration: PolicyConfigurationDraft,
        requestedProfileID: UUID?,
        now: Date
    ) throws {
        guard now < prompt.deadline,
              pendingPrompts.contains(prompt),
              handshake.controllerLeaseID != nil,
              handshake.providerEpoch == prompt.providerEpoch,
              handshake.boundLineageID == prompt.lineageID,
              handshake.active == desiredPolicy,
              desiredPolicy.lineageID == prompt.lineageID,
              desiredPolicy.generation == prompt.generation,
              configuration.lineageID == prompt.lineageID else {
            throw ControlPlaneSafetyError.stalePrompt
        }
        if let requestedProfileID {
            guard configuration.activeProfileID == requestedProfileID,
                  configuration.profiles.contains(where: { $0.id == requestedProfileID }) else {
                throw ControlPlaneSafetyError.stalePrompt
            }
        }
    }
}
