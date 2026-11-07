import RiftControl
import RiftCore
import SwiftUI

/// What the Map page offers the menu bar, so everything it can do has a menu
/// item and a shortcut someone can find.
struct MapCommandActions {
    let mapHidden: Bool
    let inspectorShown: Bool
    let timelineShown: Bool
    let toggleMap: () -> Void
    let hideInspector: () -> Void
    let toggleTimeline: () -> Void
    let find: () -> Void
    /// Nil when the selection can't be decided.
    let decide: ((FilterAction) -> Void)?
    let showRule: (() -> Void)?
}

private struct MapCommandActionsKey: FocusedValueKey {
    typealias Value = MapCommandActions
}

private struct FindRulesKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var mapCommands: MapCommandActions? {
        get { self[MapCommandActionsKey.self] }
        set { self[MapCommandActionsKey.self] = newValue }
    }

    var findRules: (() -> Void)? {
        get { self[FindRulesKey.self] }
        set { self[FindRulesKey.self] = newValue }
    }
}

struct MapCommands: Commands {
    @FocusedValue(\.mapCommands) private var actions
    @FocusedValue(\.findRules) private var findRules

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(actions?.mapHidden == true ? "Show Map" : "Hide Map") {
                actions?.toggleMap()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions == nil)
            Button("Hide Inspector") { actions?.hideInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.inspectorShown != true)
            Button(actions?.timelineShown == true ? "Hide Timeline" : "Show Timeline") {
                actions?.toggleTimeline()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(actions == nil)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button(findRules == nil ? "Find Connections" : "Find Rules") {
                if let findRules { findRules() } else { actions?.find() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil && findRules == nil)
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
