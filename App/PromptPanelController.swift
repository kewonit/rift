import RiftIPC
import AppKit
import Foundation
import SwiftUI

/// Shows the oldest waiting connection. The panel has no close button, because
/// closing it would look like dismissing the alert while the connection is
/// quietly allowed at the deadline.
@MainActor
final class PromptPanelController {
    static let shared = PromptPanelController()

    private var panel: NSPanel?
    private var host: NSHostingController<ConnectionAlertView>?
    private var presentedNonce: UUID?

    func update(
        prompts: [PromptRequest],
        controller: ControlPlaneController,
        artworkStore: ApplicationArtworkStore
    ) {
        guard let next = prompts.first else {
            closePanel()
            return
        }
        let view = ConnectionAlertView(
            prompt: next,
            moreWaiting: prompts.count - 1,
            controller: controller,
            artworkStore: artworkStore
        )
        if presentedNonce == next.nonce, let host {
            host.rootView = view
            return
        }
        closePanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Rift Connection Alert"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
        presentedNonce = next.nonce
    }

    func bringForward() {
        panel?.orderFrontRegardless()
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        host = nil
        presentedNonce = nil
    }
}
