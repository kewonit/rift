import Foundation
import Network
import Observation
import RiftControl

/// Checks every half minute whether the filter has gone quiet: ready and
/// listened to, with the network up, yet no connection for a while. It shows
/// as a problem in the Status page, the menu bar, the Map and `riftctl
/// status`, and never as a notification.
@MainActor
@Observable
final class FilterLivenessMonitor {
    private(set) var isSilent = false

    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkUpSince: Date?
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start(controlPlane: ControlPlaneController) {
        guard loop == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.networkUpSince = satisfied ? (self.networkUpSince ?? Date()) : nil
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        loop = Task { [weak self, weak controlPlane] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let controlPlane else { return }
                self.evaluate(controlPlane)
            }
        }
    }

    private func evaluate(_ controlPlane: ControlPlaneController) {
        let now = Date()
        let ready: Bool
        if case .connected(.ready) = controlPlane.state { ready = true } else { ready = false }
        // Connections reach the app only while history records them or an
        // activity view is open.
        let listening = ready && controlPlane.currentMode != .filterOff
            && (controlPlane.persistentHistoryEnabled || controlPlane.desiredActivitySubscription.mode != .off)
        listeningSince = listening ? (listeningSince ?? now) : nil
        let silent = FilterLiveness.isSilent(
            now: now,
            lastFlowAt: controlPlane.lastFlowEventAt,
            listeningSince: listeningSince,
            networkUpSince: networkUpSince
        )
        if silent != isSilent { isSilent = silent }
    }
}
