import RiftControl
import SwiftUI

/// Undo for rule changes, from anywhere in the app. It keeps its own shortcut
/// because the standard Undo belongs to text fields, such as a rule's note.
struct RuleWorkspaceCommands: Commands {
    let session: AppSession

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Divider()
            Button(canUndo ? session.controlPlane.ruleChanges.title : "Undo Rule Change") {
                session.undoRuleChange()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!canUndo)
            Button(canRedo ? session.controlPlane.ruleChanges.title : "Redo Rule Change") {
                session.undoRuleChange()
            }
            .keyboardShortcut("z", modifiers: [.command, .option, .shift])
            .disabled(!canRedo)
        }
    }

    private var canUndo: Bool {
        session.controlPlane.canUndoRuleChange && !session.controlPlane.ruleChanges.isRedo
    }

    private var canRedo: Bool {
        session.controlPlane.canUndoRuleChange && session.controlPlane.ruleChanges.isRedo
    }
}
