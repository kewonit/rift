import RiftControl
import RiftCore
import RiftIPC
import Foundation
import UserNotifications

actor NotificationRouter {
    private let clock = ContinuousClock()
    private let clockOrigin: ContinuousClock.Instant
    private var limiter = NotificationRateLimiter()
    private var summaryTask: Task<Void, Never>?
    private(set) var deliveryFailureCount: UInt64 = 0

    init() {
        clockOrigin = ContinuousClock().now
    }

    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func route(_ events: [RuntimeEvent]) async {
        guard notificationsEnabled else { cancelSummary(); return }
        let blocked = NotificationKinds.isOn(.blocked)
        let undecided = NotificationKinds.isOn(.undecided)
        for event in events where event.kind == .decision
            && !event.notificationRequested
            && ((event.action == .deny && blocked) || (event.reason != .concreteDecision && undecided)) {
            guard limiter.admit(at: monotonicTime) else { continue }
            let content = UNMutableNotificationContent()
            content.title = NotificationCopy.title(action: event.action)
            content.body = NotificationCopy.body(destination: destination(event.flow))
            var info: [String: Any] = [NotificationResponder.rowIDKey: MonitorEventRow(event: event, coverage: .complete).id]
            // A connection no rule decided gets Allow and Block buttons.
            if event.reason != .concreteDecision,
               event.flow.sourceAppIdentity ?? event.flow.sourceProcessIdentity != nil,
               let data = NotificationActions.encode(event) {
                content.categoryIdentifier = NotificationActions.undecidedCategory
                info[NotificationActions.eventKey] = data
            }
            content.userInfo = info
            await deliver(
                UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            )
        }
        scheduleSummaryIfNeeded()
    }

    func route(_ events: [EphemeralNotificationEvent]) async {
        guard notificationsEnabled else { cancelSummary(); return }
        guard NotificationKinds.isOn(.ruleMatches) else { return }
        let sound = NotificationKinds.isOn(.ruleSound)
        for event in events {
            guard limiter.admit(at: monotonicTime) else { continue }
            let content = UNMutableNotificationContent()
            content.title = NotificationCopy.title(action: event.action)
            content.body = NotificationCopy.body(destination: destination(event.flow))
            if sound { content.sound = .default }
            await deliver(
                UNNotificationRequest(
                    identifier: "rift-notify-\(event.id.uuidString.lowercased())",
                    content: content,
                    trigger: nil
                )
            )
        }
        scheduleSummaryIfNeeded()
    }

    /// Destinations appear only when the person has asked for them.
    private func destination(_ flow: FlowDescriptor) -> String? {
        guard UserDefaults.standard.bool(forKey: "notificationSensitiveDetails"),
              let endpoint = flow.destinationEndpoint else { return nil }
        return endpoint.hostname?.ascii ?? endpoint.address.description
    }

    func healthMessage() -> String? {
        deliveryFailureCount == 0 ? nil : "Some notifications couldn’t be shown."
    }

    private var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    private var monotonicTime: TimeInterval {
        let value = clockOrigin.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1_000_000_000_000_000_000
    }

    private func scheduleSummaryIfNeeded() {
        guard summaryTask == nil, let delay = limiter.summaryDelay(at: monotonicTime) else { return }
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.deliverSummary()
        }
    }

    private func deliverSummary() async {
        summaryTask = nil
        guard notificationsEnabled else { limiter.discardSummary(); return }
        guard let count = limiter.takeSummary(at: monotonicTime) else {
            scheduleSummaryIfNeeded()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Rift connection summary"
        content.body = NotificationCopy.summary(count: count)
        await deliver(UNNotificationRequest(
            identifier: "rift-summary-\(UUID().uuidString.lowercased())",
            content: content,
            trigger: nil
        ))
        scheduleSummaryIfNeeded()
    }

    private func deliver(_ request: UNNotificationRequest) async {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            if deliveryFailureCount < .max { deliveryFailureCount += 1 }
        }
    }

    private func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        limiter.discardSummary()
    }
}

private extension RuntimeEvent {
    var id: String { "rift-\(providerEpoch.uuidString)-\(sequence)" }
}

/// Which connections notify, each with its own switch in Settings › Alerts.
/// A switch nobody has touched is on, except the sound.
enum NotificationKinds: String, CaseIterable {
    case blocked = "notifyBlockedConnections"
    case undecided = "notifyUndecidedConnections"
    case ruleMatches = "notifyRuleMatches"
    case ruleSound = "notifyRuleMatchesSound"

    static func isOn(_ kind: NotificationKinds) -> Bool {
        UserDefaults.standard.object(forKey: kind.rawValue) as? Bool ?? (kind != .ruleSound)
    }
}
