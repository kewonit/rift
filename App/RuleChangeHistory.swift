import Foundation
import Observation
import RiftControl
import RiftCore

/// The last rule change and how to reverse it, shared by the Map, alerts and
/// the Rules page. It holds one step, because an undo only applies to the exact
/// rules it was made from.
@MainActor
@Observable
final class RuleChangeHistory {
    private(set) var plan: RuleWorkspaceUndoPlan?
    private(set) var name = ""
    private(set) var isRedo = false
    /// Changes when rules change, so views showing rule state can refresh.
    private(set) var revision = 0
    var isRunning = false
    @ObservationIgnored var nextChangeName: String?

    var title: String { "\(isRedo ? "Redo" : "Undo") \(name)" }

    func record(before: [Rule], after: [Rule], generation: UInt64, isRedo: Bool) {
        revision += 1
        let changeName = nextChangeName ?? "Rule Change"
        nextChangeName = nil
        guard let plan = try? RuleWorkspaceUndoPlan(
            beforeMutation: before,
            afterMutation: after,
            expectedGeneration: generation
        ) else {
            clear()
            return
        }
        self.plan = plan
        name = changeName
        self.isRedo = isRedo
    }

    func clear() {
        plan = nil
        name = ""
        isRedo = false
    }

    func noteChange() { revision += 1 }
}
