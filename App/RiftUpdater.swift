import AppKit
import Combine
import Sparkle
import SwiftUI

/// Keeps Rift current with Sparkle. It checks GitHub once a day and installs an
/// update only when it carries Rift's update signature and a Developer ID
/// signature from the same team as this copy. The new copy updates the network
/// filter itself when it opens.
@MainActor
final class RiftUpdater: NSObject, ObservableObject, @preconcurrency SPUUpdaterDelegate {
    /// Nil in builds that can't update, such as Debug builds.
    private(set) static var shared: RiftUpdater?

    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var windowObservers: [NSObjectProtocol] = []

    static func start() {
        guard shared == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let updater = RiftUpdater()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: updater, userDriverDelegate: nil
        )
        updater.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &updater.$canCheckForUpdates)
        shared = updater
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    // Rift often runs for days from the menu bar, so it doesn't wait for a quit
    // that may never come: it installs once no Rift window is open. Sparkle
    // calls its delegate on the main thread.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        pendingInstall = immediateInstallHandler
        if windowObservers.isEmpty {
            for name in [NSWindow.willCloseNotification, NSApplication.didHideNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    // A closing window still counts as open until it's gone.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.installIfNoWindowIsOpen() }
                    }
                })
            }
        }
        installIfNoWindowIsOpen()
        return true
    }

    private func installIfNoWindowIsOpen() {
        let windowOpen = !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        guard let pendingInstall, !windowOpen else { return }
        self.pendingInstall = nil
        pendingInstall()
    }
}

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updater = RiftUpdater.shared {
                CheckForUpdatesButton(updater: updater)
            }
        }
    }
}

private struct CheckForUpdatesButton: View {
    @ObservedObject var updater: RiftUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject var updater: RiftUpdater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            Toggle("Install updates automatically", isOn: $updater.installsAutomatically)
                .disabled(!updater.checksAutomatically)
            LabeledContent("Version", value: Self.version)
            Button("Check Now", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        } header: {
            Text("Updates")
        } footer: {
            Text("Rift checks GitHub once a day, which shares your IP address and Rift’s version with GitHub. An update installs only if Rift’s developer signed it.")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
