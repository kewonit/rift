import RiftIPC
import AppKit
import Foundation
import SwiftUI

/// Shows a waiting connection: the oldest, unless another one was chosen. The
/// panel has no close button, because closing it would look like dismissing
/// the alert while the connection is quietly allowed at the deadline. It can
/// be minimized to a bar that still counts down.
@MainActor
final class PromptPanelController {
    static let shared = PromptPanelController()
    static let keepMinimizedKey = "alertsKeepMinimized"

    private var panel: NSPanel?
    private var host: NSHostingController<AnyView>?
    private var presentedNonce: UUID?
    private var presentedMinimized = false
    /// The connection picked from "more waiting", while it's still waiting.
    private var chosenNonce: UUID?
    private var minimized = false
    private var lastInput: (prompts: [PromptRequest], controller: ControlPlaneController, artworkStore: ApplicationArtworkStore)?
    /// Answers Block for a connection nobody answered, when Settings › Alerts
    /// says to.
    private var timeoutAnswers: [UUID: Task<Void, Never>] = [:]
    /// Connections the person is answering right now, which Rift leaves to
    /// them.
    var answering: Set<UUID> = []

    /// Whether the frontmost app has a window covering a whole screen. Reads
    /// only window sizes and owners, which needs no permission.
    static func frontmostAppIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return screens.contains { abs($0.width - rect.width) < 1 && abs($0.height - rect.height) < 1 }
        }
    }

    func update(
        prompts: [PromptRequest],
        controller: ControlPlaneController,
        artworkStore: ApplicationArtworkStore
    ) {
        lastInput = (prompts, controller, artworkStore)
        scheduleTimeoutAnswers(prompts, controller: controller)
        guard let first = prompts.first else {
            closePanel()
            chosenNonce = nil
            minimized = false
            return
        }
        let next = prompts.first { $0.nonce == chosenNonce } ?? first
        if next.nonce != chosenNonce { chosenNonce = nil }
        // A new alert after none were waiting opens the way the person chose.
        // Over a full-screen app it arrives as the small bar, so it doesn't
        // interrupt whatever is on screen.
        if panel == nil {
            minimized = UserDefaults.standard.bool(forKey: Self.keepMinimizedKey) || Self.frontmostAppIsFullScreen()
        }
        let others = prompts.filter { $0.nonce != next.nonce }
        let view: AnyView
        if minimized {
            view = AnyView(ConnectionAlertMinimizedView(
                prompt: next, others: others, controller: controller, artworkStore: artworkStore,
                expand: { [weak self] in self?.setMinimized(false) },
                choose: { [weak self] nonce in self?.choose(nonce, expand: true) }
            ))
        } else {
            view = AnyView(ConnectionAlertView(
                prompt: next,
                moreWaiting: others.count,
                others: others,
                choose: { [weak self] nonce in self?.choose(nonce, expand: false) },
                minimize: { [weak self] in self?.setMinimized(true) },
                controller: controller,
                artworkStore: artworkStore
            )
            // A new identity for each connection, so choices made for one
            // never carry over to the next.
            .id(next.nonce))
        }
        if presentedNonce == next.nonce, presentedMinimized == minimized, let host {
            host.rootView = view
            return
        }
        if minimized, presentedMinimized, let host {
            // The bar stays where it is while the waiting connection changes.
            host.rootView = view
            presentedNonce = next.nonce
            return
        }
        closePanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: minimized ? 380 : 540, height: minimized ? 80 : 500),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = minimized ? "Rift: Connection Waiting" : "Rift Connection Alert"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        if minimized {
            place(panel, nearTopRightOf: NSScreen.main)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
        presentedNonce = next.nonce
        presentedMinimized = minimized
    }

    /// Shows the whole alert, from the menu bar's Review Waiting Connections.
    func bringForward() {
        if minimized { setMinimized(false) }
        panel?.orderFrontRegardless()
    }

    private func setMinimized(_ value: Bool) {
        guard minimized != value else { return }
        minimized = value
        refresh()
    }

    private func choose(_ nonce: UUID, expand: Bool) {
        chosenNonce = nonce
        if expand { minimized = false }
        refresh()
    }

    private func refresh() {
        guard let lastInput else { return }
        update(prompts: lastInput.prompts, controller: lastInput.controller, artworkStore: lastInput.artworkStore)
    }

    private func scheduleTimeoutAnswers(_ prompts: [PromptRequest], controller: ControlPlaneController) {
        let waiting = Set(prompts.map(\.nonce))
        for (nonce, task) in timeoutAnswers where !waiting.contains(nonce) {
            task.cancel()
            timeoutAnswers.removeValue(forKey: nonce)
        }
        answering.formIntersection(waiting)
        for prompt in prompts where timeoutAnswers[prompt.nonce] == nil {
            timeoutAnswers[prompt.nonce] = Task { [weak self, weak controller] in
                let wait = prompt.deadline.timeIntervalSinceNow - ConnectionAlertCountdown.blockLead
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, ConnectionAlertCountdown.blocksUnanswered,
                      prompt.deadline > Date(), let controller,
                      self?.answering.contains(prompt.nonce) != true else { return }
                do {
                    try await controller.answerOnce(prompt, action: .deny)
                } catch {
                    // Unless the connection was answered meanwhile, say that
                    // it's going to be allowed after all.
                    guard controller.pendingPrompts.contains(where: { $0.nonce == prompt.nonce }) else { return }
                    controller.actionResults.post(
                        "Rift couldn’t block a connection you didn’t answer, so it will be allowed.",
                        tone: .failure
                    )
                }
            }
        }
    }

    private func place(_ panel: NSPanel, nearTopRightOf screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 16,
            y: frame.maxY - size.height - 16
        ))
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        host = nil
        presentedNonce = nil
    }
}
