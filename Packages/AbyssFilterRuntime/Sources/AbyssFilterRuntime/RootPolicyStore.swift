import AbyssCore
import AbyssIPC
import Foundation

public enum RootPolicyStoreError: Error, Sendable, Equatable {
    case corruptOwnership
    case corruptSlot
    case incompatibleSchema
    case incompatibleProtocol
    case residualSlotsWhileUnclaimed
    case conflictingSlotOwners
    case mutationLocked
    case ownerMismatch
    case lineageMismatch
    case staleGeneration
    case generationHashMismatch
    case noValidPolicy
}

enum RootPolicyStorePromotionCheckpoint: Sendable, Equatable {
    case beforeSlotWrite(target: String)
    case beforeSlotReopen(target: String)
}

public actor RootPolicyStore {
    struct ValidatedSlot {
        let name: String
        let slot: PolicySlot
        let artifact: PolicyArtifact
        let payload: CompiledPolicyPayload
    }

    enum FixedSlotState {
        case absent(name: String)
        case valid(ValidatedSlot)
        case corruptOrIncompatible(name: String)
        case operationalFailure(name: String, error: any Error)

        var isAbsent: Bool {
            if case .absent = self { return true }
            return false
        }
    }

    static let ownershipName = "ownership.json"
    static let slotAName = "policy-a.slot"
    static let slotBName = "policy-b.slot"
    static let slotIndexName = "slot-index.json"
    private static let maximumSlotFileBytes = 24 * 1_024 * 1_024
    let directory: SecureDirectory
    private let promotionFault: (@Sendable (RootPolicyStorePromotionCheckpoint) throws -> Void)?
    private var allowsFreshInitialization: Bool

    public init(rootURL: URL) throws {
        let directory = try SecureDirectory(url: rootURL)
        self.directory = directory
        promotionFault = nil
        allowsFreshInitialization = directory.wasCreated
    }

    init(
        rootURL: URL,
        promotionFault: @escaping @Sendable (RootPolicyStorePromotionCheckpoint) throws -> Void
    ) throws {
        let directory = try SecureDirectory(url: rootURL)
        self.directory = directory
        self.promotionFault = promotionFault
        allowsFreshInitialization = directory.wasCreated
    }

    public func initializeIfNeeded() throws -> RootOwnership {
        try directory.withExclusiveLock { try initializeIfNeededLocked() }
    }

    public func claim(uid: UInt32, lineageID: UUID) throws {
        try directory.withExclusiveLock {
            let ownership = try initializeIfNeededLocked()
            guard ownership == .unclaimed else { throw RootPolicyStoreError.mutationLocked }
            guard try fixedSlotStates().allSatisfy(\.isAbsent) else {
                throw RootPolicyStoreError.residualSlotsWhileUnclaimed
            }
            try writeOwnership(.owned(uid: uid, lineageID: lineageID, acceptedGenerationHighWater: 0))
        }
    }

    public func promote(_ artifact: PolicyArtifact) throws -> RecoveredPolicy {
        let payload = try artifact.decode()
        guard Self.isCompatibleWithCurrentExtension(payload) else {
            throw RootPolicyStoreError.incompatibleProtocol
        }
        return try directory.withExclusiveLock {
            switch try initializeIfNeededLocked() {
            case .owned(let uid, let lineageID, let highWater):
                return try promoteLocked(
                    artifact,
                    payload: payload,
                    ownership: (uid, lineageID, highWater)
                )
            case .replacingConfiguration(let oldUID, let targetLineageID):
                return try promoteConfigurationResetLocked(
                    artifact,
                    payload: payload,
                    oldUID: oldUID,
                    targetLineageID: targetLineageID
                )
            case .unclaimed, .resetting:
                throw RootPolicyStoreError.mutationLocked
            }
        }
    }

    public func recoverNewest() throws -> RecoveredPolicy {
        try directory.withExclusiveLock { try recoverNewestLocked() }
    }

    public func referencedExpiryKeys() throws -> Set<ExpiredRuleKey> {
        try directory.withExclusiveLock { try referencedExpiryKeysLocked() }
    }

    public func pruneExpiryTombstones(
        using tombstoneStore: ExpiryTombstoneStore
    ) throws -> Set<ExpiredRuleKey> {
        try directory.withExclusiveLock {
            guard tombstoneStore.rootURL.standardizedFileURL.path
                    == directory.url.standardizedFileURL.path else {
                throw ExpiryTombstoneStoreError.rootMismatch
            }
            return try tombstoneStore.pruneAssumingExclusiveRootLock(
                retaining: referencedExpiryKeysLocked()
            )
        }
    }

    public func ownership() throws -> RootOwnership {
        try directory.withExclusiveLock { try initializeIfNeededLocked() }
    }

    func initializeIfNeededLocked() throws -> RootOwnership {
        if let ownership = try readOwnershipPermittingReconstruction() {
            allowsFreshInitialization = false
            if ownership == .unclaimed,
               try !fixedSlotStates().allSatisfy(\.isAbsent) {
                throw RootPolicyStoreError.residualSlotsWhileUnclaimed
            }
            return ownership
        }
        guard allowsFreshInitialization else { throw RootPolicyStoreError.corruptOwnership }
        guard try fixedSlotStates().allSatisfy(\.isAbsent) else {
            throw RootPolicyStoreError.corruptOwnership
        }
        try writeOwnership(.unclaimed)
        allowsFreshInitialization = false
        return .unclaimed
    }

    private func promoteLocked(
        _ artifact: PolicyArtifact,
        payload: CompiledPolicyPayload,
        ownership: (uid: UInt32, lineageID: UUID, highWater: UInt64)
    ) throws -> RecoveredPolicy {
        guard ownership.uid == payload.authorizedUID else { throw RootPolicyStoreError.ownerMismatch }
        guard ownership.lineageID == payload.lineageID else { throw RootPolicyStoreError.lineageMismatch }

        let slots = try slotsBound(to: ownership, from: fixedSlotStates())
        let newest = try newestValidatedSlot(in: slots)
        let validatedHighWater = max(ownership.highWater, newest?.slot.generation ?? 0)
        if payload.generation < validatedHighWater { throw RootPolicyStoreError.staleGeneration }
        if payload.generation == validatedHighWater {
            guard let existing = slots.first(where: {
                $0.slot.generation == payload.generation && $0.slot.hash == artifact.hash
            }) else {
                throw RootPolicyStoreError.generationHashMismatch
            }
            try reconcileMetadata(for: existing, ownership: ownership)
            return recovered(existing, acknowledgementLost: false)
        }

        let targetName = newest?.name == Self.slotAName ? Self.slotBName : Self.slotAName
        let slot = PolicySlot(ownerUID: ownership.uid, artifact: artifact, payload: payload)
        try promotionFault?(.beforeSlotWrite(target: targetName))
        try directory.writeAtomically(try Self.encoder.encode(slot), to: targetName)
        try promotionFault?(.beforeSlotReopen(target: targetName))
        guard case .valid(let reopened) = try fixedSlotState(named: targetName),
              reopened.slot.hash == artifact.hash else {
            throw RootPolicyStoreError.corruptSlot
        }
        try writeIndex(for: reopened)
        try writeOwnership(.owned(
            uid: ownership.uid,
            lineageID: ownership.lineageID,
            acceptedGenerationHighWater: payload.generation
        ))
        return recovered(reopened, acknowledgementLost: false)
    }

    private func promoteConfigurationResetLocked(
        _ artifact: PolicyArtifact,
        payload: CompiledPolicyPayload,
        oldUID: UInt32,
        targetLineageID: UUID
    ) throws -> RecoveredPolicy {
        guard payload.authorizedUID == oldUID else { throw RootPolicyStoreError.ownerMismatch }
        guard payload.lineageID == targetLineageID else {
            throw RootPolicyStoreError.lineageMismatch
        }
        guard payload.generation == 1 else { throw RootPolicyStoreError.staleGeneration }
        guard try fixedSlotStates().allSatisfy(\.isAbsent) else {
            throw RootPolicyStoreError.mutationLocked
        }
        let slot = PolicySlot(ownerUID: oldUID, artifact: artifact, payload: payload)
        try promotionFault?(.beforeSlotWrite(target: Self.slotAName))
        try directory.writeAtomically(try Self.encoder.encode(slot), to: Self.slotAName)
        try promotionFault?(.beforeSlotReopen(target: Self.slotAName))
        guard case .valid(let reopened) = try fixedSlotState(named: Self.slotAName),
              reopened.slot.hash == artifact.hash else {
            throw RootPolicyStoreError.corruptSlot
        }
        try writeIndex(for: reopened)
        try writeOwnership(.owned(
            uid: oldUID,
            lineageID: targetLineageID,
            acceptedGenerationHighWater: 1
        ))
        return recovered(reopened, acknowledgementLost: false)
    }

    private func recoverNewestLocked() throws -> RecoveredPolicy {
        let ownership = try requireOwnedLocked()
        let candidates = try slotsBound(to: ownership, from: fixedSlotStates())
        guard let newest = try newestValidatedSlot(in: candidates) else {
            throw RootPolicyStoreError.noValidPolicy
        }
        let acknowledgementLost = newest.slot.generation > ownership.highWater
        if acknowledgementLost {
            try writeOwnership(.owned(
                uid: ownership.uid,
                lineageID: ownership.lineageID,
                acceptedGenerationHighWater: newest.slot.generation
            ))
        }
        try writeIndex(for: newest)
        return recovered(newest, acknowledgementLost: acknowledgementLost)
    }

    private func referencedExpiryKeysLocked() throws -> Set<ExpiredRuleKey> {
        let ownership = try requireOwnedLocked()
        let states = try fixedSlotStates()
        for case .corruptOrIncompatible in states {
            throw RootPolicyStoreError.corruptSlot
        }
        let slots = try slotsBound(to: ownership, from: states)
        guard try newestValidatedSlot(in: slots) != nil else {
            throw RootPolicyStoreError.noValidPolicy
        }
        return Set(slots.flatMap { $0.payload.rules.compactMap(\.expiryKey) })
    }

    private func requireOwnedLocked() throws -> (uid: UInt32, lineageID: UUID, highWater: UInt64) {
        switch try initializeIfNeededLocked() {
        case .owned(let uid, let lineageID, let highWater): return (uid, lineageID, highWater)
        case .unclaimed, .resetting, .replacingConfiguration:
            throw RootPolicyStoreError.mutationLocked
        }
    }

    private func readOwnershipPermittingReconstruction() throws -> RootOwnership? {
        do {
            guard let data = try directory.read(Self.ownershipName, maximumBytes: 16 * 1_024) else {
                return try reconstructOwnershipFromSlots()
            }
            return try Self.decoder.decode(OwnershipFile.self, from: data).validated()
        } catch let error as RootPolicyStoreError where error == .corruptOwnership {
            return try reconstructOwnershipFromSlots()
        } catch is DecodingError {
            return try reconstructOwnershipFromSlots()
        }
    }

    private func reconstructOwnershipFromSlots() throws -> RootOwnership? {
        let states = try fixedSlotStates()
        let slots = states.compactMap { state -> ValidatedSlot? in
            if case .valid(let slot) = state { return slot }
            return nil
        }
        guard let first = slots.first else { return nil }
        guard slots.allSatisfy({
            $0.slot.ownerUID == first.slot.ownerUID && $0.slot.lineageID == first.slot.lineageID
        }) else { throw RootPolicyStoreError.conflictingSlotOwners }
        let highWater = slots.map(\.slot.generation).max() ?? 0
        let reconstructed = RootOwnership.owned(
            uid: first.slot.ownerUID,
            lineageID: first.slot.lineageID,
            acceptedGenerationHighWater: highWater
        )
        try writeOwnership(reconstructed)
        return reconstructed
    }

    func fixedSlotStates() throws -> [FixedSlotState] {
        let states = [Self.slotAName, Self.slotBName].map { classifyFixedSlot(named: $0) }
        for case .operationalFailure(_, let error) in states { throw error }
        return states
    }

    private func fixedSlotState(named name: String) throws -> FixedSlotState {
        let state = classifyFixedSlot(named: name)
        if case .operationalFailure(_, let error) = state { throw error }
        return state
    }

    private func classifyFixedSlot(named name: String) -> FixedSlotState {
        let data: Data
        do {
            guard let stored = try directory.read(name, maximumBytes: Self.maximumSlotFileBytes) else {
                return .absent(name: name)
            }
            data = stored
        } catch let error as SecureDirectoryError {
            if case .oversizedFile = error {
                return .corruptOrIncompatible(name: name)
            }
            return .operationalFailure(name: name, error: error)
        } catch {
            return .operationalFailure(name: name, error: error)
        }
        do {
            let slot = try Self.decoder.decode(PolicySlot.self, from: data)
            let (artifact, payload) = try slot.validated()
            guard Self.isCompatibleWithCurrentExtension(payload) else {
                return .corruptOrIncompatible(name: name)
            }
            return .valid(ValidatedSlot(
                name: name,
                slot: slot,
                artifact: artifact,
                payload: payload
            ))
        } catch {
            return .corruptOrIncompatible(name: name)
        }
    }

    private func slotsBound(
        to ownership: (uid: UInt32, lineageID: UUID, highWater: UInt64),
        from states: [FixedSlotState]
    ) throws -> [ValidatedSlot] {
        let slots = states.compactMap { state -> ValidatedSlot? in
            if case .valid(let slot) = state { return slot }
            return nil
        }
        guard slots.allSatisfy({
            $0.slot.ownerUID == ownership.uid && $0.slot.lineageID == ownership.lineageID
        }) else { throw RootPolicyStoreError.conflictingSlotOwners }
        return slots
    }

    private func newestValidatedSlot(in slots: [ValidatedSlot]) throws -> ValidatedSlot? {
        guard let highestGeneration = slots.map(\.slot.generation).max() else { return nil }
        let newest = slots.filter { $0.slot.generation == highestGeneration }
        guard let expectedHash = newest.first?.slot.hash,
              newest.allSatisfy({ $0.slot.hash == expectedHash }) else {
            throw RootPolicyStoreError.generationHashMismatch
        }
        return newest.max { $0.name < $1.name }
    }

    private func reconcileMetadata(
        for slot: ValidatedSlot,
        ownership: (uid: UInt32, lineageID: UUID, highWater: UInt64)
    ) throws {
        try writeIndex(for: slot)
        if slot.slot.generation > ownership.highWater {
            try writeOwnership(.owned(
                uid: ownership.uid,
                lineageID: ownership.lineageID,
                acceptedGenerationHighWater: slot.slot.generation
            ))
        }
    }

    private func writeIndex(for slot: ValidatedSlot) throws {
        try directory.writeAtomically(try Self.encoder.encode(SlotIndex(
            schemaVersion: SlotIndex.schemaVersion,
            currentSlot: slot.name,
            generation: slot.slot.generation,
            hash: slot.slot.hash
        )), to: Self.slotIndexName)
    }

    func writeOwnership(_ ownership: RootOwnership) throws {
        try directory.writeAtomically(
            try Self.encoder.encode(OwnershipFile.make(ownership)),
            to: Self.ownershipName
        )
    }

    private func recovered(_ value: ValidatedSlot, acknowledgementLost: Bool) -> RecoveredPolicy {
        RecoveredPolicy(
            tuple: PolicyTuple(
                lineageID: value.slot.lineageID,
                generation: value.slot.generation,
                hash: value.slot.hash
            ),
            artifact: value.artifact,
            payload: value.payload,
            recoveredAfterLostAcknowledgement: acknowledgementLost
        )
    }

    private static func isCompatibleWithCurrentExtension(
        _ payload: CompiledPolicyPayload
    ) -> Bool {
        ProtocolVersion.current.supports(
            minimum: payload.compatibility.minimumExtensionProtocol
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
