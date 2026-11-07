import RiftControl
import RiftCore
import SwiftUI

/// What the Map page offers the menu bar, so everything it can do has a menu
/// item and a shortcut someone can find.
struct MapCommandActions {
    let tableShown: Bool
    let inspectorShown: Bool
    let timelineShown: Bool
    let toggleTable: () -> Void
    let toggleInspector: () -> Void
    let toggleTimeline: () -> Void
    let find: () -> Void
    /// Nil when the selection can't be decided.
    let decide: ((FilterAction) -> Void)?
    let showRule: (() -> Void)?
}

private struct MapCommandActionsKey: FocusedValueKey {
    typealias Value = MapCommandActions
}

extension FocusedValues {
    var mapCommands: MapCommandActions? {
        get { self[MapCommandActionsKey.self] }
        set { self[MapCommandActionsKey.self] = newValue }
    }
}

struct MapCommands: Commands {
    @FocusedValue(\.mapCommands) private var actions

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(actions?.tableShown == true ? "Show Map" : "Show Connection Table") {
                actions?.toggleTable()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions == nil)
            Button(actions?.inspectorShown == true ? "Hide Inspector" : "Show Inspector") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions == nil)
            Button(actions?.timelineShown == true ? "Hide Timeline" : "Show Timeline") {
                actions?.toggleTimeline()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(actions == nil)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Find Connections") { actions?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandMenu("Connection") {
            Button("Allow…") { actions?.decide?(.allow) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions?.decide == nil)
            Button("Block…") { actions?.decide?(.deny) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.decide == nil)
            Divider()
            Button("Show Rule") { actions?.showRule?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.showRule == nil)
        }
    }
}
