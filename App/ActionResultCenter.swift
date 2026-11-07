import Foundation
import Observation
import SwiftUI

/// What the last rule action did, shown once wherever the person is working.
@MainActor
@Observable
final class ActionResultCenter {
    struct Result: Identifiable, Equatable {
        enum Tone { case success, pending, failure }
        let id = UUID()
        let message: String
        let tone: Tone
        let ruleIDs: Set<UUID>
        let offersUndo: Bool
    }

    private(set) var current: Result?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    func post(
        _ message: String,
        tone: Result.Tone = .success,
        ruleIDs: Set<UUID> = [],
        offersUndo: Bool = false
    ) {
        let result = Result(message: message, tone: tone, ruleIDs: ruleIDs, offersUndo: offersUndo)
        current = result
        AccessibilityNotification.Announcement(message).post()
        clearTask?.cancel()
        // Something that still needs attention stays until it's dismissed.
        guard tone == .success else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.current?.id == result.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        clearTask?.cancel()
        current = nil
    }
}

/// Shows the last action's result above everything else in the main window.
struct ActionResultBanner: View {
    @Bindable var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controller: ControlPlaneController { session.controlPlane }
    private var center: ActionResultCenter { controller.actionResults }

    var body: some View {
        ZStack {
            if let result = center.current {
                RiftBanner(message: result.message, tone: tone(result)) {
                    if result.offersUndo, controller.canUndoRuleChange {
                        Button(controller.ruleChanges.isRedo ? "Redo" : "Undo", action: undo)
                            .controlSize(.small)
                    }
                    if !result.ruleIDs.isEmpty {
                        Button("View Rule") { viewRules(result.ruleIDs) }
                            .controlSize(.small)
                    }
                    Button { center.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
                .frame(maxWidth: 560)
                .riftPanel(cornerRadius: RiftDesign.Radius.card)
                .padding(.bottom, RiftDesign.Spacing.l)
                .transition(RiftDesign.Motion.slide(fromY: RiftDesign.Motion.travel, reduceMotion: reduceMotion))
                .id(result.id)
            }
        }
    }

    private func tone(_ result: ActionResultCenter.Result) -> RiftBannerTone {
        switch result.tone {
        case .success: .info
        case .pending: .warning
        case .failure: .error
        }
    }

    private func viewRules(_ ids: Set<UUID>) {
        session.requestedRuleIDs = ids
        session.destination = .rules
        center.dismiss()
    }

    private func undo() {
        let wasRedo = controller.ruleChanges.isRedo
        Task { @MainActor in
            do {
                let result = try await controller.undoLastRuleChange()
                center.post(
                    result?.requiresAttention == true ? result?.message ?? "" : (wasRedo ? "Redone." : "Undone."),
                    tone: result?.requiresAttention == true ? .pending : .success,
                    offersUndo: true
                )
            } catch {
                center.post("Couldn’t undo because your rules changed.", tone: .failure)
            }
        }
    }
}
