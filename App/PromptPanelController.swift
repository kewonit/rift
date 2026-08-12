import AbyssIPC
import AppKit
import Foundation
import SwiftUI

@MainActor
final class PromptPanelController: NSObject, NSWindowDelegate {
    static let shared = PromptPanelController()

    private var panel: NSPanel?
    private var presentedNonce: UUID?

    func update(
        prompts: [PromptRequest],
        controller: ControlPlaneController,
        artworkStore: ApplicationArtworkStore
    ) {
        guard let next = prompts.first else {
            panel?.close()
            panel = nil
            presentedNonce = nil
            return
        }
        guard presentedNonce != next.nonce else { return }
        panel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Abyss Connection Alert"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: ConnectionAlertView(
                prompt: next,
                controller: controller,
                artworkStore: artworkStore
            )
        )
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
        presentedNonce = next.nonce
    }

    func dismiss() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        presentedNonce = nil
    }
}
