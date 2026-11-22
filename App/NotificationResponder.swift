import AppKit
import RiftControl
import RiftCore
import Foundation
import UserNotifications

/// Takes a click on a notification to the Map, and to the connection itself
/// when it's still there.
@MainActor
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let rowIDKey = "rowID"
    private weak var session: AppSession?

    init(session: AppSession) {
        self.session = session
        super.init()
        NotificationActions.register()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let rowID = userInfo[Self.rowIDKey] as? String
        let opensReview = userInfo[ReviewQueueModel.notificationKey] as? Bool == true
        let action = response.actionIdentifier
        let eventData = userInfo[NotificationActions.eventKey] as? Data
        let network = userInfo[NotificationActions.networkKey] as? String
        completionHandler()
        switch action {
        case NotificationActions.allow, NotificationActions.block:
            Task { @MainActor [weak self] in
                await self?.decide(action == NotificationActions.allow ? .allow : .deny, eventData: eventData)
            }
            return
        case NotificationActions.useCurrentProfile:
            guard let network else { return }
            Task { @MainActor in await NetworkProfileSwitcher.shared.useActiveProfile(for: network) }
            return
        case NotificationActions.chooseProfile:
            Task { @MainActor in
                UserDefaults.standard.set(SettingsSection.networks.rawValue, forKey: "settingsSection")
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let url = URL(string: "rift://settings") { NSWorkspace.shared.open(url) }
            }
            return
        default:
            break
        }
        Task { @MainActor [weak self] in
            self?.session?.requestedMonitorEventID = rowID
            self?.session?.destination = .liveMap
            if opensReview { self?.session?.review.isPresented = true }
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let url = URL(string: "rift://map") { NSWorkspace.shared.open(url) }
        }
    }

    /// Makes a lasting rule for the notified connection's destination.
    private func decide(_ action: FilterAction, eventData: Data?) async {
        guard let session, let event = NotificationActions.event(from: eventData),
              let identity = event.flow.sourceAppIdentity ?? event.flow.sourceProcessIdentity else { return }
        let name = await session.applicationArtwork.artwork(for: identity)?.displayName
            ?? MonitorQuery.identityLabel(identity)
        session.review.decide(
            action, destinationOf: MonitorEventRow(event: event, coverage: .complete),
            name: DisplaySanitizer.plainText(name)
        )
    }
}
