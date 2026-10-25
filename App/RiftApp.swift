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
                RiftRootView(session: session)
            }
        }
        .defaultSize(width: 1_360, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            if let session = startup.session {
                RiftNavigationCommands(session: session)
            }
            RuleWorkspaceCommands()
        }

        Settings {
            if let session = startup.session {
                SettingsView(
                    controlPlane: session.controlPlane,
                    lifecycle: session.lifecycle,
                    isPreview: session.isUIFixture
                )
            }
        }

        MenuBarExtra {
            if let session = startup.session {
                StatusMenuView(session: session)
            }
        } label: {
            if let session = startup.session {
                RiftStatusIcon(session: session)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct RiftStatusIcon: View {
    let session: AppSession
    private static let images: [String: NSImage] = {
        let names = ["eye", "shield.slash", "exclamationmark.shield", "xmark.shield.fill",
                     "questionmark.shield", "checkmark.shield", "xmark.shield"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(symbol.size.width * 2),
                    pixelsHigh: Int(symbol.size.height * 2), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                  ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            bitmap.size = symbol.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: symbol.size)
            image.addRepresentation(bitmap)
            image.isTemplate = true
            return (name, image)
        })
    }()

    var body: some View {
        statusImage
            .accessibilityLabel(
                session.isUIFixture
                    ? "Rift preview"
                    : session.statusAccessibilityLabel
            )
    }

    private var statusImage: Image {
        if let image = Self.images[session.statusSymbolName] { return Image(nsImage: image) }
        return Image(systemName: session.statusSymbolName)
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
