import AppKit
import OSLog
import RiftControl
import SwiftUI

enum ActivityPerformance {
    static let signposter = OSSignposter(subsystem: "io.rift.firewall", category: "PointsOfInterest")
}

struct ActivityRefreshSignal: ViewModifier {
    let controller: ControlPlaneController
    let changed: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: controller.visualActivityRevision) { _, _ in changed() }
    }
}

/// SwiftUI disappearance does not cover minimization, hiding or window occlusion.
struct ActivityWindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }

    @MainActor
    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(updateVisibility), name: name, object: window
                )
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(updateVisibility), name: name, object: nil
                )
            }
            updateVisibility()
        }

        @objc private func updateVisibility() {
            let visible = window.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                    && !NSApplication.shared.isHidden
            } ?? false
            guard visible != lastValue else { return }
            lastValue = visible
            // Updating SwiftUI state during view attachment must happen on the next run loop.
            Task { @MainActor [weak self] in self?.changed?(visible) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct ActivityPresentation: Sendable {
    let evaluation: MonitorQueryEvaluation
    let hierarchy: [MonitorHierarchyNode]
    let rowLookup: [String: MonitorEventRow]
    let traffic: LiveTrafficSnapshot
    let decisions: DecisionBucketSnapshot

    static func build(
        evaluation: MonitorQueryEvaluation,
        rows: [MonitorEventRow],
        query: MonitorQueryState,
        now: Date,
        coverage: HistoryCoverageSnapshot = .unavailable,
        isComplete: Bool = true,
        coverages: [String: MonitorRuleCoverage],
        visibleLimit: Int,
        pinnedID: String? = nil
    ) async throws -> ActivityPresentation {
        try await MonitorQueryWorker.run(priority: .utility) {
            try Task.checkCancellation()
            var visible = Array(evaluation.displayed.prefix(visibleLimit))
            if let pinnedID, !visible.contains(where: { $0.id == pinnedID }),
               let pinned = evaluation.displayed.first(where: { $0.id == pinnedID }) {
                visible.append(pinned)
            }
            let hierarchy = MonitorHierarchyBuilder.build(visible, lens: query.lens, coverages: coverages)
            try Task.checkCancellation()
            let displayedRows = evaluation.displayed.map(\.source)
            let bounds = query.effectiveTimeWindow(now: now)?.resolvedBounds(
                defaultStart: displayedRows.map(\.event.occurredAt).min() ?? now,
                defaultEnd: now.addingTimeInterval(0.001)
            )
            let traffic = LiveTrafficSnapshot.make(rows: displayedRows, bounds: bounds)
            try Task.checkCancellation()
            return ActivityPresentation(
                evaluation: evaluation, hierarchy: hierarchy,
                rowLookup: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
                traffic: traffic,
                decisions: MonitorDecisionBuckets.build(
                    rows: rows, query: query, now: now, coverage: coverage, isComplete: isComplete
                )
            )
        }
    }
}
