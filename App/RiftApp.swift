import RiftControl
import AppKit
import SwiftUI

@main
struct RiftApp: App {
    @NSApplicationDelegateAdaptor(RiftApplicationDelegate.self)
    private var applicationDelegate
    private let startup = AppStartupCoordinator.shared

    var body: some Scene {
        Window("Rift", id: "main") {
            if let session = startup.session {
                MonitorView(session: session)
            }
        }
        .defaultSize(width: 1_280, height: 679)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        Window("Rules", id: "rules") {
            if let session = startup.session {
                RulesWorkspaceView(
                    controlPlane: session.controlPlane,
                    requestedSelection: Binding(
                        get: { session.requestedRuleIDs },
                        set: { session.requestedRuleIDs = $0 }
                    ),
                    artworkStore: session.applicationArtwork,
                    isPreview: session.isUIFixture
                )
                .frame(minWidth: 880, minHeight: 560)
            }
        }
        .defaultSize(width: 1_080, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            RuleWorkspaceCommands()
        }

        MenuBarExtra {
            if let session = startup.session {
                StatusMenuView(session: session)
            }
        } label: {
            if let session = startup.session {
                Image(systemName: session.statusSymbolName)
                    .accessibilityLabel(
                        session.isUIFixture
                            ? "Rift preview"
                            : session.statusAccessibilityLabel
                    )
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let session = startup.session {
                SettingsView(
                    controlPlane: session.controlPlane,
                    geolocation: session.geolocation,
                    lifecycle: session.lifecycle,
                    isPreview: session.isUIFixture
                )
            }
        }
        .defaultSize(width: 760, height: 500)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class RiftApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppStartupCoordinator.shared.applicationWillFinishLaunching()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStartupCoordinator.shared.applicationDidFinishLaunching()
    }
}

@MainActor
private final class AppStartupCoordinator {
    private enum Admission {
#if DEBUG
        case fixture
#endif
        case live(ProcessInstanceLock)
        case terminate
    }

    static let shared = AppStartupCoordinator()

    let session: AppSession?
    private let admission: Admission

    private init() {
#if DEBUG
        if AppLaunchMode.current == .uiFixture {
            admission = .fixture
            session = AppSession(launchMode: .uiFixture)
            return
        }
#endif
        let admission = Self.liveAdmission()
        self.admission = admission
        switch admission {
        case .live:
#if DEBUG
            session = AppSession(launchMode: .live)
#else
            session = AppSession()
#endif
        case .terminate:
            session = nil
#if DEBUG
        case .fixture:
            preconditionFailure("Fixture admission returns before live startup")
#endif
        }
    }

    func applicationWillFinishLaunching() {
        guard case .terminate = admission else { return }
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching() {
        guard case .terminate = admission else { return }
        activateExistingApplication()
        NSApplication.shared.terminate(nil)
    }

    private static func liveAdmission() -> Admission {
        do {
            switch try ProcessInstanceLock.acquire(in: instanceLockDirectory()) {
            case .acquired(let lock): return .live(lock)
            case .unavailable: return .terminate
            }
        } catch {
            return .terminate
        }
    }

    private static func instanceLockDirectory() throws -> URL {
        guard let identifier = Bundle.main.bundleIdentifier,
              !identifier.isEmpty, !identifier.contains("/") else {
            throw StartupError.invalidBundleIdentifier
        }
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let domain = applicationSupport.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: domain,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return domain.appendingPathComponent("Process Lock", isDirectory: true)
    }

    private func activateExistingApplication() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let currentProcess = ProcessInfo.processInfo.processIdentifier
        let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: identifier
        ).first { candidate in
            candidate.processIdentifier != currentProcess && !candidate.isTerminated
        }
        _ = application?.activate(options: [.activateAllWindows])
    }
}

private enum StartupError: Error {
    case invalidBundleIdentifier
}
