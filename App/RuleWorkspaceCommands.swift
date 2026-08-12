import SwiftUI

struct RuleWorkspaceHistoryAction {
    let title: String
    let isRedo: Bool
    let isEnabled: Bool
    let perform: () -> Void

    var canUndo: Bool { isEnabled && !isRedo }
    var canRedo: Bool { isEnabled && isRedo }
}

private struct RuleWorkspaceHistoryActionKey: FocusedValueKey {
    typealias Value = RuleWorkspaceHistoryAction
}

extension FocusedValues {
    var ruleWorkspaceHistoryAction: RuleWorkspaceHistoryAction? {
        get { self[RuleWorkspaceHistoryActionKey.self] }
        set { self[RuleWorkspaceHistoryActionKey.self] = newValue }
    }
}

struct RuleWorkspaceCommands: Commands {
    @FocusedValue(\.ruleWorkspaceHistoryAction)
    private var historyAction

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Divider()
            Button(undoTitle) {
                historyAction?.perform()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!(historyAction?.canUndo ?? false))

            Button(redoTitle) {
                historyAction?.perform()
            }
            .keyboardShortcut("z", modifiers: [.command, .option, .shift])
            .disabled(!(historyAction?.canRedo ?? false))
        }
    }

    private var undoTitle: String {
        guard let historyAction, historyAction.canUndo else { return "Undo Rule Change" }
        return historyAction.title
    }

    private var redoTitle: String {
        guard let historyAction, historyAction.canRedo else { return "Redo Rule Change" }
        return historyAction.title
    }
}
