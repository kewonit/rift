import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Ways into Rift that don't depend on the menu-bar icon, which can be
/// hidden by other apps or by the notch: a Dock menu and an optional global
/// shortcut. Both open pages through Rift's own `rift://` links.
@MainActor
enum QuickAccess {
    static func open(_ page: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let url = URL(string: "rift://\(page)") { NSWorkspace.shared.open(url) }
    }

    static func dockMenu(review: ReviewQueueModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(DockMenuItem("Map") { open("map") })
        menu.addItem(DockMenuItem("Rules") { open("rules") })
        let count = review.count
        menu.addItem(DockMenuItem(count > 0 ? "Review (\(count))…" : "Review…") {
            review.isPresented = true
            open("map")
        })
        menu.addItem(.separator())
        menu.addItem(DockMenuItem("Settings…") { open("settings") })
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
private final class DockMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runClosure() {
        run()
    }
}

/// ⌃⌥⌘R shows the Map from anywhere, when turned on in Settings › General.
/// A Carbon hot key needs no Accessibility permission and sees no other keys.
@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()
    static let storageKey = "globalShortcutEnabled"
    static let label = "⌃⌥⌘R"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func applyStoredSetting() {
        setEnabled(UserDefaults.standard.bool(forKey: Self.storageKey))
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickAccess.open("map") } }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5249_4654), id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

/// The Settings › General toggle for the global shortcut.
struct GlobalShortcutToggle: View {
    @AppStorage(GlobalShortcut.storageKey) private var enabled = false

    var body: some View {
        Toggle("Show the Map with \(GlobalShortcut.label) from any app", isOn: $enabled)
            .onChange(of: enabled) { _, value in GlobalShortcut.shared.setEnabled(value) }
    }
}
